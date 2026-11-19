package destination

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/Gyakudos/CloudBox/agent/internal/folder"
	"github.com/Gyakudos/CloudBox/agent/internal/safepath"
	"github.com/Gyakudos/CloudBox/agent/internal/volume"
)

// testVolumes is a deterministic stand-in for the host's drives.
func testVolumes(t *testing.T) func() ([]volume.Volume, error) {
	t.Helper()
	root := t.TempDir()
	return func() ([]volume.Volume, error) {
		return []volume.Volume{
			{Name: "C:", Path: filepath.Join(root, "c")},
			{Name: "E:", Path: filepath.Join(root, "e")},
		}, nil
	}
}

func newManager(t *testing.T, vols func() ([]volume.Volume, error)) (*Manager, *folder.Registry) {
	t.Helper()
	registry := folder.NewRegistry()
	mgr := New(t.TempDir(), registry, vols, safepath.DefaultPolicy())
	return mgr, registry
}

func TestSetResolvesVolumeToDefaultSubfolder(t *testing.T) {
	vols := testVolumes(t)
	mgr, registry := newManager(t, vols)

	selected, err := mgr.Set("E:", "")
	if err != nil {
		t.Fatalf("Set: %v", err)
	}
	if selected.ID != DefaultID {
		t.Fatalf("folder id = %q, want %q", selected.ID, DefaultID)
	}
	if selected.Name != DefaultSubfolder {
		t.Fatalf("folder name = %q, want %q", selected.Name, DefaultSubfolder)
	}

	vol, _ := volume.Find(mustVolumes(t, vols), "E:")
	wantRoot := filepath.Join(vol.Path, DefaultSubfolder)
	if selected.Root != wantRoot {
		t.Fatalf("root = %q, want %q", selected.Root, wantRoot)
	}

	// The registry must now resolve the default ID to the chosen drive, so an upload created
	// with folder_id=default lands there.
	finalizer, ok := registry.Get(DefaultID)
	if !ok {
		t.Fatal("default folder is not registered")
	}
	if finalizer.Root != wantRoot {
		t.Fatalf("registered root = %q, want %q", finalizer.Root, wantRoot)
	}
}

func TestSetUsesNamedSubfolder(t *testing.T) {
	vols := testVolumes(t)
	mgr, _ := newManager(t, vols)

	selected, err := mgr.Set("C:", "Backups/Photos")
	if err != nil {
		t.Fatalf("Set: %v", err)
	}
	vol, _ := volume.Find(mustVolumes(t, vols), "C:")
	want := filepath.Join(vol.Path, "Backups", "Photos")
	if selected.Root != want {
		t.Fatalf("root = %q, want %q", selected.Root, want)
	}
}

func TestCurrentChoiceTracksAdoptAndSet(t *testing.T) {
	vols := testVolumes(t)
	mgr, _ := newManager(t, vols)

	if _, ok := mgr.CurrentChoice(); ok {
		t.Fatal("CurrentChoice = ok before any destination was adopted")
	}

	adopted, err := mgr.Adopt(filepath.Join(t.TempDir(), "CloudBox"), "CloudBox")
	if err != nil {
		t.Fatalf("Adopt: %v", err)
	}
	choice, ok := mgr.CurrentChoice()
	if !ok {
		t.Fatal("CurrentChoice = !ok after Adopt")
	}
	if choice.Root != adopted.Root || choice.Volume != "" || choice.Subfolder != "CloudBox" {
		t.Fatalf("choice after Adopt = %+v", choice)
	}

	if _, err := mgr.Set("E:", "Backups"); err != nil {
		t.Fatalf("Set: %v", err)
	}
	choice, ok = mgr.CurrentChoice()
	if !ok {
		t.Fatal("CurrentChoice = !ok after Set")
	}
	if choice.Volume != "E:" || choice.Subfolder != "Backups" || choice.Root == adopted.Root {
		t.Fatalf("choice after Set = %+v", choice)
	}
}

func TestCurrentChoiceRestoresPersistedVolume(t *testing.T) {
	vols := testVolumes(t)
	registry := folder.NewRegistry()
	dir := t.TempDir()
	mgr := New(dir, registry, vols, safepath.DefaultPolicy())
	if _, err := mgr.Set("E:", "Backups"); err != nil {
		t.Fatalf("Set: %v", err)
	}

	restored := New(dir, folder.NewRegistry(), vols, safepath.DefaultPolicy())
	if _, ok, err := restored.Restore(); err != nil || !ok {
		t.Fatalf("Restore: ok=%v err=%v", ok, err)
	}
	choice, ok := restored.CurrentChoice()
	if !ok {
		t.Fatal("CurrentChoice = !ok after Restore")
	}
	if choice.Volume != "E:" || choice.Subfolder != "Backups" {
		t.Fatalf("restored choice = %+v", choice)
	}
}

