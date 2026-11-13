package pairing

import (
	"encoding/json"
	"errors"
	"testing"
	"time"
)

func TestTokenIsSingleUse(t *testing.T) {
	m := NewManager(time.Minute)

	token, expires, err := m.Issue()
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if token == "" {
		t.Fatal("Issue returned an empty token")
	}
	if !expires.After(time.Now()) {
		t.Fatalf("expiry %v is not in the future", expires)
	}

	if err := m.Redeem(token); err != nil {
		t.Fatalf("first Redeem: %v", err)
	}
	if err := m.Redeem(token); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("second Redeem = %v, want ErrInvalidToken", err)
	}
}

func TestUnknownTokenIsRejected(t *testing.T) {
	m := NewManager(time.Minute)

	if err := m.Redeem("nope"); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("Redeem = %v, want ErrInvalidToken", err)
	}
	if err := m.Redeem(""); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("Redeem(empty) = %v, want ErrInvalidToken", err)
	}
}

func TestTokenExpires(t *testing.T) {
	m := NewManager(time.Minute)
	fixed := time.Date(2026, 11, 13, 9, 0, 0, 0, time.UTC)
	m.now = func() time.Time { return fixed }

	token, _, err := m.Issue()
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	m.now = func() time.Time { return fixed.Add(2 * time.Minute) }
	if err := m.Redeem(token); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("Redeem of expired token = %v, want ErrInvalidToken", err)
	}
}

func TestPendingSweepsExpired(t *testing.T) {
	m := NewManager(time.Minute)
	fixed := time.Date(2026, 11, 13, 9, 0, 0, 0, time.UTC)
	m.now = func() time.Time { return fixed }

	for i := 0; i < 3; i++ {
		if _, _, err := m.Issue(); err != nil {
			t.Fatalf("Issue %d: %v", i, err)
		}
	}
	if got := m.Pending(); got != 3 {
		t.Fatalf("Pending = %d, want 3", got)
	}

	m.now = func() time.Time { return fixed.Add(5 * time.Minute) }
	if got := m.Pending(); got != 0 {
		t.Fatalf("Pending after expiry = %d, want 0", got)
	}
}

func TestIssueIsUnique(t *testing.T) {
	m := NewManager(time.Minute)

	seen := make(map[string]bool, 32)
	for i := 0; i < 32; i++ {
		token, _, err := m.Issue()
		if err != nil {
			t.Fatalf("Issue %d: %v", i, err)
		}
		if seen[token] {
			t.Fatalf("duplicate token issued: %q", token)
		}
		seen[token] = true
	}
}

func TestPayloadJSONUsesProtocolFieldNames(t *testing.T) {
	payload := Payload{
		V:   1,
		SID: "server-id",
		EPs: []string{"192.168.1.42:8443", "cloudbox.local:8443"},
		Pin: "pin-value",
		Tok: "token-value",
	}

	raw, err := payload.JSON()
	if err != nil {
		t.Fatalf("JSON: %v", err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	for _, key := range []string{"v", "sid", "eps", "pin", "tok"} {
		if _, ok := decoded[key]; !ok {
			t.Errorf("payload JSON is missing key %q: %s", key, raw)
		}
	}
	if decoded["sid"] != "server-id" || decoded["pin"] != "pin-value" || decoded["tok"] != "token-value" {
		t.Errorf("unexpected payload values: %s", raw)
	}
}
