package main

import (
	"io"
	"log/slog"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Gyakudos/CloudBox/agent/internal/devices"
	"github.com/Gyakudos/CloudBox/agent/internal/folder"
)

func TestDisplayAddr(t *testing.T) {
	for _, tc := range []struct {
		addr string
		port int
		want string
	}{
		{addr: ":8443", port: 8443, want: "0.0.0.0:8443"},
		{addr: "127.0.0.1:18443", port: 18443, want: "127.0.0.1:18443"},
		{addr: "0.0.0.0:18444", port: 18444, want: "0.0.0.0:18444"},
		{addr: "[::1]:8443", port: 8443, want: "[::1]:8443"},
		{addr: "not-an-address", port: 8443, want: "0.0.0.0:8443"},
	} {
		if got := displayAddr(tc.addr, tc.port); got != tc.want {
			t.Errorf("displayAddr(%q, %d) = %q, want %q", tc.addr, tc.port, got, tc.want)
		}
	}
}

// A destination chosen on the PC must reach every paired phone: the phone no longer picks a drive
// itself, so the PC's Storage screen is the only place that can move its backup folder. The updater
// is injected so the test does not depend on which drives the CI machine happens to have.
func TestFollowDestination(t *testing.T) {
	store := devices.NewStore()
	phone, _, err := store.Create("Pixel", "android", "test")
	if err != nil {
		t.Fatal(err)
	}
	folders := folder.NewRegistry()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	root := filepath.Join(t.TempDir(), "CloudBoxFollowTest")

	update := func(id, volume, subfolder string, enabled bool) (devices.Device, error) {
		return store.SetBackupConfig(id, devices.BackupConfig{
			FolderID:  devices.BackupFolderID(id),
			Volume:    volume,
			Subfolder: subfolder,
			Root:      root,
			Enabled:   enabled,
		})
	}
	followDestinationWith(store, folders, logger, "TestVolume", "CloudBoxFollowTest", update)

	updated, ok := store.Get(phone.ID)
	if !ok {
		t.Fatal("device disappeared from the store")
	}
	if !updated.Backup.Enabled {
		t.Fatal("backup was not enabled for the paired phone")
	}
	if updated.Backup.FolderID != devices.BackupFolderID(phone.ID) {
		t.Fatalf("folder id = %q, want %q", updated.Backup.FolderID, devices.BackupFolderID(phone.ID))
	}
	if !strings.Contains(updated.Backup.Root, "CloudBoxFollowTest") {
		t.Fatalf("backup root %q does not use the chosen subfolder", updated.Backup.Root)
	}
	if _, ok := folders.Get(updated.Backup.FolderID); !ok {
		t.Fatal("updated backup folder was not registered for uploads")
	}
}
