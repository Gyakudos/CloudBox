// Package folder materialises verified blobs as ordinary files inside a sync root.
//
// The user's drive stays a normal folder tree: real names, real files, browsable in Explorer.
// Content-addressed staging is only a rest stop. Every write is atomic (temp file plus
// rename), so an interrupted finalize can never leave a half-written photo behind.
package folder

import (
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/safepath"
)

// Finalizer writes blobs into one sync root.
type Finalizer struct {
	// Root is the absolute sync root, chosen by the user on the phone.
	Root string
	// Policy controls path sanitisation for the target filesystem.
	Policy safepath.Policy
	// Now supplies the current time for callers that pass a zero mtime.
	Now func() time.Time
}

// New prepares a finalizer rooted at root, creating the directory if needed.
func New(root string, policy safepath.Policy) (*Finalizer, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("folder: resolve root: %w", err)
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return nil, fmt.Errorf("folder: create root %s: %w", abs, err)
	}
	return &Finalizer{Root: abs, Policy: policy, Now: time.Now}, nil
}

// Result describes where a blob landed.
type Result struct {
	// Path is the sanitised slash-form relative path actually written. It may differ from the
	// requested path when characters were replaced or a case collision was resolved.
	Path string
	// Abs is the absolute filesystem path.
	Abs string
	// Replaced is true when an existing file was overwritten.
	Replaced bool
}

// Place copies a verified blob from blobPath to rel inside the root, atomically replacing any
// existing file at that path.
//
// It copies rather than hard-links on purpose. A hard link would share an inode with the blob
// cache, so a user editing or deleting the file in Explorer would silently corrupt the cache
// and poison dedupe for every future upload of that content. A local copy costs disk IO, not
// network bandwidth, which is the trade this design accepts.
func (f *Finalizer) Place(rel, blobPath, hash string, mtime time.Time) (Result, error) {
	clean, err := safepath.Clean(rel, f.Policy)
	if err != nil {
		return Result{}, err
	}

	if mtime.IsZero() {
		mtime = f.Now()
	}

	clean, err = f.resolveCaseCollision(clean)
	if err != nil {
		return Result{}, err
	}

	abs := filepath.Join(f.Root, filepath.FromSlash(clean))
	dir := filepath.Dir(abs)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Result{}, fmt.Errorf("folder: create %s: %w", dir, err)
	}

	_, statErr := os.Stat(abs)
	replaced := statErr == nil

	temp, err := os.CreateTemp(dir, ".cloudbox-*.part")
	if err != nil {
		return Result{}, fmt.Errorf("folder: create temp file: %w", err)
	}
	tempName := temp.Name()
	defer os.Remove(tempName) // no-op after a successful rename

	if err := copyFile(temp, blobPath); err != nil {
		temp.Close()
		return Result{}, err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return Result{}, fmt.Errorf("folder: sync %s: %w", tempName, err)
	}
	if err := temp.Close(); err != nil {
		return Result{}, fmt.Errorf("folder: close %s: %w", tempName, err)
	}
	if err := os.Chtimes(tempName, mtime, mtime); err != nil {
		return Result{}, fmt.Errorf("folder: set mtime: %w", err)
	}
	if err := os.Rename(tempName, abs); err != nil {
		return Result{}, fmt.Errorf("folder: finalise %s: %w", abs, err)
	}

	_ = hash // the caller verified the content before it reached the cache
	return Result{Path: clean, Abs: abs, Replaced: replaced}, nil
}

// resolveCaseCollision keeps a new file from overwriting a differently-cased sibling on a
// case-insensitive filesystem.
func (f *Finalizer) resolveCaseCollision(clean string) (string, error) {
	if !f.Policy.Windows {
		return clean, nil
	}

	dirAbs := filepath.Join(f.Root, filepath.FromSlash(path.Dir(clean)))
	base := path.Base(clean)

	entries, err := os.ReadDir(dirAbs)
	if err != nil {
		if os.IsNotExist(err) {
			return clean, nil
		}
		return "", fmt.Errorf("folder: read %s: %w", dirAbs, err)
	}

	collides := false
	for _, entry := range entries {
		if entry.Name() != base && strings.EqualFold(entry.Name(), base) {
			collides = true
			break
		}
	}
	if !collides {
		return clean, nil
	}

	exists := func(candidate string) bool {
		name := path.Base(candidate)
		for _, entry := range entries {
			if strings.EqualFold(entry.Name(), name) {
				return true
			}
		}
		return false
	}
	return safepath.Unique(clean, exists), nil
}

func copyFile(dst *os.File, srcPath string) error {
	src, err := os.Open(srcPath)
	if err != nil {
		return fmt.Errorf("folder: open blob: %w", err)
	}
	defer src.Close()

	if _, err := io.Copy(dst, src); err != nil {
		return fmt.Errorf("folder: copy blob: %w", err)
	}
	return nil
}
