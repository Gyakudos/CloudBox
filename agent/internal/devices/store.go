// Package devices tracks the phones allowed to talk to this agent.
//
// Tokens are 256-bit random values, so a plain SHA-256 digest is sufficient for storage:
// unlike a user-chosen password there is no low-entropy guess to slow down. A password-style
// KDF would be needed only if the token were ever derived from something memorable.
//
// The registry is persisted to <data dir>/devices.json so a paired phone stays paired across
// agent restarts, along with the per-device backup folder it writes into. NewStore remains as an
// in-memory-only constructor for tests and callers that do not own a data directory.
package devices

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/destination"
	"github.com/Gyakudos/CloudBox/agent/internal/safepath"
	"github.com/Gyakudos/CloudBox/agent/internal/volume"
)

const fileName = "devices.json"

// BackupConfig is the per-device backup folder. Each paired phone gets its own folder id
// (backup-<device id>) so two phones never write into each other's trees.
type BackupConfig struct {
	FolderID  string `json:"folder_id"`
	Volume    string `json:"volume"`
	Subfolder string `json:"subfolder"`
	Root      string `json:"root"`
	Enabled   bool   `json:"enabled"`
}

// BackupFolderID returns the folder id reserved for a device's backup tree.
func BackupFolderID(deviceID string) string {
	return "backup-" + deviceID
}

// Device is a paired phone.
type Device struct {
	ID         string       `json:"id"`
	Name       string       `json:"name"`
	Platform   string       `json:"platform"`
	AppVersion string       `json:"app_version"`
	CreatedAt  time.Time    `json:"created_at"`
	LastSeenAt time.Time    `json:"last_seen_at"`
	Backup     BackupConfig `json:"backup"`
}

// persistedDevice is the on-disk form. The plaintext token is never written: only its digest,
// which is all Authenticate needs to compare against.
type persistedDevice struct {
	ID         string       `json:"id"`
	Name       string       `json:"name"`
	Platform   string       `json:"platform"`
	AppVersion string       `json:"app_version"`
	TokenHash  string       `json:"token_hash"`
	CreatedAt  time.Time    `json:"created_at"`
	LastSeenAt time.Time    `json:"last_seen_at"`
	Backup     BackupConfig `json:"backup"`
}

type persistedState struct {
	Devices []persistedDevice `json:"devices"`
}

type record struct {
	device    Device
	tokenHash [32]byte
}

// Store is a device registry. With dir set it persists every mutation to devices.json; with an
// empty dir it lives only in memory.
type Store struct {
	mu      sync.RWMutex
	dir     string
	byHash  map[[32]byte]string
	byID    map[string]record
	resolve func(volumeName, subfolder string) (destination.Destination, error)
}

// defaultResolver mirrors the destination manager's validation: a volume must come from the
// host's own enumeration and the subfolder must be a safe relative path.
func defaultResolver(volumeName, subfolder string) (destination.Destination, error) {
	return destination.Resolve(volume.List, safepath.DefaultPolicy(), volumeName, subfolder)
}

func newStore(dir string) *Store {
	return &Store{
		dir:     dir,
		byHash:  make(map[[32]byte]string),
		byID:    make(map[string]record),
		resolve: defaultResolver,
	}
}

// NewStore returns an empty, in-memory registry.
func NewStore() *Store {
	return newStore("")
}

// NewStoreAt returns the registry persisted under dir. A missing file is a first run and yields
// an empty store; a corrupt file is an error so the agent never silently forgets paired phones.
func NewStoreAt(dir string) (*Store, error) {
	s := newStore(dir)
	raw, err := os.ReadFile(filepath.Join(dir, fileName))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return s, nil
		}
		return nil, fmt.Errorf("devices: read: %w", err)
	}
	var state persistedState
	if err := json.Unmarshal(raw, &state); err != nil {
		return nil, fmt.Errorf("devices: parse: %w", err)
	}
	for _, saved := range state.Devices {
		hashBytes, err := hex.DecodeString(saved.TokenHash)
		if err != nil || len(hashBytes) != sha256.Size || saved.ID == "" {
			return nil, fmt.Errorf("devices: invalid record for %q", saved.ID)
		}
		var hash [32]byte
		copy(hash[:], hashBytes)
		s.byID[saved.ID] = record{
			device: Device{
				ID:         saved.ID,
				Name:       saved.Name,
				Platform:   saved.Platform,
				AppVersion: saved.AppVersion,
				CreatedAt:  saved.CreatedAt,
				LastSeenAt: saved.LastSeenAt,
				Backup:     saved.Backup,
			},
			tokenHash: hash,
		}
		s.byHash[hash] = saved.ID
	}
	return s, nil
}

// Create registers a new device and returns it together with its plaintext token. The token
// is returned exactly once and never stored in the clear.
func (s *Store) Create(name, platform, appVersion string) (Device, string, error) {
	idBytes := make([]byte, 16)
	if _, err := rand.Read(idBytes); err != nil {
		return Device{}, "", err
	}
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		return Device{}, "", err
	}

	device := Device{
		ID:         hex.EncodeToString(idBytes),
		Name:       name,
		Platform:   platform,
		AppVersion: appVersion,
		CreatedAt:  time.Now().UTC(),
	}
	token := base64.RawURLEncoding.EncodeToString(tokenBytes)
	hash := sha256.Sum256([]byte(token))

	s.mu.Lock()
	defer s.mu.Unlock()
	s.byHash[hash] = device.ID
	s.byID[device.ID] = record{device: device, tokenHash: hash}
	if err := s.saveLocked(); err != nil {
		delete(s.byID, device.ID)
		delete(s.byHash, hash)
		return Device{}, "", err
	}
	return device, token, nil
}

