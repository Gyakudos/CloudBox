package api_test

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/api"
	"github.com/Gyakudos/CloudBox/agent/internal/destination"
	"github.com/Gyakudos/CloudBox/agent/internal/devices"
	"github.com/Gyakudos/CloudBox/agent/internal/folder"
	"github.com/Gyakudos/CloudBox/agent/internal/identity"
	"github.com/Gyakudos/CloudBox/agent/internal/pairing"
	"github.com/Gyakudos/CloudBox/agent/internal/volume"
)

type localHarness struct {
	handler   http.Handler
	refreshed int
}

func newLocalHarness(t *testing.T, withLocal bool) *localHarness {
	t.Helper()

	ident, err := identity.LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	h := &localHarness{}
	opts := api.Options{
		Identity:   ident,
		Pairing:    pairing.NewManager(time.Minute),
		Devices:    devices.NewStore(),
		ServerName: "TEST-PC",
		Version:    "test-version",
		StartedAt:  time.Now(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		Volumes: func() ([]volume.Volume, error) {
			return []volume.Volume{{Name: "E:", Path: `E:\`, FSType: "NTFS", Total: 1000, Free: 400}}, nil
		},
		SetDestination: func(vol, sub string) (folder.Folder, error) {
			return folder.Folder{ID: destination.DefaultID, Name: sub, Root: vol + sub}, nil
		},
	}
	if withLocal {
		opts.LocalState = func() api.LocalState {
			return api.LocalState{
				ServerName: "TEST-PC",
				ServerID:   ident.ServerID,
				Version:    "test-version",
				Pin:        ident.Pin,
				Endpoints:  []string{"127.0.0.1:8443"},
				Pairing: api.LocalPairing{
					Token:     "local-token",
					ExpiresAt: time.Now().Add(time.Minute),
					Active:    true,
				},
				Destination: &destination.Destination{Volume: "C:", Subfolder: "CloudBox", Root: `C:\CloudBox`},
				Payload:     `{"tok":"local-token"}`,
				QRPNGBase64: "aGVsbG8=",
			}
		}
		opts.LocalRefresh = func() (api.LocalState, error) {
			h.refreshed++
			return opts.LocalState(), nil
		}
	}
	h.handler = api.New(opts).Handler()
	return h
}

func (h *localHarness) request(method, path, remote string, body any) *httptest.ResponseRecorder {
	var reader io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		reader = bytes.NewReader(raw)
	}
	req := httptest.NewRequest(method, path, reader)
	req.RemoteAddr = remote
	rec := httptest.NewRecorder()
	h.handler.ServeHTTP(rec, req)
	return rec
}

func TestLocalRoutesRejectNonLoopback(t *testing.T) {
	h := newLocalHarness(t, true)
	remote := "192.0.2.42:5151"

	for _, tc := range []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/local/status"},
		{http.MethodPost, "/local/pairing/refresh"},
		{http.MethodGet, "/local/volumes"},
		{http.MethodPut, "/local/destination"},
	} {
		rec := h.request(tc.method, tc.path, remote, map[string]string{"volume": "E:"})
		if rec.Code != http.StatusForbidden {
			t.Errorf("%s %s: status = %d, want 403", tc.method, tc.path, rec.Code)
		}
		if code := decodeError(t, rec); code != "LOCAL_ONLY" {
			t.Errorf("%s %s: error code = %q, want LOCAL_ONLY", tc.method, tc.path, code)
		}
	}
}

func TestIPv6LoopbackIsAllowed(t *testing.T) {
	h := newLocalHarness(t, true)
	rec := h.request(http.MethodGet, "/local/status", "[::1]:5151", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
}

func TestLocalStatusNeedsNoDeviceToken(t *testing.T) {
	h := newLocalHarness(t, true)
	rec := h.request(http.MethodGet, "/local/status", "127.0.0.1:5151", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}

	var body api.LocalState
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.ServerName != "TEST-PC" || body.Pin == "" || len(body.Endpoints) != 1 {
		t.Fatalf("unexpected identity in status: %+v", body)
	}
	if body.Pairing.Token != "local-token" || !body.Pairing.Active {
		t.Fatalf("unexpected pairing in status: %+v", body.Pairing)
	}
	if body.Destination == nil || body.Destination.Volume != "C:" {
		t.Fatalf("unexpected destination in status: %+v", body.Destination)
	}
	if body.QRPNGBase64 != "aGVsbG8=" || body.Payload == "" {
		t.Fatalf("unexpected QR fields in status: %+v", body)
	}
}

func TestLocalRefreshCallsSession(t *testing.T) {
	h := newLocalHarness(t, true)
	rec := h.request(http.MethodPost, "/local/pairing/refresh", "127.0.0.1:5151", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	if h.refreshed != 1 {
		t.Fatalf("refresh called %d times, want 1", h.refreshed)
	}
}

func TestLocalVolumesAndDestination(t *testing.T) {
	h := newLocalHarness(t, true)

	rec := h.request(http.MethodGet, "/local/volumes", "127.0.0.1:5151", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("volumes: status = %d, want 200", rec.Code)
	}
	var vols struct {
		Volumes []volume.Volume `json:"volumes"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &vols); err != nil {
		t.Fatalf("decode volumes: %v", err)
	}
	if len(vols.Volumes) != 1 || vols.Volumes[0].Name != "E:" {
		t.Fatalf("unexpected volumes: %+v", vols.Volumes)
	}

	rec = h.request(http.MethodPut, "/local/destination", "127.0.0.1:5151", map[string]string{
		"volume": "E:", "subfolder": "CloudBox",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("destination: status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	var dest struct {
		Folder folder.Folder `json:"folder"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &dest); err != nil {
		t.Fatalf("decode destination: %v", err)
	}
	if dest.Folder.Root != `E:CloudBox` {
		t.Fatalf("unexpected folder: %+v", dest.Folder)
	}
}

func TestLocalRoutesAbsentWithoutLocalState(t *testing.T) {
	h := newLocalHarness(t, false)
	for _, path := range []string{"/local/status", "/local/volumes"} {
		rec := h.request(http.MethodGet, path, "127.0.0.1:5151", nil)
		if rec.Code != http.StatusNotFound {
			t.Errorf("%s: status = %d, want 404", path, rec.Code)
		}
	}
}
