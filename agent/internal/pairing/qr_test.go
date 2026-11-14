package pairing

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func samplePayload(t *testing.T) string {
	t.Helper()
	raw, err := json.Marshal(Payload{
		V:   1,
		SID: "a356147950ad0faf88481dcd0cf5567a",
		EPs: []string{"192.168.1.20:8443", "cloudbox.local:8443", "127.0.0.1:8443"},
		Pin: strings.Repeat("ab", 32),
		Tok: strings.Repeat("cd", 16),
	})
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	return string(raw)
}

func TestQRPNGProducesAPNG(t *testing.T) {
	png, err := QRPNG(samplePayload(t))
	if err != nil {
		t.Fatalf("QRPNG: %v", err)
	}
	if !bytes.HasPrefix(png, []byte("\x89PNG\r\n\x1a\n")) {
		t.Fatal("output is not a PNG")
	}
	if len(png) < 100 {
		t.Fatalf("PNG is suspiciously small: %d bytes", len(png))
	}
}

func TestQRTextRendersBlocks(t *testing.T) {
	text, err := QRText(samplePayload(t))
	if err != nil {
		t.Fatalf("QRText: %v", err)
	}
	if !strings.ContainsAny(text, "█▀▄") {
		t.Fatal("ASCII QR contains no block characters")
	}
	lines := strings.Split(strings.Trim(text, "\n"), "\n")
	if len(lines) < 20 {
		t.Fatalf("QR looks too small: %d lines", len(lines))
	}
	// Every row must be the same width, or the code will not scan.
	width := len([]rune(lines[0]))
	for i, line := range lines {
		if got := len([]rune(line)); got != width {
			t.Fatalf("row %d width = %d, want %d", i, got, width)
		}
	}
}

func TestQREncodingRejectsOversizedInput(t *testing.T) {
	// A QR code cannot hold unbounded data; the encoder must fail rather than panic.
	if _, err := QRPNG(strings.Repeat("x", 5000)); err == nil {
		t.Fatal("oversized input was accepted")
	}
}
