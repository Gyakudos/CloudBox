// Package safepath turns untrusted, phone-supplied relative paths into paths that are safe to
// write inside a sync root.
//
// This is the only place in the agent that trusts nothing. Every byte of a path that arrives
// over the wire passes through Clean before it touches the filesystem, so a malicious or
// buggy client cannot escape the sync root, overwrite a system file, or produce a name the
// target filesystem cannot represent.
//
// The Windows rules are applied whenever the policy says so, even on a non-Windows host, so
// the same path sanitises identically in tests and on the machine that will eventually hold
// the files.
package safepath

import (
	"errors"
	"path"
	"runtime"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

var (
	// ErrEmpty is returned for a path with no usable segments.
	ErrEmpty = errors.New("safepath: empty path")
	// ErrAbsolute is returned for absolute paths and Windows drive-relative paths.
	ErrAbsolute = errors.New("safepath: absolute paths are not allowed")
	// ErrTraversal is returned when a segment is "..".
	ErrTraversal = errors.New("safepath: parent traversal is not allowed")
	// ErrInvalid is returned when a segment cannot be represented at all.
	ErrInvalid = errors.New("safepath: path segment is not representable")
)

// DefaultMaxSegmentBytes matches the ext4 and NTFS component limit.
const DefaultMaxSegmentBytes = 255

// Policy configures the target filesystem's rules.
type Policy struct {
	// Windows applies reserved-name and illegal-character rules and forbids trailing dots
	// and spaces.
	Windows bool
	// MaxSegmentBytes caps each path component.
	MaxSegmentBytes int
}

// DefaultPolicy returns the policy for the current host.
func DefaultPolicy() Policy {
	return Policy{
		Windows:         runtime.GOOS == "windows",
		MaxSegmentBytes: DefaultMaxSegmentBytes,
	}
}

// windowsReserved are device names that cannot be used as filenames on Windows, with or
// without an extension.
var windowsReserved = map[string]bool{
	"CON": true, "PRN": true, "AUX": true, "NUL": true,
	"COM1": true, "COM2": true, "COM3": true, "COM4": true, "COM5": true,
	"COM6": true, "COM7": true, "COM8": true, "COM9": true,
	"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true, "LPT5": true,
	"LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true,
}

// Clean normalises rel and validates it for the given policy. The result always uses "/" as
// the separator; callers convert with filepath.FromSlash.
func Clean(rel string, policy Policy) (string, error) {
	if policy.MaxSegmentBytes <= 0 {
		policy.MaxSegmentBytes = DefaultMaxSegmentBytes
	}

	// NFC first: macOS stores NFD, Android and Windows use NFC, and comparing raw bytes
	// across them produces phantom duplicates.
	rel = norm.NFC.String(rel)
	rel = strings.ReplaceAll(rel, `\`, "/")

	if strings.HasPrefix(rel, "/") {
		return "", ErrAbsolute
	}
	if len(rel) >= 2 && rel[1] == ':' {
		return "", ErrAbsolute
	}
	if strings.ContainsRune(rel, 0) {
		return "", ErrInvalid
	}

	segments := strings.Split(rel, "/")
	cleaned := make([]string, 0, len(segments))

	for _, segment := range segments {
		if segment == "" || segment == "." {
			continue
		}
		if segment == ".." {
			return "", ErrTraversal
		}

		sanitised, err := cleanSegment(segment, policy)
		if err != nil {
			return "", err
		}
		cleaned = append(cleaned, sanitised)
	}

	if len(cleaned) == 0 {
		return "", ErrEmpty
	}
	return strings.Join(cleaned, "/"), nil
}

func cleanSegment(segment string, policy Policy) (string, error) {
	if policy.Windows {
		var b strings.Builder
		b.Grow(len(segment))
		for _, r := range segment {
			switch {
			case r < 0x20 || r == 0x7F:
				b.WriteByte('_')
			case strings.ContainsRune(`<>:"|?*`, r):
				b.WriteByte('_')
			default:
				b.WriteRune(r)
			}
		}
		segment = b.String()

		// Windows silently strips trailing dots and spaces, which would make two distinct
		// client paths collide on disk. Strip them here so the index matches reality.
		segment = strings.TrimRight(segment, ". ")

		stem := segment
		if idx := strings.IndexByte(segment, '.'); idx >= 0 {
			stem = segment[:idx]
		}
		if windowsReserved[strings.ToUpper(stem)] {
			segment = "_" + segment
		}
	} else {
		for _, r := range segment {
			if r < 0x20 || r == 0x7F {
				return "", ErrInvalid
			}
		}
	}

	segment = strings.TrimRight(segment, " ")
	if segment == "" {
		return "", ErrInvalid
	}

	segment = truncateSegment(segment, policy.MaxSegmentBytes)
	if segment == "" {
		return "", ErrInvalid
	}
	return segment, nil
}

// truncateSegment shortens a name to maxBytes without splitting a rune, preferring to keep
// the extension intact so the file still opens with the right application.
func truncateSegment(name string, maxBytes int) string {
	if len(name) <= maxBytes {
		return name
	}

	ext := path.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	if len(ext) >= maxBytes/2 {
		// Not really an extension; treat the whole name as the stem.
		ext = ""
		stem = name
	}

	keep := maxBytes - len(ext)
	if keep < 1 {
		return ""
	}
	stem = truncateUTF8(stem, keep)
	if stem == "" {
		return ""
	}
	return stem + ext
}

func truncateUTF8(s string, maxBytes int) string {
	if len(s) <= maxBytes {
		return s
	}
	s = s[:maxBytes]
	for len(s) > 0 && !utf8.ValidString(s) {
		s = s[:len(s)-1]
	}
	return s
}

// Unique returns rel if it is free, otherwise appends "~1", "~2", ... before the extension
// until it is. exists is called with slash-form paths and must perform a case-insensitive
// check on case-insensitive filesystems.
func Unique(rel string, exists func(string) bool) string {
	if !exists(rel) {
		return rel
	}

	dir := path.Dir(rel)
	base := path.Base(rel)
	ext := path.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	if dir == "." {
		dir = ""
	}

	for i := 1; i < 10_000; i++ {
		candidate := withSuffix(stem, ext, i)
		if dir != "" {
			candidate = dir + "/" + candidate
		}
		if !exists(candidate) {
			return candidate
		}
	}
	return rel
}

func withSuffix(stem, ext string, n int) string {
	var b strings.Builder
	b.WriteString(stem)
	b.WriteByte('~')
	b.WriteString(itoa(n))
	b.WriteString(ext)
	return b.String()
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits [8]byte
	i := len(digits)
	for n > 0 {
		i--
		digits[i] = byte('0' + n%10)
		n /= 10
	}
	return string(digits[i:])
}
