// Package api exposes the agent's HTTPS surface.
//
// Every responder except /healthz and /v1/pair requires a device bearer token. The router is
// the standard library mux; the surface is small enough that a third-party router would be
// noise. See docs/sync-protocol.md for the full endpoint contract.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"runtime"
	"runtime/debug"
	"strings"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/blob"
	"github.com/Gyakudos/CloudBox/agent/internal/devices"
	"github.com/Gyakudos/CloudBox/agent/internal/folder"
	"github.com/Gyakudos/CloudBox/agent/internal/identity"
	"github.com/Gyakudos/CloudBox/agent/internal/pairing"
	"github.com/Gyakudos/CloudBox/agent/internal/volume"
)

// maxBodyBytes caps JSON request bodies. Pair requests are a few hundred bytes; anything
// larger is a mistake or an attack. Upload bytes do not go through this limit; they are
// bounded by the declared size on the upload itself.
const maxBodyBytes = 64 << 10

// Options configures a Server. Identity, Pairing and Devices are required. Blobs and Folders
// are required for the upload endpoints; when Blobs is nil those routes are not registered.
type Options struct {
	Identity   *identity.Identity
	Pairing    *pairing.Manager
	Devices    *devices.Store
	Blobs      *blob.Store
	Folders    *folder.Registry
	Volumes    func() ([]volume.Volume, error)
	// SetDestination resolves a volume the phone picked into the default sync folder. Nil
	// disables the destination endpoint.
	SetDestination func(volumeName, subfolder string) (folder.Folder, error)
	ServerName     string
	Version        string
	StartedAt      time.Time
	Logger         *slog.Logger
}

// Server serves the agent HTTP API.
type Server struct {
	opts Options
}

// New builds a Server, filling in defaults for the optional fields.
func New(opts Options) *Server {
	if opts.Volumes == nil {
		opts.Volumes = volume.List
	}
	if opts.Logger == nil {
		opts.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if opts.StartedAt.IsZero() {
		opts.StartedAt = time.Now()
	}
	return &Server{opts: opts}
}

// Handler returns the fully wired HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("POST /v1/pair", s.handlePair)
	mux.Handle("GET /v1/system/info", s.requireDevice(http.HandlerFunc(s.handleInfo)))
	mux.Handle("GET /v1/system/volumes", s.requireDevice(http.HandlerFunc(s.handleVolumes)))

	if s.opts.SetDestination != nil {
		mux.Handle("PUT /v1/system/destination", s.requireDevice(http.HandlerFunc(s.handleSetDestination)))
	}

	if s.opts.Blobs != nil {
		mux.Handle("POST /v1/uploads", s.requireDevice(http.HandlerFunc(s.handleCreateUpload)))
		mux.Handle("PATCH /v1/uploads/{id}", s.requireDevice(http.HandlerFunc(s.handleAppendUpload)))
		mux.Handle("GET /v1/uploads/{id}", s.requireDevice(http.HandlerFunc(s.handleUploadStatus)))
		mux.Handle("POST /v1/uploads/{id}/commit", s.requireDevice(http.HandlerFunc(s.handleCommitUpload)))
	}

	return s.observe(mux)
}

// ---------------------------------------------------------------------------- middleware

type deviceContextKey struct{}

func (s *Server) requireDevice(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r)
		if !ok {
			writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "missing bearer token")
			return
		}
		device, ok := s.opts.Devices.Authenticate(token)
		if !ok {
			writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "unknown device token")
			return
		}
		ctx := context.WithValue(r.Context(), deviceContextKey{}, device)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func deviceFrom(ctx context.Context) (devices.Device, bool) {
	device, ok := ctx.Value(deviceContextKey{}).(devices.Device)
	return device, ok
}

func bearerToken(r *http.Request) (string, bool) {
	const prefix = "Bearer "
	header := r.Header.Get("Authorization")
	if len(header) <= len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return "", false
	}
	token := strings.TrimSpace(header[len(prefix):])
	return token, token != ""
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (s *Server) observe(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		defer func() {
			if recovered := recover(); recovered != nil {
				s.opts.Logger.Error("panic serving request",
					"method", r.Method, "path", r.URL.Path,
					"panic", recovered, "stack", string(debug.Stack()))
				writeError(recorder, http.StatusInternalServerError, "INTERNAL", "internal error")
			}
			s.opts.Logger.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", recorder.status,
				"duration_ms", time.Since(start).Milliseconds(),
			)
		}()

		next.ServeHTTP(recorder, r)
	})
}

