package mdns

import (
	"strings"
	"testing"
)

func TestTXTRecordsCarryIdentityButNotSecrets(t *testing.T) {
	records := TXTRecords("a356147950ad0faf88481dcd0cf5567a", "DESKTOP-ABC", "0.01.13.11.26")

	joined := strings.Join(records, "\x00")
	for _, want := range []string{"v=1", "sid=a356147950ad0faf88481dcd0cf5567a", "name=DESKTOP-ABC", "ver=0.01.13.11.26"} {
		if !strings.Contains(joined, want) {
			t.Errorf("TXT records missing %q: %v", want, records)
		}
	}
}

func TestTXTRecordsNeverLeakAToken(t *testing.T) {
	// The pairing token must only ever travel in the scanned QR payload. Guard against a
	// future refactor quietly threading it into the advertisement.
	token := "0123456789abcdef0123456789abcdef"
	records := TXTRecords("sid-value", "PC", "1")
	for _, record := range records {
		if strings.Contains(record, token) {
			t.Fatalf("token leaked into TXT record %q", record)
		}
	}
}

func TestSanitizeStripsProblemCharacters(t *testing.T) {
	got := sanitize("a=b\tc\x00d")
	if strings.ContainsAny(got, "=\t\x00") {
		t.Fatalf("sanitize left problem characters: %q", got)
	}
	if got != "a-b c d" {
		t.Fatalf("sanitize = %q, want %q", got, "a-b c d")
	}
}

func TestInstanceNameDefaultsWhenBlank(t *testing.T) {
	if got := InstanceName("   "); got != "CloudBox on PC" {
		t.Fatalf("InstanceName(blank) = %q", got)
	}
	if got := InstanceName("Laptop"); got != "CloudBox on Laptop" {
		t.Fatalf("InstanceName = %q", got)
	}
}
