package devices

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Gyakudos/CloudBox/agent/internal/destination"
)

func TestCreateAndAuthenticate(t *testing.T) {
	store := NewStore()

	device, token, err := store.Create("Pixel 8", "android", "test-version")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if device.ID == "" || device.Name != "Pixel 8" || device.Platform != "android" {
		t.Fatalf("unexpected device: %+v", device)
	}
	if token == "" {
		t.Fatal("Create returned an empty token")
	}
	if device.CreatedAt.IsZero() {
		t.Fatal("CreatedAt was not set")
	}

	resolved, ok := store.Authenticate(token)
	if !ok {
		t.Fatal("Authenticate rejected a freshly issued token")
	}
	if resolved.ID != device.ID {
		t.Fatalf("Authenticate returned device %q, want %q", resolved.ID, device.ID)
	}
}

func TestAuthenticateRejectsBadTokens(t *testing.T) {
	store := NewStore()
	if _, _, err := store.Create("Pixel", "android", "v"); err != nil {
		t.Fatalf("Create: %v", err)
	}

	for _, token := range []string{"", "wrong", "  "} {
		if _, ok := store.Authenticate(token); ok {
			t.Errorf("Authenticate(%q) succeeded", token)
		}
	}
}

func TestTokensAreUnique(t *testing.T) {
	store := NewStore()

	seen := make(map[string]bool, 16)
	for i := 0; i < 16; i++ {
		_, token, err := store.Create("phone", "android", "v")
		if err != nil {
			t.Fatalf("Create %d: %v", i, err)
		}
		if seen[token] {
			t.Fatalf("duplicate token: %q", token)
		}
		seen[token] = true
	}
}

func TestRevokeInvalidatesToken(t *testing.T) {
	store := NewStore()

	device, token, err := store.Create("Pixel", "android", "v")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if !store.Revoke(device.ID) {
		t.Fatal("Revoke returned false for a known device")
	}
	if _, ok := store.Authenticate(token); ok {
		t.Fatal("token still authenticates after revoke")
	}
	if store.Revoke(device.ID) {
		t.Fatal("Revoke returned true for an already-revoked device")
	}
	if got := len(store.List()); got != 0 {
		t.Fatalf("List has %d devices after revoke, want 0", got)
	}
}

// fakeResolver keeps backup-config tests independent of the host's actual drives.
func fakeResolver(volumeName, subfolder string) (destination.Destination, error) {
	return destination.Destination{
		Volume:    volumeName,
		Subfolder: subfolder,
		Root:      filepath.Join(volumeName, filepath.FromSlash(subfolder)),
	}, nil
}

func TestNewStoreAtFirstRun(t *testing.T) {
	store, err := NewStoreAt(t.TempDir())
	if err != nil {
		t.Fatalf("NewStoreAt on an empty dir: %v", err)
	}
	if len(store.List()) != 0 {
		t.Fatalf("first run has %d devices, want 0", len(store.List()))
	}
}

