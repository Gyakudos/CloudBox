package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/api"
	"github.com/Gyakudos/CloudBox/agent/internal/destination"
	"github.com/Gyakudos/CloudBox/agent/internal/discovery"
	"github.com/Gyakudos/CloudBox/agent/internal/identity"
	"github.com/Gyakudos/CloudBox/agent/internal/pairing"
	"github.com/Gyakudos/CloudBox/agent/internal/version"
)

const (
	pairingFileName = "pairing.json"
	qrFileName      = "pairing.png"
)

// pairingSnapshot is the one live code the agent is currently showing. The phone learns the
// token from the QR (or the handoff file); the desktop app reads the same code through /local.
type pairingSnapshot struct {
	token     string
	expires   time.Time
	payload   []byte
	qr        []byte
	qrPath    string
	qrWritten bool
}

// pairingSession owns issuing and refreshing the displayed code. Both the startup path and the
// desktop app's Refresh button go through issue(), so they cannot disagree about what is live.
type pairingSession struct {
	mu      sync.Mutex
	dir     string
	name    string
	ident   *identity.Identity
	manager *pairing.Manager
	port    int
	logger  *slog.Logger

	current pairingSnapshot
}

func newPairingSession(dir, name string, ident *identity.Identity, manager *pairing.Manager, port int, logger *slog.Logger) *pairingSession {
	return &pairingSession{
		dir:     dir,
		name:    name,
		ident:   ident,
		manager: manager,
		port:    port,
		logger:  logger,
	}
}

// issue mints a fresh one-time code, renders its QR, writes the handoff files and publishes it.
func (p *pairingSession) issue() (pairingSnapshot, error) {
	token, expires, err := p.manager.Issue()
	if err != nil {
		return pairingSnapshot{}, fmt.Errorf("issue pairing token: %w", err)
	}

	payload := pairing.Payload{
		V:   1,
		SID: p.ident.ServerID,
		EPs: discovery.LocalEndpoints(p.port),
		Pin: p.ident.Pin,
		Tok: token,
	}
	raw, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return pairingSnapshot{}, fmt.Errorf("encode pairing payload: %w", err)
	}

	// Render before publishing: a code the desktop app can show must be a code the phone can scan.
	qr, qrErr := pairing.QRPNG(string(raw))
	if qrErr != nil {
		p.logger.Warn("could not render QR image", "err", qrErr)
	}

	snap := pairingSnapshot{
		token:     token,
		expires:   expires,
		payload:   raw,
		qr:        qr,
		qrPath:    filepath.Join(p.dir, qrFileName),
		qrWritten: qrErr == nil,
	}

	handoff := filepath.Join(p.dir, pairingFileName)
	if err := os.WriteFile(handoff, append(raw, '\n'), 0o600); err != nil {
		// The QR still works; only the file handoff (used by the desktop app to find us) is lost.
		p.logger.Warn("could not write pairing payload", "path", handoff, "err", err)
	}
	if qrErr == nil {
		if err := os.WriteFile(snap.qrPath, qr, 0o600); err != nil {
			p.logger.Warn("could not write QR image", "path", snap.qrPath, "err", err)
			snap.qrWritten = false
		}
	}

	p.mu.Lock()
	p.current = snap
	p.mu.Unlock()
	return snap, nil
}

// state builds the response for GET /local/status. Active is checked without consuming the
// token, so polling from the desktop app cannot invalidate the code it is showing.
func (p *pairingSession) state(dest *destination.Manager) api.LocalState {
	p.mu.Lock()
	defer p.mu.Unlock()

	snap := p.current
	var chosen *destination.Destination
	if choice, ok := dest.CurrentChoice(); ok {
		chosen = &choice
	}
	var qr string
	if len(snap.qr) > 0 {
		qr = base64.StdEncoding.EncodeToString(snap.qr)
	}

	return api.LocalState{
		ServerName: p.name,
		ServerID:   p.ident.ServerID,
		Version:    version.Version,
		Pin:        p.ident.Pin,
		Endpoints:  discovery.LocalEndpoints(p.port),
		Pairing: api.LocalPairing{
			Token:     snap.token,
			ExpiresAt: snap.expires,
			Active:    p.manager.Valid(snap.token),
		},
		Destination: chosen,
		Payload:     string(snap.payload),
		QRPNGBase64: qr,
	}
}

func (p *pairingSession) refresh(dest *destination.Manager) (api.LocalState, error) {
	if _, err := p.issue(); err != nil {
		return api.LocalState{}, err
	}
	return p.state(dest), nil
}
