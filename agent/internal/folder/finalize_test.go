package folder

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/safepath"
)

func newFinalizer(t *testing.T, policy safepath.Policy) (*Finalizer, string) {
	t.Helper()
	root := t.TempDir()
	f, err := New(root, policy)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return f, root
}

// blobFile writes source content somewhere on disk, standing in for the verified blob cache.
func blobFile(t *testing.T, data string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "blob")
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatalf("write blob: %v", err)
	}
	return path
}

var (
	unixPolicy = safepath.Policy{Windows: false, MaxSegmentBytes: safepath.DefaultMaxSegmentBytes}
	winPolicy  = safepath.Policy{Windows: true, MaxSegmentBytes: safepath.DefaultMaxSegmentBytes}
)

func TestPlaceWritesNestedFile(t *testing.T) {
	f, root := newFinalizer(t, unixPolicy)
	mtime := time.Date(2026, 3, 4, 5, 6, 7, 0, time.UTC)

	res, err := f.Place("DCIM/Camera/IMG_0001.jpg", blobFile(t, "photo-bytes"), "hash", mtime)
	if err != nil {
		t.Fatalf("Place: %v", err)
	}
	if res.Replaced {
		t.Error("Replaced = true on a fresh path")
	}
	if res.Path != "DCIM/Camera/IMG_0001.jpg" {
		t.Errorf("Path = %q", res.Path)
	}

	got, err := os.ReadFile(filepath.Join(root, "DCIM", "Camera", "IMG_0001.jpg"))
	if err != nil {
		t.Fatalf("read placed file: %v", err)
	}
	if string(got) != "photo-bytes" {
		t.Fatalf("content = %q", got)
	}

	info, err := os.Stat(res.Abs)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if !info.ModTime().Equal(mtime) {
		t.Errorf("mtime = %v, want %v", info.ModTime(), mtime)
	}
}

func TestPlaceReplacesExistingFileAtomically(t *testing.T) {
	f, root := newFinalizer(t, unixPolicy)

	if _, err := f.Place("a/note.txt", blobFile(t, "first"), "h1", time.Time{}); err != nil {
		t.Fatalf("first Place: %v", err)
	}
	res, err := f.Place("a/note.txt", blobFile(t, "second"), "h2", time.Time{})
	if err != nil {
		t.Fatalf("second Place: %v", err)
	}
	if !res.Replaced {
		t.Error("Replaced = false when overwriting an existing file")
	}

	got, _ := os.ReadFile(filepath.Join(root, "a", "note.txt"))
	if string(got) != "second" {
		t.Fatalf("content = %q, want the replacement", got)
	}

	// No temp files may survive a successful place.
	entries, _ := os.ReadDir(filepath.Join(root, "a"))
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".cloudbox-") {
			t.Fatalf("temp file %q was left behind", entry.Name())
		}
	}
}

func TestPlaceRejectsTraversal(t *testing.T) {
	f, _ := newFinalizer(t, unixPolicy)
	if _, err := f.Place("../escape.txt", blobFile(t, "x"), "h", time.Time{}); err == nil {
		t.Fatal("traversal path was accepted")
	}
}

func TestPlaceSanitisesWindowsNames(t *testing.T) {
	f, root := newFinalizer(t, winPolicy)

	res, err := f.Place(`reports/q1<final>:v2?.txt`, blobFile(t, "data"), "h", time.Time{})
	if err != nil {
		t.Fatalf("Place: %v", err)
	}
	if strings.ContainsAny(res.Path, `<>:"|?*`) {
		t.Fatalf("illegal characters survived: %q", res.Path)
	}
	if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(res.Path))); err != nil {
		t.Fatalf("placed file not found at %s: %v", res.Path, err)
	}
}

func TestPlaceResolvesCaseCollisionOnWindows(t *testing.T) {
	f, root := newFinalizer(t, winPolicy)

	if _, err := f.Place("Photos/beach.jpg", blobFile(t, "lower"), "h1", time.Time{}); err != nil {
		t.Fatalf("first Place: %v", err)
	}
	res, err := f.Place("Photos/BEACH.JPG", blobFile(t, "upper"), "h2", time.Time{})
	if err != nil {
		t.Fatalf("second Place: %v", err)
	}

	if res.Path == "Photos/BEACH.JPG" {
		t.Fatal("a differently-cased sibling was allowed to overwrite the original")
	}
	if !strings.Contains(res.Path, "~1") {
		t.Fatalf("collision was not resolved with a unique suffix: %q", res.Path)
	}

	// The original must be untouched.
	original, _ := os.ReadFile(filepath.Join(root, "Photos", "beach.jpg"))
	if string(original) != "lower" {
		t.Fatalf("original content = %q, want it preserved", original)
	}
}

func TestPlaceAllowsCaseVariantsOnUnix(t *testing.T) {
	f, _ := newFinalizer(t, unixPolicy)

	if _, err := f.Place("a/Photo.jpg", blobFile(t, "one"), "h1", time.Time{}); err != nil {
		t.Fatalf("first Place: %v", err)
	}
	res, err := f.Place("a/photo.jpg", blobFile(t, "two"), "h2", time.Time{})
	if err != nil {
		t.Fatalf("second Place: %v", err)
	}
	if res.Path != "a/photo.jpg" {
		t.Fatalf("case-sensitive filesystems should keep both names, got %q", res.Path)
	}
}

func TestPlaceUsesNowWhenMtimeIsZero(t *testing.T) {
	f, _ := newFinalizer(t, unixPolicy)
	fixed := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	f.Now = func() time.Time { return fixed }

	res, err := f.Place("x.txt", blobFile(t, "y"), "h", time.Time{})
	if err != nil {
		t.Fatalf("Place: %v", err)
	}
	info, _ := os.Stat(res.Abs)
	if !info.ModTime().Equal(fixed) {
		t.Errorf("mtime = %v, want the injected now %v", info.ModTime(), fixed)
	}
}

func TestNewCreatesMissingRoot(t *testing.T) {
	root := filepath.Join(t.TempDir(), "drive", "CloudBox")
	if _, err := New(root, unixPolicy); err != nil {
		t.Fatalf("New: %v", err)
	}
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		t.Fatalf("root was not created: %v", err)
	}
}
