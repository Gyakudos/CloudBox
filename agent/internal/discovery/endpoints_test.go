package discovery

import (
	"net"
	"testing"
)

func TestLocalEndpointsAreWellFormed(t *testing.T) {
	endpoints := LocalEndpoints(8443)
	if len(endpoints) == 0 {
		t.Fatal("LocalEndpoints returned nothing")
	}

	for _, endpoint := range endpoints {
		_, port, err := net.SplitHostPort(endpoint)
		if err != nil {
			t.Fatalf("endpoint %q is not host:port: %v", endpoint, err)
		}
		if port != "8443" {
			t.Errorf("endpoint %q has port %q, want 8443", endpoint, port)
		}
	}
}

func TestLocalEndpointsPreferredOrder(t *testing.T) {
	endpoints := LocalEndpoints(8443)

	last := endpoints[len(endpoints)-1]
	if last != "127.0.0.1:8443" {
		t.Errorf("last endpoint = %q, want loopback", last)
	}

	// Loopback must appear exactly once even if no other addresses exist.
	count := 0
	for _, endpoint := range endpoints {
		if endpoint == "127.0.0.1:8443" {
			count++
		}
	}
	if count != 1 {
		t.Errorf("loopback appears %d times, want 1", count)
	}
}

func TestLocalEndpointsDeduplicates(t *testing.T) {
	endpoints := LocalEndpoints(9000)

	seen := make(map[string]bool, len(endpoints))
	for _, endpoint := range endpoints {
		if seen[endpoint] {
			t.Errorf("duplicate endpoint %q", endpoint)
		}
		seen[endpoint] = true
	}
}
