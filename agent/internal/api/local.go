package api

// The /local/* surface exists for the PC-side desktop app. It needs no device bearer token:
// the app is the person sitting at this machine, with the same trust level as the files in the
// agent's data directory. Access is instead restricted to loopback connections, so none of it
// is reachable from a phone or another computer on the LAN.
//
// This is why the pairing code, volume list and destination controls are not folded into the
// device-authenticated /v1 routes — a phone that is paired to back up photos must not be able
// to mint new pairing codes or repoint the backup folder.

import (
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/destination"
)

// LocalPairing is the currently displayed pairing code and its state.
type LocalPairing struct {
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
	// Active is false once a phone has redeemed the token or it has expired. The desktop app
	// polls status to switch from "waiting" to "paired" without consuming the token itself.
	Active bool `json:"active"`
}

// LocalState is everything the desktop app needs to render its two screens. Payload is the JSON
// QR document (the same bytes written to pairing.json) and QRPNGBase64 is a rendered copy, so
// the app does not have to guess the data directory or duplicate QR encoding.
type LocalState struct {
	ServerName  string                   `json:"server_name"`
	ServerID    string                   `json:"server_id"`
	Version     string                   `json:"version"`
	Pin         string                   `json:"pin"`
	Endpoints   []string                 `json:"endpoints"`
	Pairing     LocalPairing             `json:"pairing"`
	Destination *destination.Destination `json:"destination"`
	Payload     string                   `json:"payload"`
	QRPNGBase64 string                   `json:"qr_png_base64"`
}

func (s *Server) handleLocalStatus(w http.ResponseWriter, _ *http.Request) {
	state := s.opts.LocalState()
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleLocalRefresh(w http.ResponseWriter, _ *http.Request) {
	state, err := s.opts.LocalRefresh()
	if err != nil {
		s.opts.Logger.Error("refresh pairing code", "err", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL", "could not create a new pairing code")
		return
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleLocalSetDestination(w http.ResponseWriter, r *http.Request) {
	var req setDestinationRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "malformed JSON body")
		return
	}
	s.applyDestination(w, req)
}

// requireLoopback rejects any request that did not arrive over a loopback connection. Checking
// the socket peer rather than a Host header means a DNS name pointing at the PC cannot slip
// through: the TCP source address cannot be spoofed.
func (s *Server) requireLoopback(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			host = r.RemoteAddr
		}
		ip := net.ParseIP(strings.Trim(host, "[]"))
		if ip == nil || !ip.IsLoopback() {
			s.opts.Logger.Warn("rejected non-loopback local request", "remote", r.RemoteAddr, "path", r.URL.Path)
			writeError(w, http.StatusForbidden, "LOCAL_ONLY", "this endpoint is only available from this PC")
			return
		}
		next.ServeHTTP(w, r)
	})
}
