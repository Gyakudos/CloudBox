// Package netutil holds small networking helpers shared across the agent.
package netutil

import "net"

// LocalIPs returns this host's unicast addresses, excluding loopback, link-local and
// unspecified addresses. Ordering follows the OS interface order.
func LocalIPs() []net.IP {
	var out []net.IP

	ifaces, err := net.Interfaces()
	if err != nil {
		return out
	}

	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch a := addr.(type) {
			case *net.IPNet:
				ip = a.IP
			case *net.IPAddr:
				ip = a.IP
			}
			if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
				continue
			}
			out = append(out, ip)
		}
	}

	return out
}
