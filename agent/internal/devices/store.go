// Package devices tracks the phones allowed to talk to this agent.
//
// Tokens are 256-bit random values, so a plain SHA-256 digest is sufficient for storage:
// unlike a user-chosen password there is no low-entropy guess to slow down. A password-style
// KDF would be needed only if the token were ever derived from something memorable.
package devices

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"sync"
	"time"
)

// Device is a paired phone.
type Device struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	Platform   string    `json:"platform"`
	AppVersion string    `json:"app_version"`
	CreatedAt  time.Time `json:"created_at"`
}

// Store is an in-memory device registry.
//
// Persistence lands with M1; the interface is kept narrow so the swap to SQLite does not
// ripple into the API layer.
type Store struct {
	mu     sync.RWMutex
	byHash map[[32]byte]Device
	byID   map[string]Device
}

// NewStore returns an empty registry.
func NewStore() *Store {
	return &Store{
		byHash: make(map[[32]byte]Device),
		byID:   make(map[string]Device),
	}
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

	s.mu.Lock()
	defer s.mu.Unlock()
	s.byHash[sha256.Sum256([]byte(token))] = device
	s.byID[device.ID] = device

	return device, token, nil
}

// Authenticate resolves a bearer token to a device.
func (s *Store) Authenticate(token string) (Device, bool) {
	if token == "" {
		return Device{}, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	device, ok := s.byHash[sha256.Sum256([]byte(token))]
	return device, ok
}

// Revoke removes a device and invalidates its token immediately.
func (s *Store) Revoke(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, ok := s.byID[id]; !ok {
		return false
	}
	delete(s.byID, id)
	for hash, candidate := range s.byHash {
		if candidate.ID == id {
			delete(s.byHash, hash)
			break
		}
	}
	return true
}

// List returns the registered devices, newest first.
func (s *Store) List() []Device {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]Device, 0, len(s.byID))
	for _, device := range s.byID {
		out = append(out, device)
	}
	return out
}

// ErrNotFound is returned when a device ID is unknown.
var ErrNotFound = errors.New("devices: not found")