func TestPersistenceRoundTrip(t *testing.T) {
	dir := t.TempDir()
	store, err := NewStoreAt(dir)
	if err != nil {
		t.Fatalf("NewStoreAt: %v", err)
	}
	store.resolve = fakeResolver

	first, firstToken, err := store.Create("Pixel 8", "android", "v1")
	if err != nil {
		t.Fatalf("Create first: %v", err)
	}
	second, secondToken, err := store.Create("iPhone", "ios", "v2")
	if err != nil {
		t.Fatalf("Create second: %v", err)
	}
	if firstToken == secondToken {
		t.Fatal("two devices received the same token")
	}

	if _, err := store.UpdateBackup(first.ID, "E:", "CloudBox/Pixel", true); err != nil {
		t.Fatalf("UpdateBackup first: %v", err)
	}
	if _, err := store.UpdateBackup(second.ID, "E:", "CloudBox/iPhone", true); err != nil {
		t.Fatalf("UpdateBackup second: %v", err)
	}

	raw, err := os.ReadFile(filepath.Join(dir, "devices.json"))
	if err != nil {
		t.Fatalf("read devices.json: %v", err)
	}
	if !strings.Contains(string(raw), `"token_hash"`) {
		t.Fatal("devices.json does not store token hashes")
	}
	if strings.Contains(string(raw), firstToken) || strings.Contains(string(raw), secondToken) {
		t.Fatal("devices.json contains a plaintext token")
	}

	reloaded, err := NewStoreAt(dir)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if got, ok := reloaded.Authenticate(firstToken); !ok || got.ID != first.ID {
		t.Fatalf("first token did not survive reload: device=%+v ok=%v", got, ok)
	}
	if got, ok := reloaded.Authenticate(secondToken); !ok || got.ID != second.ID {
		t.Fatalf("second token did not survive reload: device=%+v ok=%v", got, ok)
	}

	savedFirst, ok := reloaded.Get(first.ID)
	if !ok {
		t.Fatal("first device missing after reload")
	}
	if want := BackupFolderID(first.ID); savedFirst.Backup.FolderID != want {
		t.Fatalf("backup folder id = %q, want %q", savedFirst.Backup.FolderID, want)
	}
	if savedFirst.Backup.Volume != "E:" || savedFirst.Backup.Subfolder != "CloudBox/Pixel" ||
		savedFirst.Backup.Root != filepath.Join("E:", "CloudBox", "Pixel") || !savedFirst.Backup.Enabled {
		t.Fatalf("first backup config = %+v", savedFirst.Backup)
	}
	savedSecond, ok := reloaded.Get(second.ID)
	if !ok || savedSecond.Backup.Subfolder != "CloudBox/iPhone" {
		t.Fatalf("second backup config = %+v ok=%v", savedSecond.Backup, ok)
	}

	// Revoke must be durable too.
	if ok, err := reloaded.RevokeWithError(first.ID); !ok || err != nil {
		t.Fatalf("revoke first: ok=%v err=%v", ok, err)
	}
	afterRevoke, err := NewStoreAt(dir)
	if err != nil {
		t.Fatalf("reload after revoke: %v", err)
	}
	if _, ok := afterRevoke.Authenticate(firstToken); ok {
		t.Fatal("revoked token still authenticates after reload")
	}
	if _, ok := afterRevoke.Authenticate(secondToken); !ok {
		t.Fatal("other device's token was lost after revoke")
	}
	if _, err := afterRevoke.RevokeWithError("no-such-id"); err == nil {
		t.Fatal("revoking an unknown id did not report an error")
	}
}

func TestListIsDeterministicAndNewestFirst(t *testing.T) {
	store := NewStore()
	first, _, err := store.Create("old", "android", "v")
	if err != nil {
		t.Fatalf("Create old: %v", err)
	}
	second, _, err := store.Create("new", "android", "v")
	if err != nil {
		t.Fatalf("Create new: %v", err)
	}

	got := store.List()
	if len(got) != 2 {
		t.Fatalf("List length = %d, want 2", len(got))
	}
	again := store.List()
	for i := range got {
		if got[i].ID != again[i].ID {
			t.Fatal("List order is not deterministic")
		}
	}
	if got[0].ID != second.ID || got[1].ID != first.ID {
		t.Fatalf("List order = %v, want newest first", []string{got[0].Name, got[1].Name})
	}
}

func TestTouchAndBackupHelpers(t *testing.T) {
	store := NewStore()
	store.resolve = fakeResolver
	device, token, err := store.Create("Pixel", "android", "v")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	store.Touch(device.ID)
	seen, ok := store.Get(device.ID)
	if !ok || seen.LastSeenAt.IsZero() {
		t.Fatalf("Touch did not record last_seen_at: %+v ok=%v", seen, ok)
	}

	if _, ok := store.BackupConfigForToken(token); ok {
		t.Fatal("a device with no backup config was reported as configured")
	}
	if _, err := store.UpdateBackup(device.ID, "E:", "CloudBox", true); err != nil {
		t.Fatalf("UpdateBackup: %v", err)
	}
	if cfg, ok := store.BackupConfigForToken(token); !ok || cfg.FolderID != BackupFolderID(device.ID) {
		t.Fatalf("BackupConfigForToken = %+v ok=%v", cfg, ok)
	}
	if _, err := store.UpdateBackup("missing", "E:", "CloudBox", true); err == nil {
		t.Fatal("UpdateBackup on an unknown device did not fail")
	}
}
