package pairing

import (
	"fmt"
	"strings"

	"rsc.io/qr"
)

// QRPNG renders text as a PNG QR code, suitable for writing to a file the user can scan from
// the setup screen.
func QRPNG(text string) ([]byte, error) {
	code, err := qr.Encode(text, qr.M)
	if err != nil {
		return nil, fmt.Errorf("pairing: encode QR: %w", err)
	}
	return code.PNG(), nil
}

// QRText renders text as a QR code made of block characters for the terminal, so pairing works
// on a headless machine without opening the PNG. Two QR rows share one text row, using the
// upper and lower half-block runes.
func QRText(text string) (string, error) {
	code, err := qr.Encode(text, qr.M)
	if err != nil {
		return "", fmt.Errorf("pairing: encode QR: %w", err)
	}

	const quiet = 2
	size := code.Size
	var b strings.Builder
	b.WriteByte('\n')

	// Quiet zone at the top.
	blank := strings.Repeat(" ", (size+2*quiet)*2)
	for i := 0; i < quiet; i++ {
		b.WriteString(blank)
		b.WriteByte('\n')
	}

	for y := 0; y < size; y += 2 {
		for i := 0; i < quiet; i++ {
			b.WriteString("  ")
		}
		for x := 0; x < size; x++ {
			top := code.Black(x, y)
			bottom := y+1 < size && code.Black(x, y+1)
			switch {
			case top && bottom:
				b.WriteString("█")
			case top:
				b.WriteString("▀")
			case bottom:
				b.WriteString("▄")
			default:
				b.WriteString(" ")
			}
			b.WriteString(" ")
		}
		for i := 0; i < quiet; i++ {
			b.WriteString("  ")
		}
		b.WriteByte('\n')
	}

	for i := 0; i < quiet; i++ {
		b.WriteString(blank)
		b.WriteByte('\n')
	}
	return b.String(), nil
}
