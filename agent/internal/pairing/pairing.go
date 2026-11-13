// Package pairing issues and redeems the one-time tokens shown on the PC when a new phone
// wants to pair.
//
// A token is bearer-only and short lived: it authorises exactly one successful pair request
// and is deleted on first attempt, success or failure. See docs/sync-protocol.md section 2.
package pairing

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"sync"
	"time"
)

// ErrInvalidToken is returned when a token is unknown, already used, or expired.
var ErrInvalidToken = errors.New("pairing: invalid or expired token")

// ErrTooManyPending is returned when too many unused tokens exist, which would mean the tray
// UI is leaking tokens.
var ErrTooManyPending = errors.New("pairing: too many pending tokens")

const (
	tokenBytes = 32
	maxPending = 64
)

// Manager holds the outstanding one-time pairing tokens.
type Manager struct {
	mu     sync.Mutex
	ttl    time.Duration
	now    func() time.Time
	tokens map[string]time.Time
}

// NewManager returns a Manager issuing tokens that live for ttl. A non-positive ttl falls
// back to the documented default of five minutes.
func NewManager(ttl time.Duration) *Manager {
	if ttl <= 0 {
		ttl = 5 * time.Minute
	}
	return &Manager{
		ttl:    ttl,
		now:    time.Now,
		tokens: make(map[string]time.Time),
	}
}

// Issue creates a new one-time token and returns it with its expiry.
func (m *Manager) Issue() (string, time.Time, error) {
	buf := make([]byte, tokenBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", time.Time{}, err
	}
	token := base64.RawURLEncoding.EncodeToString(buf)
	expires := m.now().Add(m.ttl)

	m.mu.Lock()
	defer m.mu.Unlock()

	m.sweepLocked()
	if len(m.tokens) >= maxPending {
		return "", time.Time{}, ErrTooManyPending
	}
	m.tokens[token] = expires
	return token, expires, nil
}

// Redeem consumes a token. It returns ErrInvalidToken if the token is unknown, expired, or
// has already been used. The token is consumed even when it has expired, so a stolen token
// cannot be retried.
func (m *Manager) Redeem(token string) error {
	if token == "" {
		return ErrInvalidToken
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	expires, ok := m.tokens[token]
	if !ok {
		return ErrInvalidToken
	}
	delete(m.tokens, token)

	if !m.now().Before(expires) {
		return ErrInvalidToken
	}
	return nil
}

// Pending reports how many unexpired tokens are outstanding.
func (m *Manager) Pending() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sweepLocked()
	return len(m.tokens)
}

func (m *Manager) sweepLocked() {
	now := m.now()
	for token, expires := range m.tokens {
		if !now.Before(expires) {
			delete(m.tokens, token)
		}
	}
}

// Payload is the JSON document encoded into the pairing QR code. It is deliberately compact
// so it still scans when rendered small.
type Payload struct {
	// V is the payload schema version.
	V int `json:"v"`
	// SID is the server ID, so the app can recognise a known PC.
	SID string `json:"sid"`
	// EPs are candidate host:port endpoints, most preferred first.
	EPs []string `json:"eps"`
	// Pin is the base64 SHA-256 SPKI digest the app must match.
	Pin string `json:"pin"`
	// Tok is the single-use pairing token.
	Tok string `json:"tok"`
}

// JSON encodes the payload for QR rendering or the on-disk handoff file.
func (p Payload) JSON() ([]byte, error) {
	return json.Marshal(p)
}
