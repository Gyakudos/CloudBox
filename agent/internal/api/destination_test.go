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
)

type destinationHarness struct {
	handler http.Handler
	token   string
}

func newDestinationHarness(t *testing.T, set func(string, string) (folder.Folder, error)) *destinationHarness {
	t.Helper()

	ident, err := identity.LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	store := devices.NewStore()
	_, token, err := store.Create("TestPhone", "android", "test")
	if err != nil {
		t.Fatalf("create device: %v", err)
	}

	srv := api.New(api.Options{
		Identity:       ident,
		Pairing:        pairing.NewManager(time.Minute),
		Devices:        store,
		SetDestination: set,
		ServerName:     "TEST-PC",
		Version:        "test-version",
		Logger:         slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	return &destinationHarness{handler: srv.Handler(), token: token}
}

func (h *destinationHarness) put(body any, token string) *httptest.ResponseRecorder {
	raw, _ := json.Marshal(body)
	req := httptest.NewRequest(http.MethodPut, "/v1/system/destination", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.handler.ServeHTTP(rec, req)
	return rec
}

func TestSetDestinationReturnsTheChosenFolder(t *testing.T) {
	var gotVolume, gotSubfolder string
	h := newDestinationHarness(t, func(vol, sub string) (folder.Folder, error) {
		gotVolume, gotSubfolder = vol, sub
		return folder.Folder{ID: destination.DefaultID, Name: "CloudBox", Root: `E:\CloudBox`}, nil
	})

	rec := h.put(map[string]string{"volume": "E:", "subfolder": "CloudBox"}, h.token)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	if gotVolume != "E:" || gotSubfolder != "CloudBox" {
		t.Fatalf("handler got (%q, %q)", gotVolume, gotSubfolder)
	}

	var body struct {
		Folder folder.Folder `json:"folder"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Folder.ID != destination.DefaultID || body.Folder.Root != `E:\CloudBox` {
		t.Fatalf("unexpected folder: %+v", body.Folder)
	}
}

func TestSetDestinationUsesTheCallingDeviceBackupFolder(t *testing.T) {
	ident, err := identity.LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	store := devices.NewStore()
	device, token, err := store.Create("Phone", "android", "test")
	if err != nil {
		t.Fatalf("create device: %v", err)
	}
	_, err = store.SetBackupConfig(device.ID, devices.BackupConfig{
		FolderID:  "backup-" + device.ID,
		Volume:    "C:",
		Subfolder: "CloudBox/Phone",
		Root:      `C:\CloudBox\Phone`,
		Enabled:   true,
	})
	if err != nil {
		t.Fatalf("set backup config: %v", err)
	}

	srv := api.New(api.Options{
		Identity: ident,
		Pairing:  pairing.NewManager(time.Minute),
		Devices:  store,
		SetDestination: func(string, string) (folder.Folder, error) {
			t.Fatal("the global destination must not change for a paired phone")
			return folder.Folder{}, nil
		},
		SetDeviceBackup: func(id, vol, sub string, enabled bool) (devices.Device, folder.Folder, error) {
			if id != device.ID || vol != "E:" || sub != "Phone" || !enabled {
				t.Fatalf("device backup setter got (%q, %q, %q, %v)", id, vol, sub, enabled)
			}
			return device, folder.Folder{ID: "backup-" + id, Name: sub, Root: `E:\Phone`}, nil
		},
		ServerName: "TEST-PC",
		Version:    "test-version",
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	h := &destinationHarness{handler: srv.Handler(), token: token}

	rec := h.put(map[string]string{"volume": "E:", "subfolder": "Phone"}, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	var body struct {
		Folder folder.Folder `json:"folder"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Folder.ID != "backup-"+device.ID {
		t.Fatalf("folder id = %q, want per-device folder", body.Folder.ID)
	}
}

func TestSetDestinationMapsErrorsToStatus(t *testing.T) {
	cases := []struct {
		name     string
		err      error
		wantCode int
		wantBody string
	}{
		{"unknown volume", destination.ErrUnknownVolume, http.StatusNotFound, "VOLUME_NOT_FOUND"},
		{"unsafe subfolder", destination.ErrInvalidSubfolder, http.StatusBadRequest, "INVALID_SUBFOLDER"},
		{"internal", io.ErrUnexpectedEOF, http.StatusInternalServerError, "INTERNAL"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newDestinationHarness(t, func(string, string) (folder.Folder, error) {
				return folder.Folder{}, tc.err
			})
			rec := h.put(map[string]string{"volume": "E:"}, h.token)
			if rec.Code != tc.wantCode {
				t.Fatalf("status = %d, want %d (body %s)", rec.Code, tc.wantCode, rec.Body.String())
			}
			if code := decodeError(t, rec); code != tc.wantBody {
				t.Fatalf("error code = %q, want %q", code, tc.wantBody)
			}
		})
	}
}

func TestSetDestinationRequiresVolume(t *testing.T) {
	called := false
	h := newDestinationHarness(t, func(string, string) (folder.Folder, error) {
		called = true
		return folder.Folder{}, nil
	})

	rec := h.put(map[string]string{"subfolder": "CloudBox"}, h.token)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	if called {
		t.Fatal("SetDestination was called without a volume")
	}
}

func TestSetDestinationRequiresAuth(t *testing.T) {
	h := newDestinationHarness(t, func(string, string) (folder.Folder, error) {
		return folder.Folder{}, nil
	})

	rec := h.put(map[string]string{"volume": "E:"}, "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestSetDestinationRouteAbsentWhenUnconfigured(t *testing.T) {
	h := newDestinationHarness(t, nil)

	rec := h.put(map[string]string{"volume": "E:"}, h.token)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 when no destination callback is configured", rec.Code)
	}
}