// ---------------------------------------------------------------------------- handlers

type healthResponse struct {
	Status        string `json:"status"`
	Version       string `json:"version"`
	ServerID      string `json:"server_id"`
	UptimeSeconds int64  `json:"uptime_seconds"`
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, healthResponse{
		Status:        "ok",
		Version:       s.opts.Version,
		ServerID:      s.opts.Identity.ServerID,
		UptimeSeconds: int64(time.Since(s.opts.StartedAt).Seconds()),
	})
}

type pairRequest struct {
	Token      string `json:"token"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
	AppVersion string `json:"app_version"`
}

type pairResponse struct {
	DeviceID      string `json:"device_id"`
	DeviceToken   string `json:"device_token"`
	ServerID      string `json:"server_id"`
	ServerName    string `json:"server_name"`
	ServerVersion string `json:"server_version"`
}

func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	var req pairRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "malformed JSON body")
		return
	}

	req.DeviceName = strings.TrimSpace(req.DeviceName)
	if req.DeviceName == "" {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "device_name is required")
		return
	}
	if len(req.DeviceName) > 64 {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "device_name is too long")
		return
	}
	if req.Platform == "" {
		req.Platform = "unknown"
	}

	// Validation runs before redemption on purpose: a malformed request is a client bug, not
	// an attack, and burning a token for it would force the user to walk back to the PC.
	// Redemption itself is single-use and mutex-guarded, so concurrent attempts still
	// resolve to exactly one winner.
	if err := s.opts.Pairing.Redeem(req.Token); err != nil {
		s.opts.Logger.Warn("pairing rejected", "reason", err, "device_name", req.DeviceName)
		writeError(w, http.StatusUnauthorized, "INVALID_PAIRING_TOKEN", "pairing token is invalid, used, or expired")
		return
	}

	device, token, err := s.opts.Devices.Create(req.DeviceName, req.Platform, req.AppVersion)
	if err != nil {
		s.opts.Logger.Error("create device", "err", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL", "could not register device")
		return
	}

	s.opts.Logger.Info("device paired", "device_id", device.ID, "name", device.Name, "platform", device.Platform)

	writeJSON(w, http.StatusCreated, pairResponse{
		DeviceID:      device.ID,
		DeviceToken:   token,
		ServerID:      s.opts.Identity.ServerID,
		ServerName:    s.opts.ServerName,
		ServerVersion: s.opts.Version,
	})
}

type infoResponse struct {
	ServerID   string          `json:"server_id"`
	ServerName string          `json:"server_name"`
	Version    string          `json:"version"`
	Platform   string          `json:"platform"`
	Device     devices.Device  `json:"device"`
	Folders    []folder.Folder `json:"folders"`
}

func (s *Server) handleInfo(w http.ResponseWriter, r *http.Request) {
	device, ok := deviceFrom(r.Context())
	if !ok {
		writeError(w, http.StatusInternalServerError, "INTERNAL", "device missing from request context")
		return
	}

	folders := []folder.Folder{}
	if s.opts.Folders != nil {
		folders = s.opts.Folders.List()
	}

	writeJSON(w, http.StatusOK, infoResponse{
		ServerID:   s.opts.Identity.ServerID,
		ServerName: s.opts.ServerName,
		Version:    s.opts.Version,
		Platform:   runtime.GOOS,
		Device:     device,
		Folders:    folders,
	})
}

type volumesResponse struct {
	Volumes []volume.Volume `json:"volumes"`
}

func (s *Server) handleVolumes(w http.ResponseWriter, r *http.Request) {
	vols, err := s.opts.Volumes()
	if err != nil {
		s.opts.Logger.Error("enumerate volumes", "err", err)
		writeError(w, http.StatusInternalServerError, "VOLUMES_UNAVAILABLE", "could not enumerate volumes")
		return
	}
	if vols == nil {
		vols = []volume.Volume{}
	}
	writeJSON(w, http.StatusOK, volumesResponse{Volumes: vols})
}

// ---------------------------------------------------------------------------- helpers

type errorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type errorEnvelope struct {
	Error errorBody `json:"error"`
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorEnvelope{Error: errorBody{Code: code, Message: message}})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(dst); err != nil {
		return err
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("unexpected trailing data")
	}
	return nil
}