func TestSetForIDLeavesGlobalChoiceAlone(t *testing.T) {
	vols := testVolumes(t)
	dir := t.TempDir()
	registry := folder.NewRegistry()
	mgr := New(dir, registry, vols, safepath.DefaultPolicy())

	if _, err := mgr.Set("C:", "Global"); err != nil {
		t.Fatalf("Set default: %v", err)
	}
	global, _ := mgr.CurrentChoice()

	perDevice, dest, err := mgr.SetForID("backup-device-1", "E:", "Phone")
	if err != nil {
		t.Fatalf("SetForID: %v", err)
	}
	if perDevice.ID != "backup-device-1" || dest.Volume != "E:" || dest.Subfolder != "Phone" {
		t.Fatalf("per-device result = %+v / %+v", perDevice, dest)
	}
	vol, _ := volume.Find(mustVolumes(t, vols), "E:")
	if want := filepath.Join(vol.Path, "Phone"); perDevice.Root != want {
		t.Fatalf("per-device root = %q, want %q", perDevice.Root, want)
	}
	if finalizer, ok := registry.Get("backup-device-1"); !ok || finalizer.Root != perDevice.Root {
		t.Fatal("per-device folder was not registered")
	}

	after, ok := mgr.CurrentChoice()
	if !ok || after != global {
		t.Fatalf("global choice changed: before %+v after %+v", global, after)
	}
	persisted, ok, err := load(dir)
	if err != nil || !ok || persisted.Volume != "C:" || persisted.Subfolder != "Global" {
		t.Fatalf("destination.json changed: %+v ok=%v err=%v", persisted, ok, err)
	}
}

func TestSetRejectsUnknownVolume(t *testing.T) {
	mgr, _ := newManager(t, testVolumes(t))

	_, err := mgr.Set("Z:", "")
	if !errors.Is(err, ErrUnknownVolume) {
		t.Fatalf("error = %v, want ErrUnknownVolume", err)
	}
}

func TestSetRejectsUnsafeSubfolder(t *testing.T) {
	mgr, _ := newManager(t, testVolumes(t))

	for _, subfolder := range []string{"../escape", "/etc", `C:\Windows`, ".."} {
		if _, err := mgr.Set("C:", subfolder); !errors.Is(err, ErrInvalidSubfolder) {
			t.Errorf("subfolder %q: error = %v, want ErrInvalidSubfolder", subfolder, err)
		}
	}
}

func TestSetPersistsAcrossManagers(t *testing.T) {
	vols := testVolumes(t)
	registry := folder.NewRegistry()
	dir := t.TempDir()
	mgr := New(dir, registry, vols, safepath.DefaultPolicy())

	selected, err := mgr.Set("E:", "CloudBox")
	if err != nil {
		t.Fatalf("Set: %v", err)
	}

	// A fresh manager, as if the agent had restarted, must come back to the same root.
	restartedRegistry := folder.NewRegistry()
	restarted := New(dir, restartedRegistry, vols, safepath.DefaultPolicy())
	restored, ok, err := restarted.Restore()
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if !ok {
		t.Fatal("Restore found no persisted destination")
	}
	if restored.Root != selected.Root {
		t.Fatalf("restored root = %q, want %q", restored.Root, selected.Root)
	}
	persisted, ok, err := load(dir)
	if err != nil || !ok {
		t.Fatalf("load: (%v, %v)", ok, err)
	}
	if persisted.Volume != "E:" || persisted.Subfolder != "CloudBox" {
		t.Fatalf("persisted = %+v, want volume E: and subfolder CloudBox", persisted)
	}
	if _, ok := restartedRegistry.Get(DefaultID); !ok {
		t.Fatal("restored destination was not registered")
	}
}

func TestRestoreWithoutPersistedChoice(t *testing.T) {
	mgr, _ := newManager(t, testVolumes(t))

	if _, ok, err := mgr.Restore(); err != nil || ok {
		t.Fatalf("Restore on a first run = (%v, %v), want (false, nil)", ok, err)
	}
}

func TestAdoptRegistersExplicitRoot(t *testing.T) {
	mgr, registry := newManager(t, testVolumes(t))
	root := t.TempDir()

	adopted, err := mgr.Adopt(root, "MyBackups")
	if err != nil {
		t.Fatalf("Adopt: %v", err)
	}
	if adopted.Root != root || adopted.Name != "MyBackups" {
		t.Fatalf("adopted = %+v", adopted)
	}
	if finalizer, ok := registry.Get(DefaultID); !ok || finalizer.Root != root {
		t.Fatalf("registry root = %v, want %q", ok, root)
	}

	// Adopt must not persist: an explicit --sync-root wins on every start.
	if _, ok, _ := mgr.Restore(); ok {
		t.Fatal("Adopt persisted a choice; an explicit flag should not be remembered")
	}
}

func mustVolumes(t *testing.T, fn func() ([]volume.Volume, error)) []volume.Volume {
	t.Helper()
	vols, err := fn()
	if err != nil {
		t.Fatalf("volumes: %v", err)
	}
	return vols
}
