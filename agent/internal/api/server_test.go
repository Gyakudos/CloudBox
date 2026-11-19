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
	"github.com/Gyakudos/CloudBox/agent/internal/devices"
	"github.com/Gyakudos/CloudBox/agent/internal/folder"
	"github.com/Gyakudos/CloudBox/agent/internal/identity"
	"github.com/Gyakudos/CloudBox/agent/internal/pairing"
	"github.com/Gyakudos/CloudBox/agent/internal/volume"
)

type harness struct {
	handler  http.Handler
	pairings *pairing.Manager
}

func newHarness(t *testing.T) *harness {
	t.Helper()

	ident, err := identity.LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("identity.LoadOrCreate: %v", err)
	}

	pairings := pairing.NewManager(time.Minute)
	srv := api.New(api.Options{
		Identity: ident,
		Pairing:  pairings,
		Devices:  devices.NewStore(),
		Volumes: func() ([]volume.Volume, error) {
			return []volume.Volume{
				{Name: "C:", Path: `C:\`, FSType: "NTFS", Total: 1000, Free: 400},
			}, nil
		},
		ServerName: "TEST-PC",
		Version:    "test-version",
		StartedAt:  time.Now(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	})

	return &harness{handler: srv.Handler(), pairings: pairings}
}

func (h *harness) do(method, path string, body any, token string) *httptest.ResponseRecorder {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			panic(err)
		}
		reader = bytes.NewReader(raw)
	}

	req := httptest.NewRequest(method, path, reader)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	rec := httptest.NewRecorder()
	h.handler.ServeHTTP(rec, req)
	return rec
}

func decodeError(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var envelope struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode error envelope: %v (body %q)", err, rec.Body.String())
	}
	return envelope.Error.Code
}

func TestHealthNeedsNoAuth(t *testing.T) {
	h := newHarness(t)

	rec := h.do(http.MethodGet, "/healthz", nil, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}

	var body struct {
		Status   string `json:"status"`
		Version  string `json:"version"`
		ServerID string `json:"server_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Status != "ok" || body.Version != "test-version" || body.ServerID == "" {
		t.Fatalf("unexpected body: %+v", body)
	}
}

func TestSystemEndpointsRequireDeviceToken(t *testing.T) {
	h := newHarness(t)

	for _, path := range []string{"/v1/system/info", "/v1/system/volumes"} {
		rec := h.do(http.MethodGet, path, nil, "")
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("%s: status = %d, want 401", path, rec.Code)
		}
		if code := decodeError(t, rec); code != "UNAUTHORIZED" {
			t.Fatalf("%s: error code = %q, want UNAUTHORIZED", path, code)
		}

		rec = h.do(http.MethodGet, path, nil, "not-a-real-token")
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("%s with bad token: status = %d, want 401", path, rec.Code)
		}
	}
}

func TestPairFlow(t *testing.T) {
	h := newHarness(t)

	token, _, err := h.pairings.Issue()
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}

	rec := h.do(http.MethodPost, "/v1/pair", map[string]string{
		"token":       "wrong",
		"device_name": "Pixel 8",
	}, "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("bad token: status = %d, want 401", rec.Code)
	}
	if code := decodeError(t, rec); code != "INVALID_PAIRING_TOKEN" {
		t.Fatalf("bad token: error code = %q", code)
	}

	rec = h.do(http.MethodPost, "/v1/pair", map[string]string{
		"token":       token,
		"device_name": "Pixel 8",
		"platform":    "android",
		"app_version": "test-version",
	}, "")
	if rec.Code != http.StatusCreated {
		t.Fatalf("pair: status = %d, want 201 (body %s)", rec.Code, rec.Body.String())
	}

	var paired struct {
		DeviceID      string `json:"device_id"`
		DeviceToken   string `json:"device_token"`
		ServerID      string `json:"server_id"`
		ServerName    string `json:"server_name"`
		ServerVersion string `json:"server_version"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &paired); err != nil {
		t.Fatalf("decode pair response: %v", err)
	}
	if paired.DeviceID == "" || paired.DeviceToken == "" {
		t.Fatalf("pair response missing identifiers: %+v", paired)
	}
	if paired.ServerName != "TEST-PC" || paired.ServerVersion != "test-version" {
		t.Fatalf("pair response has wrong server identity: %+v", paired)
	}

	// The pairing token must be single use.
	rec = h.do(http.MethodPost, "/v1/pair", map[string]string{
		"token":       token,
		"device_name": "Attacker",
	}, "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("token reuse: status = %d, want 401", rec.Code)
	}

	// The issued device token must now be accepted.
	rec = h.do(http.MethodGet, "/v1/system/volumes", nil, paired.DeviceToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("volumes with device token: status = %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}

	var volumesBody struct {
		Volumes []volume.Volume `json:"volumes"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &volumesBody); err != nil {
		t.Fatalf("decode volumes: %v", err)
	}
	if len(volumesBody.Volumes) != 1 || volumesBody.Volumes[0].Name != "C:" {
		t.Fatalf("unexpected volumes: %+v", volumesBody.Volumes)
	}

	rec = h.do(http.MethodGet, "/v1/system/info", nil, paired.DeviceToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("info: status = %d, want 200", rec.Code)
	}
	var info struct {
		Device  devices.Device  `json:"device"`
		Folders []folder.Folder `json:"folders"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatalf("decode info: %v", err)
	}
	if info.Device.ID != paired.DeviceID {
		t.Fatalf("info device = %q, want %q", info.Device.ID, paired.DeviceID)
	}
	if info.Folders == nil {
		t.Fatal("folders should be an empty array, not null")
	}
}

func TestPairValidationDoesNotConsumeToken(t *testing.T) {
	h := newHarness(t)

	token, _, err := h.pairings.Issue()
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}

	rec := h.do(http.MethodPost, "/v1/pair", map[string]string{"token": token, "device_name": "  "}, "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}

	// A rejected *malformed* request must not burn the token: the user is still standing at
	// the PC with a valid QR code and would otherwise have to regenerate it.
	rec = h.do(http.MethodPost, "/v1/pair", map[string]string{"token": token, "device_name": "Pixel"}, "")
	if rec.Code != http.StatusCreated {
		t.Fatalf("token was consumed by a malformed request: status %d", rec.Code)
	}
}

func TestMultipleDevicesPairAndRevokeLocally(t *testing.T) {
	ident, err := identity.LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	pairings := pairing.NewManager(time.Minute)
	store := devices.NewStore()
	pairedCount := 0

	srv := api.New(api.Options{
		Identity: ident,
		Pairing:  pairings,
		Devices:  store,
		Folders:  folder.NewRegistry(),
		Volumes: func() ([]volume.Volume, error) {
			return []volume.Volume{{Name: "E:", Path: `E:\`}}, nil
		},
		LocalState:   func() api.LocalState { return api.LocalState{} },
		ListDevices:  func() []devices.Device { return store.List() },
		RevokeDevice: func(id string) error { _, err := store.RevokeWithError(id); return err },
		ListBackups:  func() []api.BackupInfo { return nil },
		OnPaired: func(device devices.Device) error {
			pairedCount++
			_, err := store.SetBackupConfig(device.ID, devices.BackupConfig{
				FolderID:  devices.BackupFolderID(device.ID),
				Subfolder: "CloudBox/" + device.Name,
				Root:      `E:\CloudBox\` + device.Name,
				Enabled:   true,
			})
			return err
		},
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	handler := srv.Handler()

	request := func(method, path string, body any, token string) *httptest.ResponseRecorder {
		var reader io.Reader
		if body != nil {
			raw, err := json.Marshal(body)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			reader = bytes.NewReader(raw)
		}
		req := httptest.NewRequest(method, path, reader)
		req.RemoteAddr = "127.0.0.1:5151" // local routes are loopback-only
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}

	pair := func(name string) (string, string) {
		t.Helper()
		code, _, err := pairings.Issue()
		if err != nil {
			t.Fatalf("issue pairing code: %v", err)
		}
		rec := request(http.MethodPost, "/v1/pair", map[string]string{
			"token": code, "device_name": name, "platform": "android",
		}, "")
		if rec.Code != http.StatusCreated {
			t.Fatalf("pair %s: status = %d body %s", name, rec.Code, rec.Body.String())
		}
		var body struct {
			DeviceID    string `json:"device_id"`
			DeviceToken string `json:"device_token"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode pair response: %v", err)
		}
		return body.DeviceID, body.DeviceToken
	}

	firstID, firstToken := pair("Pixel")
	secondID, secondToken := pair("iPhone")
	if firstToken == secondToken || firstID == secondID {
		t.Fatal("two pairings produced the same token or device id")
	}
	if pairedCount != 2 {
		t.Fatalf("OnPaired called %d times, want 2", pairedCount)
	}
	for _, id := range []string{firstID, secondID} {
		device, ok := store.Get(id)
		if !ok || !device.Backup.Enabled || device.Backup.FolderID != devices.BackupFolderID(id) {
			t.Fatalf("device %s was not initialised with a backup folder: %+v", id, device)
		}
	}

	rec := request(http.MethodGet, "/local/devices", nil, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("list devices: status = %d", rec.Code)
	}
	var listed struct {
		Devices []devices.Device `json:"devices"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &listed); err != nil {
		t.Fatalf("decode devices: %v", err)
	}
	if len(listed.Devices) != 2 {
		t.Fatalf("listed %d devices, want 2", len(listed.Devices))
	}

	rec = request(http.MethodDelete, "/local/devices/"+firstID, nil, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("revoke: status = %d body %s", rec.Code, rec.Body.String())
	}
	var deleted struct {
		Deleted bool `json:"deleted"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &deleted); err != nil || !deleted.Deleted {
		t.Fatalf("revoke response = %s err=%v", rec.Body.String(), err)
	}
	if rec := request(http.MethodGet, "/v1/system/info", nil, firstToken); rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked token still works: status = %d", rec.Code)
	}
	if rec := request(http.MethodGet, "/v1/system/info", nil, secondToken); rec.Code != http.StatusOK {
		t.Fatalf("other device's token stopped working: status = %d", rec.Code)
	}

	rec = request(http.MethodDelete, "/local/devices/"+firstID, nil, "")
	if rec.Code != http.StatusNotFound || decodeError(t, rec) != "DEVICE_NOT_FOUND" {
		t.Fatalf("revoke twice: status = %d code = %q", rec.Code, decodeError(t, rec))
	}
}

func TestVolumesErrorIsReported(t *testing.T) {
	ident, err := identity.LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("identity: %v", err)
	}

	pairings := pairing.NewManager(time.Minute)
	store := devices.NewStore()
	_, token, err := store.Create("Pixel", "android", "test")
	if err != nil {
		t.Fatalf("create device: %v", err)
	}

	srv := api.New(api.Options{
		Identity: ident,
		Pairing:  pairings,
		Devices:  store,
		Volumes: func() ([]volume.Volume, error) {
			return nil, io.ErrUnexpectedEOF
		},
		ServerName: "TEST-PC",
		Version:    "test-version",
	})

	req := httptest.NewRequest(http.MethodGet, "/v1/system/volumes", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
	if code := decodeError(t, rec); code != "VOLUMES_UNAVAILABLE" {
		t.Fatalf("error code = %q", code)
	}
}
