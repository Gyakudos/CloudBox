// Package destination owns the one decision the drive picker makes: which drive, and which
// folder on it, receives backups.
//
// The phone never sends a filesystem path. It sends the *name* of a volume the agent itself
// enumerated, and this package resolves that name against a fresh enumeration, so a client can
// only ever write to a drive it was actually shown — never to an arbitrary location, and never
// to a drive that has since been unplugged. The resolved root is registered in the folder
// registry under a fixed ID, and the choice is persisted so a restart remembers it.
package destination

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/Gyakudos/CloudBox/agent/internal/folder"
	"github.com/Gyakudos/CloudBox/agent/internal/safepath"
	"github.com/Gyakudos/CloudBox/agent/internal/volume"
)

const (
	// DefaultID is the folder ID the phone uses for the drive the user picked.
	DefaultID = "default"
	// DefaultSubfolder is the folder created on the chosen drive when none is named.
	DefaultSubfolder = "CloudBox"
	// fileName is where the persisted choice lives inside the agent's data directory.
	fileName = "destination.json"
)

var (
	// ErrUnknownVolume is returned when a destination names a volume the host does not have,
	// which is what a stale drive picker or an unplugged drive looks like.
	ErrUnknownVolume = errors.New("destination: unknown volume")
	// ErrInvalidSubfolder is returned when the requested folder name is not a safe relative
	// path (absolute, containing "..", or otherwise unrepresentable).
	ErrInvalidSubfolder = errors.New("destination: invalid subfolder")
)

// Destination is a resolved choice: the volume it names, the subfolder within it, and the
// absolute root backups land in.
type Destination struct {
	Volume    string `json:"volume"`
	Subfolder string `json:"subfolder"`
	Root      string `json:"root"`
}

// Manager resolves and remembers the default sync folder.
type Manager struct {
	dir     string
	folders *folder.Registry
	volumes func() ([]volume.Volume, error)
	policy  safepath.Policy

	mu      sync.Mutex
	current folder.Folder
}

// New returns a Manager that registers its choice in folders and persists it under dir.
func New(dir string, folders *folder.Registry, volumes func() ([]volume.Volume, error), policy safepath.Policy) *Manager {
	return &Manager{dir: dir, folders: folders, volumes: volumes, policy: policy}
}

// Adopt registers an explicitly configured root (from --sync-root) as the default folder. It is
// not persisted: an explicit flag is the operator's decision and should win on every start.
func (m *Manager) Adopt(root, name string) (folder.Folder, error) {
	finalizer, err := folder.New(root, m.policy)
	if err != nil {
		return folder.Folder{}, err
	}
	if name == "" {
		name = DefaultSubfolder
	}
	if err := m.folders.Register(DefaultID, name, finalizer); err != nil {
		return folder.Folder{}, err
	}
	return m.record(folder.Folder{ID: DefaultID, Name: name, Root: finalizer.Root}), nil
}

// Set resolves volumeName and subfolder to a sync root, points the default folder at it, and
// persists the choice. An empty subfolder falls back to DefaultSubfolder.
func (m *Manager) Set(volumeName, subfolder string) (folder.Folder, error) {
	vols, err := m.volumes()
	if err != nil {
		return folder.Folder{}, fmt.Errorf("destination: enumerate volumes: %w", err)
	}

	vol, ok := volume.Find(vols, volumeName)
	if !ok {
		return folder.Folder{}, fmt.Errorf("%w: %q", ErrUnknownVolume, volumeName)
	}

	if strings.TrimSpace(subfolder) == "" {
		subfolder = DefaultSubfolder
	}
	clean, err := safepath.Clean(subfolder, m.policy)
	if err != nil {
		return folder.Folder{}, fmt.Errorf("%w: %v", ErrInvalidSubfolder, err)
	}

	root := filepath.Join(vol.Path, filepath.FromSlash(clean))
	finalizer, err := folder.New(root, m.policy)
	if err != nil {
		return folder.Folder{}, err
	}

	selected := folder.Folder{ID: DefaultID, Name: clean, Root: finalizer.Root}
	if err := m.folders.Register(DefaultID, clean, finalizer); err != nil {
		return folder.Folder{}, err
	}
	m.record(selected)

	// Persist after the registry is live: a failed write should not leave the phone pointing at
	// a folder the agent has not actually adopted.
	dest := Destination{Volume: vol.Name, Subfolder: clean, Root: finalizer.Root}
	if err := save(m.dir, dest); err != nil {
		return selected, err
	}
	return selected, nil
}

// Restore loads a persisted choice and registers it. The bool reports whether one was found.
func (m *Manager) Restore() (folder.Folder, bool, error) {
	dest, ok, err := load(m.dir)
	if err != nil || !ok {
		return folder.Folder{}, false, err
	}

	finalizer, err := folder.New(dest.Root, m.policy)
	if err != nil {
		// A drive that is no longer present must not stop the agent from starting; the caller
		// falls back to the default root.
		return folder.Folder{}, false, err
	}
	if err := m.folders.Register(DefaultID, dest.Subfolder, finalizer); err != nil {
		return folder.Folder{}, false, err
	}
	return m.record(folder.Folder{ID: DefaultID, Name: dest.Subfolder, Root: finalizer.Root}), true, nil
}

// Current returns the active default folder.
func (m *Manager) Current() (folder.Folder, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.current.ID == "" {
		return folder.Folder{}, false
	}
	return m.current, true
}

func (m *Manager) record(f folder.Folder) folder.Folder {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.current = f
	return f
}

// load reads the persisted destination. The bool is false when no choice has been made yet.
func load(dir string) (Destination, bool, error) {
	raw, err := os.ReadFile(filepath.Join(dir, fileName))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Destination{}, false, nil
		}
		return Destination{}, false, fmt.Errorf("destination: read: %w", err)
	}
	var dest Destination
	if err := json.Unmarshal(raw, &dest); err != nil {
		return Destination{}, false, fmt.Errorf("destination: parse: %w", err)
	}
	if strings.TrimSpace(dest.Root) == "" {
		return Destination{}, false, nil
	}
	return dest, true, nil
}

// save writes the destination atomically, so a crash mid-write cannot corrupt it.
func save(dir string, dest Destination) error {
	raw, err := json.MarshalIndent(dest, "", "  ")
	if err != nil {
		return fmt.Errorf("destination: encode: %w", err)
	}
	raw = append(raw, '\n')

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("destination: create data dir: %w", err)
	}
	temp, err := os.CreateTemp(dir, ".destination-*.tmp")
	if err != nil {
		return fmt.Errorf("destination: create temp: %w", err)
	}
	tempName := temp.Name()
	defer os.Remove(tempName) // no-op after a successful rename

	if _, err := temp.Write(raw); err != nil {
		temp.Close()
		return fmt.Errorf("destination: write: %w", err)
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return fmt.Errorf("destination: sync: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("destination: close: %w", err)
	}
	if err := os.Rename(tempName, filepath.Join(dir, fileName)); err != nil {
		return fmt.Errorf("destination: commit: %w", err)
	}
	return nil
}
