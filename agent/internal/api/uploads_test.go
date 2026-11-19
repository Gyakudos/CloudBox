package api_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/api"
	"github.com/Gyakudos/CloudBox/agent/internal/blob"
	"github.com/Gyakudos/CloudBox/agent/internal/devices"
	"github.com/Gyakudos/CloudBox/agent/internal/folder"
	"github.com/Gyakudos/CloudBox/agent/internal/identity"
	"github.com/Gyakudos/CloudBox/agent/internal/pairing"
	"github.com/Gyakudos/CloudBox/agent/internal/safepath"
	"github.com/Gyakudos/CloudBox/agent/internal/volume"
)

const testFolderID = "f-test"

type uploadHarness struct {
	handler http.Handler
	blobs   *blob.Store
	root    string
	token   string
}

func newUploadHarness(t *testing.T) *uploadHarness {
	t.Helper()

	ident, err := identity.LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	store, err := blob.Open(t.TempDir(), blob.DefaultMaxSize)
	if err != nil {
		t.Fatalf("blob.Open: %v", err)
	}

	root := t.TempDir()
	finalizer, err := folder.New(root, safepath.Policy{MaxSegmentBytes: safepath.DefaultMaxSegmentBytes})
	if err != nil {
		t.Fatalf("folder.New: %v", err)
	}
	folders := folder.NewRegistry()
	if err := folders.Register(testFolderID, "Camera", finalizer); err != nil {
		t.Fatalf("register folder: %v", err)
	}

	devicesStore := devices.NewStore()
	device, token, err := devicesStore.Create("TestPhone", "android", "test")
	if err != nil {
		t.Fatalf("create device: %v", err)
	}
	_ = device

	srv := api.New(api.Options{
		Identity:   ident,
		Pairing:    pairing.NewManager(time.Minute),
		Devices:    devicesStore,
		Blobs:      store,
		Folders:    folders,
		Volumes:    func() ([]volume.Volume, error) { return nil, nil },
		ServerName: "TEST-PC",
		Version:    "test-version",
		StartedAt:  time.Now(),
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	})

	return &uploadHarness{handler: srv.Handler(), blobs: store, root: root, token: token}
}

func (h *uploadHarness) json(method, path string, body any) *httptest.ResponseRecorder {
	raw, _ := json.Marshal(body)
	req := httptest.NewRequest(method, path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if h.token != "" {
		req.Header.Set("Authorization", "Bearer "+h.token)
	}
	rec := httptest.NewRecorder()
	h.handler.ServeHTTP(rec, req)
	return rec
}

func (h *uploadHarness) patch(uploadID string, start int64, total int64, chunk []byte) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPatch, "/v1/uploads/"+uploadID, bytes.NewReader(chunk))
	req.Header.Set("Authorization", "Bearer "+h.token)
	req.Header.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, start+int64(len(chunk))-1, total))
	rec := httptest.NewRecorder()
	h.handler.ServeHTTP(rec, req)
	return rec
}

func (h *uploadHarness) create(hash string, size int64, folderID string) createResponse {
	rec := h.json(http.MethodPost, "/v1/uploads", map[string]any{
		"hash": hash, "size": size, "folder_id": folderID,
	})
	if rec.Code != http.StatusCreated {
		panic(fmt.Sprintf("create upload: status %d body %s", rec.Code, rec.Body.String()))
	}
	var out createResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		panic(err)
	}
	return out
}

type createResponse struct {
	UploadID string `json:"upload_id"`
	Offset   int64  `json:"offset"`
	Complete bool   `json:"complete"`
}

