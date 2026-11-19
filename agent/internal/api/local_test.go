package api_test

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
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
	devices   *devices.Store
	deviceID  string
}

func newLocalHarness(t *testing.T, withLocal bool) *localHarness {
	t.Helper()

	ident, err := identity.LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	h := &localHarness{}
	store := devices.NewStore()
	device, _, err := store.Create("Pixel", "android", "v")
	if err != nil {
		t.Fatalf("create device: %v", err)
	}
	if _, err := store.SetBackupConfig(device.ID, devices.BackupConfig{
		FolderID:  devices.BackupFolderID(device.ID),
		Volume:    "E:",
		Subfolder: "CloudBox/Phone",
		Root:      filepath.Join(`E:\`, "CloudBox", "Phone"),
		Enabled:   true,
	}); err != nil {
		t.Fatalf("set backup config: %v", err)
	}
	h.devices = store
	h.deviceID = device.ID

	opts := api.Options{
		Identity:   ident,
		Pairing:    pairing.NewManager(time.Minute),
		Devices:    store,
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
		ListDevices:  func() []devices.Device { return store.List() },
		RevokeDevice: func(id string) error { _, err := store.RevokeWithError(id); return err },
		SetDeviceBackup: func(id, vol, sub string, enabled bool) (devices.Device, folder.Folder, error) {
			dev, err := store.SetBackupConfig(id, devices.BackupConfig{
				FolderID:  devices.BackupFolderID(id),
				Volume:    vol,
				Subfolder: sub,
				Root:      filepath.Join(vol, filepath.FromSlash(sub)),
				Enabled:   enabled,
			})
			if err != nil {
				return devices.Device{}, folder.Folder{}, err
			}
			return dev, folder.Folder{ID: dev.Backup.FolderID, Name: sub, Root: dev.Backup.Root}, nil
		},
		ListBackups: func() []api.BackupInfo {
			out := []api.BackupInfo{}
			for _, dev := range store.List() {
				cfg := dev.Backup
				out = append(out, api.BackupInfo{
					DeviceID: dev.ID, DeviceName: dev.Name,
					FolderID: cfg.FolderID, Volume: cfg.Volume,
					Subfolder: cfg.Subfolder, Root: cfg.Root,
					Available: true, Enabled: cfg.Enabled, LastSeenAt: dev.LastSeenAt,
				})
			}
			return out
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
		opts.LocalLogs = func() []string { return []string{"first line", "second line"} }
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
		{http.MethodGet, "/local/logs"},
		{http.MethodGet, "/local/volumes"},
		{http.MethodPut, "/local/destination"},
		{http.MethodGet, "/local/devices"},
		{http.MethodDelete, "/local/devices/device-id"},
		{http.MethodPut, "/local/devices/device-id/backup"},
		{http.MethodGet, "/local/backups"},
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

func TestLocalLogsReturnsBufferedLines(t *testing.T) {
	h := newLocalHarness(t, true)
	rec := h.request(http.MethodGet, "/local/logs", "127.0.0.1:5151", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	var body struct {
		Lines []string `json:"lines"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	want := []string{"first line", "second line"}
	if len(body.Lines) != len(want) {
		t.Fatalf("lines = %q, want %q", body.Lines, want)
	}
	for i := range want {
		if body.Lines[i] != want[i] {
			t.Fatalf("lines[%d] = %q, want %q", i, body.Lines[i], want[i])
		}
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
	for _, path := range []string{"/local/status", "/local/logs", "/local/volumes"} {
		rec := h.request(http.MethodGet, path, "127.0.0.1:5151", nil)
		if rec.Code != http.StatusNotFound {
			t.Errorf("%s: status = %d, want 404", path, rec.Code)
		}
	}
}

func TestLocalDevicesAndBackups(t *testing.T) {
	h := newLocalHarness(t, true)
	loopback := "127.0.0.1:5151"

	rec := h.request(http.MethodGet, "/local/devices", loopback, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("devices: status = %d body %s", rec.Code, rec.Body.String())
	}
	var listed struct {
		Devices []devices.Device `json:"devices"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &listed); err != nil {
		t.Fatalf("decode devices: %v", err)
	}
	if len(listed.Devices) != 1 || listed.Devices[0].ID != h.deviceID {
		t.Fatalf("devices = %+v", listed.Devices)
	}

	rec = h.request(http.MethodGet, "/local/backups", loopback, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("backups: status = %d body %s", rec.Code, rec.Body.String())
	}
	var backups struct {
		Backups []api.BackupInfo `json:"backups"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &backups); err != nil {
		t.Fatalf("decode backups: %v", err)
	}
	if len(backups.Backups) != 1 {
		t.Fatalf("backups = %+v", backups.Backups)
	}
	row := backups.Backups[0]
	if row.DeviceID != h.deviceID || row.DeviceName != "Pixel" ||
		row.FolderID != devices.BackupFolderID(h.deviceID) || row.Volume != "E:" ||
		row.Subfolder != "CloudBox/Phone" || !row.Enabled || !row.Available {
		t.Fatalf("backup row = %+v", row)
	}

	rec = h.request(http.MethodPut, "/local/devices/"+h.deviceID+"/backup", loopback, map[string]any{
		"volume": "E:", "subfolder": "CloudBox/New", "enabled": false,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("set backup: status = %d body %s", rec.Code, rec.Body.String())
	}
	var updated struct {
		Device devices.Device `json:"device"`
		Folder folder.Folder  `json:"folder"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode set backup: %v", err)
	}
	if updated.Device.Backup.Enabled || updated.Device.Backup.Subfolder != "CloudBox/New" {
		t.Fatalf("updated device = %+v", updated.Device)
	}
	if updated.Folder.ID != devices.BackupFolderID(h.deviceID) || updated.Folder.Root == "" {
		t.Fatalf("updated folder = %+v", updated.Folder)
	}

	rec = h.request(http.MethodGet, "/local/backups", loopback, nil)
	if err := json.Unmarshal(rec.Body.Bytes(), &backups); err != nil {
		t.Fatalf("decode backups after update: %v", err)
	}
	if len(backups.Backups) == 1 && backups.Backups[0].Enabled {
		t.Fatal("backup still reported as enabled after disabling it")
	}

	rec = h.request(http.MethodDelete, "/local/devices/"+h.deviceID, loopback, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("delete: status = %d body %s", rec.Code, rec.Body.String())
	}
	var deleted struct {
		Deleted bool `json:"deleted"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &deleted); err != nil || !deleted.Deleted {
		t.Fatalf("delete response = %s err=%v", rec.Body.String(), err)
	}
	for _, path := range []string{"/local/devices", "/local/backups"} {
		rec = h.request(http.MethodGet, path, loopback, nil)
		if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) == "" {
			t.Fatalf("%s after delete: status = %d body %s", path, rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), h.deviceID) {
			t.Fatalf("%s still lists the revoked device: %s", path, rec.Body.String())
		}
	}
}

func TestLocalDeviceNotFound(t *testing.T) {
	h := newLocalHarness(t, true)
	loopback := "127.0.0.1:5151"

	rec := h.request(http.MethodDelete, "/local/devices/missing", loopback, nil)
	if rec.Code != http.StatusNotFound || decodeError(t, rec) != "DEVICE_NOT_FOUND" {
		t.Fatalf("delete unknown: status = %d code = %q", rec.Code, decodeError(t, rec))
	}

	rec = h.request(http.MethodPut, "/local/devices/missing/backup", loopback, map[string]string{
		"volume": "E:", "subfolder": "CloudBox",
	})
	if rec.Code != http.StatusNotFound || decodeError(t, rec) != "DEVICE_NOT_FOUND" {
		t.Fatalf("backup unknown: status = %d code = %q", rec.Code, decodeError(t, rec))
	}
}
