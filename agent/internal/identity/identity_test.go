package identity

import (
	"crypto/tls"
	"errors"
	"testing"
)

func TestLoadOrCreateIsStable(t *testing.T) {
	dir := t.TempDir()

	first, err := LoadOrCreate(dir)
	if err != nil {
		t.Fatalf("first LoadOrCreate: %v", err)
	}

	second, err := LoadOrCreate(dir)
	if err != nil {
		t.Fatalf("second LoadOrCreate: %v", err)
	}

	if first.ServerID != second.ServerID {
		t.Errorf("server ID changed: %q then %q", first.ServerID, second.ServerID)
	}
	if first.Pin != second.Pin {
		t.Errorf("certificate pin changed: %q then %q", first.Pin, second.Pin)
	}
	if !isValidServerID(first.ServerID) {
		t.Errorf("server ID %q is not 16 hex-encoded bytes", first.ServerID)
	}
}

func TestCertificateCoversLocalNames(t *testing.T) {
	ident, err := LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("LoadOrCreate: %v", err)
	}

	leaf := ident.Leaf()
	if leaf == nil {
		t.Fatal("leaf certificate is nil")
	}

	want := map[string]bool{"localhost": false, "cloudbox.local": false}
	for _, name := range leaf.DNSNames {
		if _, ok := want[name]; ok {
			want[name] = true
		}
	}
	for name, found := range want {
		if !found {
			t.Errorf("certificate is missing DNS name %q (have %v)", name, leaf.DNSNames)
		}
	}

	if len(leaf.IPAddresses) == 0 {
		t.Error("certificate has no IP SANs")
	}
}

func TestPinMatchesCertificate(t *testing.T) {
	ident, err := LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("LoadOrCreate: %v", err)
	}

	computed, err := PinForCertificate(ident.Leaf())
	if err != nil {
		t.Fatalf("PinForCertificate: %v", err)
	}
	if computed != ident.Pin {
		t.Fatalf("pin = %q, want %q", computed, ident.Pin)
	}

	if !VerifyPin(ident.Leaf(), ident.Pin) {
		t.Error("VerifyPin rejected the real certificate")
	}
	if VerifyPin(ident.Leaf(), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=") {
		t.Error("VerifyPin accepted a wrong pin")
	}
}

func TestTLSHandshakeWithPinnedClient(t *testing.T) {
	ident, err := LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("LoadOrCreate: %v", err)
	}

	listener, err := tls.Listen("tcp", "127.0.0.1:0", ident.TLSConfig())
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	serverErr := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			serverErr <- err
			return
		}
		defer conn.Close()
		serverErr <- conn.(*tls.Conn).Handshake()
	}()

	verifyPin := func(cs tls.ConnectionState) error {
		if len(cs.PeerCertificates) == 0 {
			return errors.New("no peer certificate")
		}
		if !VerifyPin(cs.PeerCertificates[0], ident.Pin) {
			return errors.New("certificate pin mismatch")
		}
		return nil
	}

	client, err := tls.Dial("tcp", listener.Addr().String(), &tls.Config{
		// The pin replaces the CA chain; hostname verification is not meaningful on a LAN
		// where the address may be a bare IP that changes with DHCP.
		InsecureSkipVerify: true,
		VerifyConnection:   verifyPin,
	})
	if err != nil {
		t.Fatalf("dial with correct pin: %v", err)
	}
	client.Close()

	if err := <-serverErr; err != nil {
		t.Fatalf("server handshake: %v", err)
	}
}

func TestTLSHandshakeRejectsWrongPin(t *testing.T) {
	ident, err := LoadOrCreate(t.TempDir())
	if err != nil {
		t.Fatalf("LoadOrCreate: %v", err)
	}

	listener, err := tls.Listen("tcp", "127.0.0.1:0", ident.TLSConfig())
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	go func() {
		conn, err := listener.Accept()
		if err == nil {
			_ = conn.(*tls.Conn).Handshake()
			conn.Close()
		}
	}()

	_, err = tls.Dial("tcp", listener.Addr().String(), &tls.Config{
		InsecureSkipVerify: true,
		VerifyConnection: func(cs tls.ConnectionState) error {
			return errors.New("pin mismatch")
		},
	})
	if err == nil {
		t.Fatal("dial succeeded with a wrong pin")
	}
}