func hashBytes(t *testing.T, data []byte) string {
	t.Helper()
	sum, err := blob.Hash(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	return sum
}

func TestUploadHappyPath(t *testing.T) {
	h := newUploadHarness(t)
	data := []byte("the quick brown fox jumps over the lazy dog")
	hash := hashBytes(t, data)
	mtime := time.Date(2026, 5, 6, 7, 8, 9, 0, time.UTC)

	created := h.create(hash, int64(len(data)), testFolderID)
	if created.Offset != 0 {
		t.Fatalf("initial offset = %d, want 0", created.Offset)
	}

	// Split across two PATCHes.
	mid := len(data) / 2
	if rec := h.patch(created.UploadID, 0, int64(len(data)), data[:mid]); rec.Code != http.StatusOK {
		t.Fatalf("first patch: status %d body %s", rec.Code, rec.Body.String())
	}

	// Status must report the resume point after a dropped connection.
	rec := h.json(http.MethodGet, "/v1/uploads/"+created.UploadID, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status: %d", rec.Code)
	}
	var status struct {
		Offset int64 `json:"offset"`
	}
	json.Unmarshal(rec.Body.Bytes(), &status)
	if status.Offset != int64(mid) {
		t.Fatalf("resume offset = %d, want %d", status.Offset, mid)
	}

	if rec := h.patch(created.UploadID, int64(mid), int64(len(data)), data[mid:]); rec.Code != http.StatusOK {
		t.Fatalf("second patch: status %d body %s", rec.Code, rec.Body.String())
	}

	rec = h.json(http.MethodPost, "/v1/uploads/"+created.UploadID+"/commit", map[string]any{
		"hash": hash, "path": "DCIM/Camera/IMG_0001.jpg", "mtime_ms": mtime.UnixMilli(),
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("commit: status %d body %s", rec.Code, rec.Body.String())
	}
	var committed struct {
		Committed bool   `json:"committed"`
		Path      string `json:"path"`
	}
	json.Unmarshal(rec.Body.Bytes(), &committed)
	if !committed.Committed {
		t.Fatal("commit did not report success")
	}

	onDisk := filepath.Join(h.root, "DCIM", "Camera", "IMG_0001.jpg")
	got, err := os.ReadFile(onDisk)
	if err != nil {
		t.Fatalf("read finalized file: %v", err)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("finalized bytes differ from what was uploaded")
	}
	info, _ := os.Stat(onDisk)
	if !info.ModTime().Equal(mtime) {
		t.Errorf("mtime = %v, want the source mtime %v", info.ModTime(), mtime)
	}
}

func TestUploadOffsetConflictReportsResumePoint(t *testing.T) {
	h := newUploadHarness(t)
	data := []byte("0123456789")
	hash := hashBytes(t, data)
	created := h.create(hash, int64(len(data)), testFolderID)

	if rec := h.patch(created.UploadID, 0, int64(len(data)), data[:4]); rec.Code != http.StatusOK {
		t.Fatalf("first patch: %d", rec.Code)
	}

	// Claim to be at 0 again; the server must answer 409 and say where to resume.
	rec := h.patch(created.UploadID, 0, int64(len(data)), data[4:])
	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409; body %s", rec.Code, rec.Body.String())
	}
	var conflict struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
		Offset int64 `json:"offset"`
	}
	json.Unmarshal(rec.Body.Bytes(), &conflict)
	if conflict.Error.Code != "OFFSET_MISMATCH" {
		t.Fatalf("code = %q, want OFFSET_MISMATCH", conflict.Error.Code)
	}
	if conflict.Offset != 4 {
		t.Fatalf("resume offset = %d, want 4", conflict.Offset)
	}
}

