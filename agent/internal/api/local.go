package api

// The /local/* surface exists for the PC-side desktop app. It needs no device bearer token:
// the app is the person sitting at this machine, with the same trust level as the files in the
// agent's data directory. Access is instead restricted to loopback connections, so none of it
// is reachable from a phone or another computer on the LAN.
//
// This is why the pairing code, volume list and destination controls are not folded into the
// device-authenticated /v1 routes — a phone that is paired to back up photos must not be able
// to mint new pairing codes or repoint the backup folder.

import (
	"errors"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/destination"
	"github.com/Gyakudos/CloudBox/agent/internal/devices"
	"github.com/Gyakudos/CloudBox/agent/internal/folder"
)

// LocalPairing is the currently displayed pairing code and its state.
type LocalPairing struct {
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
	// Active is false once a phone has redeemed the token or it has expired. The desktop app
	// polls status to switch from "waiting" to "paired" without consuming the token itself.
	Active bool `json:"active"`
}

// LocalState is everything the desktop app needs to render its two screens. Payload is the JSON
// QR document (the same bytes written to pairing.json) and QRPNGBase64 is a rendered copy, so
// the app does not have to guess the data directory or duplicate QR encoding.
type LocalState struct {
	ServerName  string                   `json:"server_name"`
	ServerID    string                   `json:"server_id"`
	Version     string                   `json:"version"`
	Pin         string                   `json:"pin"`
	Endpoints   []string                 `json:"endpoints"`
	Pairing     LocalPairing             `json:"pairing"`
	Destination *destination.Destination `json:"destination"`
	Payload     string                   `json:"payload"`
	QRPNGBase64 string                   `json:"qr_png_base64"`
}

func (s *Server) handleLocalStatus(w http.ResponseWriter, _ *http.Request) {
	state := s.opts.LocalState()
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleLocalRefresh(w http.ResponseWriter, _ *http.Request) {
	state, err := s.opts.LocalRefresh()
	if err != nil {
		s.opts.Logger.Error("refresh pairing code", "err", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL", "could not create a new pairing code")
		return
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleLocalSetDestination(w http.ResponseWriter, r *http.Request) {
	var req setDestinationRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "malformed JSON body")
		return
	}
	s.applyDestination(w, req)
}

// BackupInfo is one row of the PC app's paired-devices screen. Availability is computed by the
// agent (which can see the drives) rather than guessed by the client.
type BackupInfo struct {
	DeviceID   string    `json:"device_id"`
	DeviceName string    `json:"device_name"`
	FolderID   string    `json:"folder_id"`
	Volume     string    `json:"volume"`
	Subfolder  string    `json:"subfolder"`
	Root       string    `json:"root"`
	Available  bool      `json:"available"`
	Enabled    bool      `json:"enabled"`
	LastSeenAt time.Time `json:"last_seen_at"`
}

func (s *Server) handleLocalListDevices(w http.ResponseWriter, _ *http.Request) {
	out := []devices.Device{}
	if s.opts.ListDevices != nil {
		out = s.opts.ListDevices()
	}
	if out == nil {
		out = []devices.Device{}
	}
	writeJSON(w, http.StatusOK, struct {
		Devices []devices.Device `json:"devices"`
	}{Devices: out})
}

func (s *Server) handleLocalRevokeDevice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if s.opts.RevokeDevice == nil {
		writeError(w, http.StatusNotImplemented, "INTERNAL", "device management is not configured")
		return
	}
	switch err := s.opts.RevokeDevice(id); {
	case errors.Is(err, devices.ErrNotFound):
		writeError(w, http.StatusNotFound, "DEVICE_NOT_FOUND", "no such paired device")
		return
	case err != nil:
		s.opts.Logger.Error("revoke device", "err", err, "device_id", id)
		writeError(w, http.StatusInternalServerError, "INTERNAL", "could not revoke device")
		return
	}
	s.opts.Logger.Info("device revoked", "device_id", id)
	writeJSON(w, http.StatusOK, struct {
		Deleted bool `json:"deleted"`
	}{Deleted: true})
}

type setBackupRequest struct {
	Volume    string `json:"volume"`
	Subfolder string `json:"subfolder"`
	// Enabled defaults to true when omitted, so a simple volume/subfolder PUT turns backups on.
	Enabled *bool `json:"enabled"`
}

type setBackupResponse struct {
	Device devices.Device `json:"device"`
	Folder folder.Folder  `json:"folder"`
}

func (s *Server) handleLocalSetBackup(w http.ResponseWriter, r *http.Request) {
	var req setBackupRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "malformed JSON body")
		return
	}
	if strings.TrimSpace(req.Volume) == "" {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "volume is required")
		return
	}
	if s.opts.SetDeviceBackup == nil {
		writeError(w, http.StatusNotImplemented, "INTERNAL", "device management is not configured")
		return
	}
	enabled := true
	if req.Enabled != nil {
		enabled = *req.Enabled
	}

	device, selected, err := s.opts.SetDeviceBackup(r.PathValue("id"), req.Volume, req.Subfolder, enabled)
	switch {
	case errors.Is(err, devices.ErrNotFound):
		writeError(w, http.StatusNotFound, "DEVICE_NOT_FOUND", "no such paired device")
		return
	case errors.Is(err, destination.ErrUnknownVolume):
		writeError(w, http.StatusNotFound, "VOLUME_NOT_FOUND", "the PC no longer has that drive")
		return
	case errors.Is(err, destination.ErrInvalidSubfolder):
		writeError(w, http.StatusBadRequest, "INVALID_SUBFOLDER", "the folder name is not usable on that drive")
		return
	case err != nil:
		s.opts.Logger.Error("set device backup", "err", err, "device_id", r.PathValue("id"))
		writeError(w, http.StatusInternalServerError, "INTERNAL", "could not change the device backup")
		return
	}

	s.opts.Logger.Info("device backup changed",
		"device_id", device.ID, "folder_id", selected.ID, "root", selected.Root)
	writeJSON(w, http.StatusOK, setBackupResponse{Device: device, Folder: selected})
}

func (s *Server) handleLocalListBackups(w http.ResponseWriter, _ *http.Request) {
	out := []BackupInfo{}
	if s.opts.ListBackups != nil {
		out = s.opts.ListBackups()
	}
	if out == nil {
		out = []BackupInfo{}
	}
	writeJSON(w, http.StatusOK, struct {
		Backups []BackupInfo `json:"backups"`
	}{Backups: out})
}

// requireLoopback rejects any request that did not arrive over a loopback connection. Checking
// the socket peer rather than a Host header means a DNS name pointing at the PC cannot slip
// through: the TCP source address cannot be spoofed.
func (s *Server) requireLoopback(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			host = r.RemoteAddr
		}
		ip := net.ParseIP(strings.Trim(host, "[]"))
		if ip == nil || !ip.IsLoopback() {
			s.opts.Logger.Warn("rejected non-loopback local request", "remote", r.RemoteAddr, "path", r.URL.Path)
			writeError(w, http.StatusForbidden, "LOCAL_ONLY", "this endpoint is only available from this PC")
			return
		}
		next.ServeHTTP(w, r)
	})
}
