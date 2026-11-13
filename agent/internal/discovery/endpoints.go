// Package discovery builds the endpoint hints the phone tries, in order, when pairing.
//
// The phone attempts each candidate in turn with a short timeout. LAN addresses come first
// because they avoid the tailnet relay; the mDNS name is next for networks where the address
// changes; loopback is last and only useful for a desktop client running on the same machine.
package discovery

import (
	"net"
	"sort"
	"strconv"

	"github.com/Gyakudos/CloudBox/agent/internal/netutil"
)

// MDNSHost is the hostname the agent intends to advertise over mDNS once discovery lands.
const MDNSHost = "cloudbox.local"

// LocalEndpoints returns candidate host:port pairs, most preferred first.
func LocalEndpoints(port int) []string {
	portText := strconv.Itoa(port)

	seen := make(map[string]bool, 8)
	endpoints := make([]string, 0, 8)
	add := func(host string) {
		ep := net.JoinHostPort(host, portText)
		if !seen[ep] {
			seen[ep] = true
			endpoints = append(endpoints, ep)
		}
	}

	ips := netutil.LocalIPs()
	// IPv4 first: more likely to be reachable from a phone, and shorter to render.
	sort.SliceStable(ips, func(i, j int) bool {
		return ips[i].To4() != nil && ips[j].To4() == nil
	})
	for _, ip := range ips {
		add(ip.String())
	}

	add(MDNSHost)
	add("127.0.0.1")

	return endpoints
}