func TestUploadHashMismatchIsRejected(t *testing.T) {
	h := newUploadHarness(t)
	real := []byte("this is the real content")
	claimed := hashBytes(t, []byte("this is different content"))

	created := h.create(claimed, int64(len(real)), testFolderID)
	if rec := h.patch(created.UploadID, 0, int64(len(real)), real); rec.Code != http.StatusOK {
		t.Fatalf("patch: %d body %s", rec.Code, rec.Body.String())
	}

	rec := h.json(http.MethodPost, "/v1/uploads/"+created.UploadID+"/commit", map[string]any{
		"hash": claimed, "path": "evil.bin",
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422; body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "HASH_MISMATCH") {
		t.Fatalf("body = %s, want HASH_MISMATCH", rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(h.root, "evil.bin")); !os.IsNotExist(err) {
		t.Fatal("a corrupt upload reached the sync folder")
	}
}

func TestUploadCommitRejectsTraversalPath(t *testing.T) {
	h := newUploadHarness(t)
	data := []byte("payload")
	hash := hashBytes(t, data)

	created := h.create(hash, int64(len(data)), testFolderID)
	if rec := h.patch(created.UploadID, 0, int64(len(data)), data); rec.Code != http.StatusOK {
		t.Fatalf("patch: %d", rec.Code)
	}

	rec := h.json(http.MethodPost, "/v1/uploads/"+created.UploadID+"/commit", map[string]any{
		"hash": hash, "path": "../../escape.txt",
	})
	if rec.Code == http.StatusOK {
		t.Fatalf("traversal path was accepted: %s", rec.Body.String())
	}

	// Nothing may exist outside the root.
	if _, err := os.Stat(filepath.Join(filepath.Dir(h.root), "escape.txt")); !os.IsNotExist(err) {
		t.Fatal("traversal escaped the sync root")
	}
}

func TestUploadRejectsUnknownFolder(t *testing.T) {
	h := newUploadHarness(t)
	rec := h.json(http.MethodPost, "/v1/uploads", map[string]any{
		"hash": hashBytes(t, []byte("x")), "size": 1, "folder_id": "does-not-exist",
	})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestUploadDedupeSkipsTransfer(t *testing.T) {
	h := newUploadHarness(t)
	data := []byte("a photo already on the server")
	hash := hashBytes(t, data)

	first := h.create(hash, int64(len(data)), testFolderID)
	if rec := h.patch(first.UploadID, 0, int64(len(data)), data); rec.Code != http.StatusOK {
		t.Fatalf("patch: %d", rec.Code)
	}
	if rec := h.json(http.MethodPost, "/v1/uploads/"+first.UploadID+"/commit", map[string]any{
		"hash": hash, "path": "one.jpg",
	}); rec.Code != http.StatusOK {
		t.Fatalf("commit: %d body %s", rec.Code, rec.Body.String())
	}

	// The same bytes again: the server should say "complete", costing zero bandwidth, and the
	// commit must still place the content — a metadata-only copy out of the cache.
	second := h.create(hash, int64(len(data)), testFolderID)
	if !second.Complete {
		t.Fatal("second upload of identical content was not reported as complete")
	}
	if second.UploadID == "" {
		t.Fatal("a deduped upload must still carry an upload_id so it can be committed")
	}
	if second.Offset != int64(len(data)) {
		t.Fatalf("deduped offset = %d, want %d", second.Offset, len(data))
	}

	rec := h.json(http.MethodPost, "/v1/uploads/"+second.UploadID+"/commit", map[string]any{
		"hash": hash, "path": "two.jpg",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("deduped commit: status %d body %s", rec.Code, rec.Body.String())
	}
	var committed struct {
		Committed bool `json:"committed"`
		Deduped   bool `json:"deduped"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &committed); err != nil {
		t.Fatalf("decode commit: %v", err)
	}
	if !committed.Committed || !committed.Deduped {
		t.Fatalf("commit = %+v, want committed and deduped", committed)
	}

	// The second path must now hold the same bytes, despite no PATCH ever being sent.
	onDisk, err := os.ReadFile(filepath.Join(h.root, "two.jpg"))
	if err != nil {
		t.Fatalf("deduped file was not finalized: %v", err)
	}
	if !bytes.Equal(onDisk, data) {
		t.Fatal("deduped file content differs from the original")
	}
}

func TestTwoDevicesUseSeparateBackupRoots(t *testing.T) {
	ident, err := identity.LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	store, err := blob.Open(t.TempDir(), blob.DefaultMaxSize)
	if err != nil {
		t.Fatalf("blob.Open: %v", err)
	}

	rootA := t.TempDir()
	rootB := t.TempDir()
	sharedRoot := t.TempDir()
	folders := folder.NewRegistry()
	register := func(id, root string) {
		t.Helper()
		finalizer, err := folder.New(root, safepath.DefaultPolicy())
		if err != nil {
			t.Fatalf("folder.New(%s): %v", root, err)
		}
		if err := folders.Register(id, id, finalizer); err != nil {
			t.Fatalf("register %s: %v", id, err)
		}
	}
	register("shared", sharedRoot)

	deviceStore := devices.NewStore()
	first, tokenA, err := deviceStore.Create("Pixel", "android", "v")
	if err != nil {
		t.Fatalf("create first: %v", err)
	}
	second, tokenB, err := deviceStore.Create("iPhone", "ios", "v")
	if err != nil {
		t.Fatalf("create second: %v", err)
	}
	if _, err := deviceStore.SetBackupConfig(first.ID, devices.BackupConfig{
		FolderID: devices.BackupFolderID(first.ID), Root: rootA, Enabled: true,
	}); err != nil {
		t.Fatalf("backup for first: %v", err)
	}
	if _, err := deviceStore.SetBackupConfig(second.ID, devices.BackupConfig{
		FolderID: devices.BackupFolderID(second.ID), Root: rootB, Enabled: true,
	}); err != nil {
		t.Fatalf("backup for second: %v", err)
	}
	register(devices.BackupFolderID(first.ID), rootA)
	register(devices.BackupFolderID(second.ID), rootB)

	handler := api.New(api.Options{
		Identity:   ident,
		Pairing:    pairing.NewManager(time.Minute),
		Devices:    deviceStore,
		Blobs:      store,
		Folders:    folders,
		Volumes:    func() ([]volume.Volume, error) { return nil, nil },
		ServerName: "TEST-PC",
		Version:    "test-version",
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	}).Handler()

	request := func(method, path string, body any, token string) *httptest.ResponseRecorder {
		t.Helper()
		var reader io.Reader
		if body != nil {
			raw, err := json.Marshal(body)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			reader = bytes.NewReader(raw)
		}
		req := httptest.NewRequest(method, path, reader)
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}

	upload := func(token string, data []byte, relPath string) {
		t.Helper()
		hash := hashBytes(t, data)
		// Both phones claim the same folder_id; the per-device backup config must win.
		rec := request(http.MethodPost, "/v1/uploads", map[string]any{
			"hash": hash, "size": len(data), "folder_id": "shared",
		}, token)
		if rec.Code != http.StatusCreated {
			t.Fatalf("create: status = %d body %s", rec.Code, rec.Body.String())
		}
		var created createResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
			t.Fatalf("decode create: %v", err)
		}

		req := httptest.NewRequest(http.MethodPatch, "/v1/uploads/"+created.UploadID, bytes.NewReader(data))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Range", fmt.Sprintf("bytes 0-%d/%d", len(data)-1, len(data)))
		rec = httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("patch: status = %d body %s", rec.Code, rec.Body.String())
		}

		rec = request(http.MethodPost, "/v1/uploads/"+created.UploadID+"/commit", map[string]any{
			"hash": hash, "path": relPath,
		}, token)
		if rec.Code != http.StatusOK {
			t.Fatalf("commit: status = %d body %s", rec.Code, rec.Body.String())
		}
	}

	upload(tokenA, []byte("pixel photo bytes"), "DCIM/pixel.jpg")
	upload(tokenB, []byte("iphone photo bytes"), "DCIM/iphone.jpg")

	if got, err := os.ReadFile(filepath.Join(rootA, "DCIM", "pixel.jpg")); err != nil || string(got) != "pixel photo bytes" {
		t.Fatalf("first phone's file: %q err=%v", got, err)
	}
	if got, err := os.ReadFile(filepath.Join(rootB, "DCIM", "iphone.jpg")); err != nil || string(got) != "iphone photo bytes" {
		t.Fatalf("second phone's file: %q err=%v", got, err)
	}
	if _, err := os.Stat(filepath.Join(rootA, "DCIM", "iphone.jpg")); !os.IsNotExist(err) {
		t.Fatal("second phone's file landed in the first phone's root")
	}
	if _, err := os.Stat(filepath.Join(rootB, "DCIM", "pixel.jpg")); !os.IsNotExist(err) {
		t.Fatal("first phone's file landed in the second phone's root")
	}
	if entries, err := os.ReadDir(sharedRoot); err != nil || len(entries) != 0 {
		t.Fatalf("the shared fallback folder received files: %v err=%v", entries, err)
	}
}

func TestUploadRequiresAuth(t *testing.T) {
	h := newUploadHarness(t)
	h.token = ""
	rec := h.json(http.MethodPost, "/v1/uploads", map[string]any{
		"hash": hashBytes(t, []byte("x")), "size": 1, "folder_id": testFolderID,
	})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestUploadMissingContentRange(t *testing.T) {
	h := newUploadHarness(t)
	data := []byte("abcd")
	created := h.create(hashBytes(t, data), int64(len(data)), testFolderID)

	req := httptest.NewRequest(http.MethodPatch, "/v1/uploads/"+created.UploadID, bytes.NewReader(data))
	req.Header.Set("Authorization", "Bearer "+h.token)
	rec := httptest.NewRecorder()
	h.handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}
