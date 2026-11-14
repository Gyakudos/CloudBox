// Package mdns advertises the agent on the local network so the phone can find it by name
// instead of an IP address.
//
// The advertisement is public by construction: anyone on the LAN can browse it. Nothing
// secret goes in the TXT records, and in particular the pairing token never does — it travels
// only in the QR payload the user physically scans. See docs/sync-protocol.md.
package mdns

import (
	"fmt"
	"strings"

	"github.com/grandcat/zeroconf"
)

const (
	// Service is the DNS-SD service type the app browses for.
	Service = "_cloudbox._tcp"
	// Domain is the multicast DNS domain for the local link.
	Domain = "local."
)

// Advertiser holds a live mDNS registration.
type Advertiser struct {
	server *zeroconf.Server
}

// Advertise publishes the agent on all usable interfaces and returns a handle to stop it.
func Advertise(instance string, port int, txt []string) (*Advertiser, error) {
	server, err := zeroconf.Register(instance, Service, Domain, port, txt, nil)
	if err != nil {
		return nil, fmt.Errorf("mdns: register %s: %w", Service, err)
	}
	return &Advertiser{server: server}, nil
}

// Close withdraws the advertisement.
func (a *Advertiser) Close() {
	if a != nil && a.server != nil {
		a.server.Shutdown()
	}
}

// InstanceName builds a human-readable instance label for the service.
func InstanceName(serverName string) string {
	serverName = strings.TrimSpace(serverName)
	if serverName == "" {
		serverName = "PC"
	}
	return "CloudBox on " + serverName
}

// TXTRecords builds the DNS-SD TXT records for the advertisement. The pairing token is
// deliberately absent: discovery is unauthenticated, so anything advertised is public.
func TXTRecords(serverID, serverName, version string) []string {
	return []string{
		"v=1",
		"sid=" + sanitize(serverID),
		"name=" + sanitize(serverName),
		"ver=" + sanitize(version),
	}
}

// sanitize strips characters that would break a DNS-SD TXT value.
func sanitize(value string) string {
	var b strings.Builder
	for _, r := range value {
		switch {
		case r < 0x20 || r == 0x7F:
			b.WriteByte(' ')
		case r == '=':
			b.WriteByte('-')
		default:
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}
