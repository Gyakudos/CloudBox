// Package identity owns the PC agent's long-lived cryptographic identity: the server ID, the
// self-signed TLS certificate the phone pins, and the SPKI digest used as that pin.
//
// The pin is what makes pairing safe on a LAN with no certificate authority: the phone learns
// the digest out-of-band (from the pairing QR code) and refuses any connection whose
// certificate does not match. See docs/sync-protocol.md section 2.
package identity

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/netutil"
)

const (
	serverIDFile = "server_id"
	certPEMFile  = "tls.crt"
	keyPEMFile   = "tls.key"

	// certValidity is deliberately long: the pin is stable across renewals, but a new key
	// invalidates the pin and forces every paired device to re-pair.
	certValidity = 10 * 365 * 24 * time.Hour

	dirPerm  os.FileMode = 0o700
	filePerm os.FileMode = 0o600
)

// Identity is the agent's stable, on-disk identity.
type Identity struct {
	// ServerID is a random 128-bit identifier, hex encoded. It is stable for the life of
	// the data directory and appears in the pairing payload.
	ServerID string

	// Pin is the base64 SHA-256 digest of the certificate's SubjectPublicKeyInfo. The phone
	// compares the observed certificate against this value.
	Pin string

	// Cert is the self-signed server certificate and private key.
	Cert tls.Certificate

	// Dir is the directory the identity is persisted in.
	Dir string

	leaf *x509.Certificate
}

// LoadOrCreate reads the identity from dir, generating a server ID and TLS keypair on first
// run. It is safe to call on every start: existing material is reused.
func LoadOrCreate(dir string) (*Identity, error) {
	if err := os.MkdirAll(dir, dirPerm); err != nil {
		return nil, fmt.Errorf("identity: create %s: %w", dir, err)
	}

	serverID, err := loadOrCreateServerID(filepath.Join(dir, serverIDFile))
	if err != nil {
		return nil, err
	}

	cert, err := loadOrCreateCert(dir, serverID)
	if err != nil {
		return nil, err
	}

	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return nil, fmt.Errorf("identity: parse leaf certificate: %w", err)
	}
	cert.Leaf = leaf

	pin, err := PinForCertificate(leaf)
	if err != nil {
		return nil, err
	}

	return &Identity{
		ServerID: serverID,
		Pin:      pin,
		Cert:     cert,
		Dir:      dir,
		leaf:     leaf,
	}, nil
}

// Leaf returns the parsed server certificate.
func (i *Identity) Leaf() *x509.Certificate { return i.leaf }

// TLSConfig returns a server-side TLS configuration carrying the pinned certificate.
func (i *Identity) TLSConfig() *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{i.Cert},
		MinVersion:   tls.VersionTLS12,
	}
}

// PinForCertificate computes the base64 SHA-256 digest of a certificate's public key.
func PinForCertificate(cert *x509.Certificate) (string, error) {
	spki, err := x509.MarshalPKIXPublicKey(cert.PublicKey)
	if err != nil {
		return "", fmt.Errorf("identity: marshal public key: %w", err)
	}
	sum := sha256.Sum256(spki)
	return base64.StdEncoding.EncodeToString(sum[:]), nil
}

// VerifyPin reports whether cert matches the expected pin, in constant time.
func VerifyPin(cert *x509.Certificate, pin string) bool {
	got, err := PinForCertificate(cert)
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(pin)) == 1
}

func loadOrCreateServerID(path string) (string, error) {
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		id := strings.TrimSpace(string(data))
		if !isValidServerID(id) {
			return "", fmt.Errorf("identity: %s is malformed", path)
		}
		return id, nil
	case errors.Is(err, os.ErrNotExist):
		// fall through and generate
	default:
		return "", fmt.Errorf("identity: read server id: %w", err)
	}

	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("identity: generate server id: %w", err)
	}
	id := hex.EncodeToString(buf)
	if err := writeAtomic(path, []byte(id+"\n"), filePerm); err != nil {
		return "", err
	}
	return id, nil
}

func isValidServerID(id string) bool {
	if len(id) != 32 {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

func loadOrCreateCert(dir, serverID string) (tls.Certificate, error) {
	certPath := filepath.Join(dir, certPEMFile)
	keyPath := filepath.Join(dir, keyPEMFile)

	certPEM, certErr := os.ReadFile(certPath)
	keyPEM, keyErr := os.ReadFile(keyPath)

	if certErr == nil && keyErr == nil {
		cert, err := tls.X509KeyPair(certPEM, keyPEM)
		if err == nil {
			leaf, perr := x509.ParseCertificate(cert.Certificate[0])
			if perr == nil && time.Now().Before(leaf.NotAfter.Add(-30*24*time.Hour)) {
				return cert, nil
			}
		}
		// Unreadable or near expiry: regenerate below. Regenerating changes the pin, so the
		// caller must surface that to the user; devices will need to re-pair.
	} else if !errors.Is(certErr, os.ErrNotExist) && certErr != nil {
		return tls.Certificate{}, fmt.Errorf("identity: read certificate: %w", certErr)
	} else if !errors.Is(keyErr, os.ErrNotExist) && keyErr != nil {
		return tls.Certificate{}, fmt.Errorf("identity: read private key: %w", keyErr)
	}

	generatedCert, generatedKey, err := generateSelfSigned(serverID)
	if err != nil {
		return tls.Certificate{}, err
	}
	if err := writeAtomic(certPath, generatedCert, filePerm); err != nil {
		return tls.Certificate{}, err
	}
	if err := writeAtomic(keyPath, generatedKey, filePerm); err != nil {
		return tls.Certificate{}, err
	}

	cert, err := tls.X509KeyPair(generatedCert, generatedKey)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("identity: load generated keypair: %w", err)
	}
	return cert, nil
}

func generateSelfSigned(serverID string) (certPEM, keyPEM []byte, err error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("identity: generate key: %w", err)
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, fmt.Errorf("identity: generate serial: %w", err)
	}

	short := serverID
	if len(short) > 8 {
		short = short[:8]
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "cloudbox-" + short, Organization: []string{"CloudBox"}},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(certValidity),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"localhost", "cloudbox", "cloudbox.local", "cloudbox.local."},
		IPAddresses:           certificateIPs(),
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, fmt.Errorf("identity: create certificate: %w", err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, nil, fmt.Errorf("identity: marshal private key: %w", err)
	}

	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM, nil
}

func certificateIPs() []net.IP {
	ips := []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}
	return append(ips, netutil.LocalIPs()...)
}

// writeAtomic writes data to a sibling temp file and renames it into place, so a crash can
// never leave a half-written key or ID behind.
func writeAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("identity: create temp file: %w", err)
	}
	name := tmp.Name()
	defer os.Remove(name)

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("identity: write %s: %w", path, err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("identity: sync %s: %w", path, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("identity: close %s: %w", path, err)
	}
	if err := os.Chmod(name, perm); err != nil {
		// Best effort: Windows has no POSIX mode bits.
		_ = err
	}
	if err := os.Rename(name, path); err != nil {
		return fmt.Errorf("identity: replace %s: %w", path, err)
	}
	return nil
}