// Authenticate resolves a bearer token to a device.
func (s *Store) Authenticate(token string) (Device, bool) {
	if token == "" {
		return Device{}, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.byHash[sha256.Sum256([]byte(token))]
	if !ok {
		return Device{}, false
	}
	return s.byID[id].device, true
}

// Revoke removes a device and invalidates its token immediately. It reports whether the device
// existed. Use RevokeWithError when the caller needs to know whether persistence succeeded.
func (s *Store) Revoke(id string) bool {
	ok, _ := s.RevokeWithError(id)
	return ok
}

// RevokeWithError is Revoke with persistence errors reported. ErrNotFound means the id was
// already gone. On a failed write the in-memory removal is rolled back.
func (s *Store) RevokeWithError(id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	old, ok := s.byID[id]
	if !ok {
		return false, ErrNotFound
	}
	delete(s.byID, id)
	delete(s.byHash, old.tokenHash)
	if err := s.saveLocked(); err != nil {
		s.byID[id] = old
		s.byHash[old.tokenHash] = id
		return true, err
	}
	return true, nil
}

// Get returns one device by id.
func (s *Store) Get(id string) (Device, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.byID[id]
	return rec.device, ok
}

// Touch records that a device was seen just now. Writes are best effort: a disk error must not
// turn a perfectly good authenticated request into a failure.
func (s *Store) Touch(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, ok := s.byID[id]
	if !ok {
		return
	}
	rec.device.LastSeenAt = time.Now().UTC()
	s.byID[id] = rec
	_ = s.saveLocked()
}

// UpdateBackup resolves volume and subfolder with the same rules as the default destination
// and stores the resulting per-device backup config.
func (s *Store) UpdateBackup(id, volumeName, subfolder string, enabled bool) (Device, error) {
	s.mu.RLock()
	_, exists := s.byID[id]
	s.mu.RUnlock()
	if !exists {
		return Device{}, ErrNotFound
	}

	dest, err := s.resolve(volumeName, subfolder)
	if err != nil {
		return Device{}, err
	}
	return s.SetBackupConfig(id, BackupConfig{
		FolderID:  BackupFolderID(id),
		Volume:    dest.Volume,
		Subfolder: dest.Subfolder,
		Root:      dest.Root,
		Enabled:   enabled,
	})
}

// SetBackupConfig stores an already resolved backup config. The on-pair path uses it to inherit
// the current global destination, which may be an adopted path with no source volume.
func (s *Store) SetBackupConfig(id string, cfg BackupConfig) (Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	old, ok := s.byID[id]
	if !ok {
		return Device{}, ErrNotFound
	}
	rec := old
	rec.device.Backup = cfg
	s.byID[id] = rec
	if err := s.saveLocked(); err != nil {
		s.byID[id] = old
		return Device{}, err
	}
	return rec.device, nil
}

// BackupConfigForTokenHash returns the enabled backup config for a token digest. It lets the
// upload layer route bytes without exposing plaintext tokens.
func (s *Store) BackupConfigForTokenHash(hash [32]byte) (BackupConfig, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	id, ok := s.byHash[hash]
	if !ok {
		return BackupConfig{}, false
	}
	cfg := s.byID[id].device.Backup
	return cfg, cfg.Enabled && cfg.FolderID != ""
}

// BackupConfigForToken is the plaintext-token form of BackupConfigForTokenHash.
func (s *Store) BackupConfigForToken(token string) (BackupConfig, bool) {
	if token == "" {
		return BackupConfig{}, false
	}
	return s.BackupConfigForTokenHash(sha256.Sum256([]byte(token)))
}

// List returns the registered devices, newest first (ties broken by id for determinism).
func (s *Store) List() []Device {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]Device, 0, len(s.byID))
	for _, rec := range s.byID {
		out = append(out, rec.device)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].CreatedAt.After(out[j].CreatedAt)
		}
		return out[i].ID > out[j].ID
	})
	return out
}

// saveLocked writes the whole registry atomically. The caller must hold s.mu for writing.
func (s *Store) saveLocked() error {
	if s.dir == "" {
		return nil
	}
	state := persistedState{Devices: make([]persistedDevice, 0, len(s.byID))}
	for id, rec := range s.byID {
		state.Devices = append(state.Devices, persistedDevice{
			ID:         id,
			Name:       rec.device.Name,
			Platform:   rec.device.Platform,
			AppVersion: rec.device.AppVersion,
			TokenHash:  hex.EncodeToString(rec.tokenHash[:]),
			CreatedAt:  rec.device.CreatedAt,
			LastSeenAt: rec.device.LastSeenAt,
			Backup:     rec.device.Backup,
		})
	}
	sort.Slice(state.Devices, func(i, j int) bool {
		return state.Devices[i].ID < state.Devices[j].ID
	})
	raw, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("devices: encode: %w", err)
	}
	raw = append(raw, '\n')

	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		return fmt.Errorf("devices: create data dir: %w", err)
	}
	temp, err := os.CreateTemp(s.dir, ".devices-*.tmp")
	if err != nil {
		return fmt.Errorf("devices: create temp: %w", err)
	}
	tempName := temp.Name()
	defer os.Remove(tempName) // no-op after a successful rename

	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return fmt.Errorf("devices: chmod: %w", err)
	}
	if _, err := temp.Write(raw); err != nil {
		temp.Close()
		return fmt.Errorf("devices: write: %w", err)
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return fmt.Errorf("devices: sync: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("devices: close: %w", err)
	}
	if err := os.Rename(tempName, filepath.Join(s.dir, fileName)); err != nil {
		return fmt.Errorf("devices: commit: %w", err)
	}
	return nil
}

// ErrNotFound is returned when a device ID is unknown.
var ErrNotFound = errors.New("devices: not found")
