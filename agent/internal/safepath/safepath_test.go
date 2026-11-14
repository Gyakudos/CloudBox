package safepath

import (
	"errors"
	"strings"
	"testing"
)

var winPolicy = Policy{Windows: true, MaxSegmentBytes: DefaultMaxSegmentBytes}
var unixPolicy = Policy{Windows: false, MaxSegmentBytes: DefaultMaxSegmentBytes}

func TestCleanAcceptsNormalPaths(t *testing.T) {
	cases := map[string]string{
		"DCIM/Camera/IMG_0001.jpg":      "DCIM/Camera/IMG_0001.jpg",
		"./DCIM//Camera/x.mp4":          "DCIM/Camera/x.mp4",
		"a/b/./c.txt":                   "a/b/c.txt",
		"Music/Album 01/Track 1.mp3":    "Music/Album 01/Track 1.mp3",
		"Documents/report (final).docx": "Documents/report (final).docx",
		"unicode/日本語/写真.jpg":            "unicode/日本語/写真.jpg",
		"dots/in.name.with.dots.tar.gz": "dots/in.name.with.dots.tar.gz",
	}

	for input, want := range cases {
		got, err := Clean(input, unixPolicy)
		if err != nil {
			t.Errorf("Clean(%q) error: %v", input, err)
			continue
		}
		if got != want {
			t.Errorf("Clean(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestCleanRejectsTraversal(t *testing.T) {
	for _, input := range []string{
		"../etc/passwd",
		"a/../../b",
		"a/..",
		"..",
		"a/..\\..\\b",
	} {
		if _, err := Clean(input, unixPolicy); !errors.Is(err, ErrTraversal) {
			t.Errorf("Clean(%q) error = %v, want ErrTraversal", input, err)
		}
	}
}

func TestCleanRejectsAbsolutePaths(t *testing.T) {
	for _, input := range []string{
		"/etc/passwd",
		`\\server\share\file`,
		"C:/Windows/System32/config",
		`C:\Windows`,
	} {
		if _, err := Clean(input, unixPolicy); !errors.Is(err, ErrAbsolute) {
			t.Errorf("Clean(%q) error = %v, want ErrAbsolute", input, err)
		}
	}
}

func TestCleanRejectsEmpty(t *testing.T) {
	for _, input := range []string{"", ".", "./"} {
		if _, err := Clean(input, unixPolicy); !errors.Is(err, ErrEmpty) {
			t.Errorf("Clean(%q) error = %v, want ErrEmpty", input, err)
		}
	}
}

func TestCleanTreatsRootAsAbsolute(t *testing.T) {
	// "/" is empty in content but absolute in form. Reporting ErrAbsolute is the more
	// actionable answer: it tells the caller the client sent a rooted path, not nothing.
	for _, input := range []string{"/", "///", "//server"} {
		if _, err := Clean(input, unixPolicy); !errors.Is(err, ErrAbsolute) {
			t.Errorf("Clean(%q) error = %v, want ErrAbsolute", input, err)
		}
	}
}

func TestCleanRejectsNulByte(t *testing.T) {
	if _, err := Clean("a\x00b", unixPolicy); !errors.Is(err, ErrInvalid) {
		t.Errorf("error = %v, want ErrInvalid", err)
	}
}

func TestWindowsIllegalCharactersAreReplaced(t *testing.T) {
	cases := map[string]string{
		`a<b>c:d"e|f?g*h.txt`: "a_b_c_d_e_f_g_h.txt",
		"tab\there.txt":       "tab_here.txt",
		"newline\nhere.txt":   "newline_here.txt",
	}
	for input, want := range cases {
		got, err := Clean(input, winPolicy)
		if err != nil {
			t.Errorf("Clean(%q) error: %v", input, err)
			continue
		}
		if got != want {
			t.Errorf("Clean(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestWindowsReservedNamesArePrefixed(t *testing.T) {
	for _, input := range []string{
		"CON", "con", "NUL", "nul.txt", "COM1", "com9.log", "LPT1.dat", "AUX", "PRN",
	} {
		got, err := Clean(input, winPolicy)
		if err != nil {
			t.Errorf("Clean(%q) error: %v", input, err)
			continue
		}
		if !strings.HasPrefix(got, "_") {
			t.Errorf("Clean(%q) = %q, want a leading underscore", input, got)
		}
	}

	// Names that merely contain a reserved word must be left alone.
	if got, _ := Clean("CONTENTS.txt", winPolicy); got != "CONTENTS.txt" {
		t.Errorf("Clean(CONTENTS.txt) = %q, want it unchanged", got)
	}
}

func TestWindowsTrailingDotsAndSpacesAreStripped(t *testing.T) {
	cases := map[string]string{
		"file.":      "file",
		"file   ":    "file",
		"a/b. . ":    "a/b",
		"name...txt": "name...txt", // interior dots are legal
	}
	for input, want := range cases {
		got, err := Clean(input, winPolicy)
		if err != nil {
			t.Errorf("Clean(%q) error: %v", input, err)
			continue
		}
		if got != want {
			t.Errorf("Clean(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestLongSegmentsAreTruncatedButKeepExtension(t *testing.T) {
	long := strings.Repeat("a", 400) + ".jpg"
	got, err := Clean(long, unixPolicy)
	if err != nil {
		t.Fatalf("Clean error: %v", err)
	}
	if len(got) > DefaultMaxSegmentBytes {
		t.Errorf("segment is %d bytes, want <= %d", len(got), DefaultMaxSegmentBytes)
	}
	if !strings.HasSuffix(got, ".jpg") {
		t.Errorf("truncation lost the extension: %q", got)
	}
}

func TestTruncationDoesNotSplitRunes(t *testing.T) {
	long := strings.Repeat("日", 200) + ".txt"
	got, err := Clean(long, unixPolicy)
	if err != nil {
		t.Fatalf("Clean error: %v", err)
	}
	for _, r := range got {
		if r == '\uFFFD' {
			t.Fatalf("truncation produced an invalid rune: %q", got)
		}
	}
}

func TestUnicodeIsNormalisedToNFC(t *testing.T) {
	// "é" as e + combining acute (NFD) must become a single precomposed rune.
	nfd := "Cafe\u0301/photo.jpg"
	got, err := Clean(nfd, unixPolicy)
	if err != nil {
		t.Fatalf("Clean error: %v", err)
	}
	if strings.ContainsRune(got, '\u0301') {
		t.Errorf("combining mark survived normalisation: %q", got)
	}
	if !strings.HasPrefix(got, "Café/") {
		t.Errorf("got %q, want NFC form", got)
	}
}

func TestUniqueAddsSuffixBeforeExtension(t *testing.T) {
	taken := map[string]bool{
		"a/photo.jpg":   true,
		"a/photo~1.jpg": true,
	}

	got := Unique("a/photo.jpg", func(p string) bool { return taken[p] })
	if got != "a/photo~2.jpg" {
		t.Fatalf("Unique = %q, want a/photo~2.jpg", got)
	}
}

func TestUniqueLeavesFreePathAlone(t *testing.T) {
	got := Unique("a/b.jpg", func(string) bool { return false })
	if got != "a/b.jpg" {
		t.Fatalf("Unique = %q, want it unchanged", got)
	}
}

func TestUniqueHandlesRootLevelFiles(t *testing.T) {
	taken := map[string]bool{"photo.jpg": true}
	got := Unique("photo.jpg", func(p string) bool { return taken[p] })
	if got != "photo~1.jpg" {
		t.Fatalf("Unique = %q, want photo~1.jpg", got)
	}
}
