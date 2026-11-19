package main

import "testing"

func TestDisplayAddr(t *testing.T) {
	for _, tc := range []struct {
		addr string
		port int
		want string
	}{
		{addr: ":8443", port: 8443, want: "0.0.0.0:8443"},
		{addr: "127.0.0.1:18443", port: 18443, want: "127.0.0.1:18443"},
		{addr: "0.0.0.0:18444", port: 18444, want: "0.0.0.0:18444"},
		{addr: "[::1]:8443", port: 8443, want: "[::1]:8443"},
		{addr: "not-an-address", port: 8443, want: "0.0.0.0:8443"},
	} {
		if got := displayAddr(tc.addr, tc.port); got != tc.want {
			t.Errorf("displayAddr(%q, %d) = %q, want %q", tc.addr, tc.port, got, tc.want)
		}
	}
}
