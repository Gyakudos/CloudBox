// Package blob implements the content-addressed staging store for transfers.
//
// An upload is written to a staging file in fixed-size appends, resumed by offset, then
// verified with BLAKE3 before it is promoted into the blob cache. Nothing enters the cache
// that has not been hashed from the bytes actually received, so a truncated or corrupted
// upload can never be mistaken for a good one.
//
// The cache is a bounded, best-effort dedupe window, not the permanent home of the data:
// files are copied out of it into the user's sync folders, and the cache is swept by age when
// it exceeds its size cap.
//
// The store never keeps a staging file open between requests. The authoritative offset is the
// file's size on disk, so a dropped connection, a retried request, or a server restart all
// resume from the same place, and an abandoned upload costs a file, not a leaked handle.
package blob

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/zeebo/blake3"
)

var (
	// ErrInvalidHash is returned for a hash that is not 32 hex-encoded bytes.
	ErrInvalidHash = errors.New("blob: invalid hash")
	// ErrHashMismatch is returned when received bytes do not match the declared hash.
	ErrHashMismatch = errors.New("blob: content hash mismatch")
	// ErrOffsetMismatch is returned when an append does not start at the current offset.
	ErrOffsetMismatch = errors.New("blob: offset mismatch")
	// ErrSizeExceeded is returned when a client sends more bytes than it declared.
	ErrSizeExceeded = errors.New("blob: upload exceeds declared size")
	// ErrIncomplete is returned when a commit arrives before every byte has been written.
	ErrIncomplete = errors.New("blob: upload is incomplete")
	// ErrNotFound is returned for an unknown or finished upload.
	ErrNotFound = errors.New("blob: upload not found")
	// ErrTooLarge is returned when an upload's declared size exceeds the limit.
	ErrTooLarge = errors.New("blob: declared size is too large")
)

const (
	// DefaultMaxSize caps a single file at 16 GiB: larger than any phone video today, small
	// enough that a hostile client cannot fill the disk with one bogus declaration.
	DefaultMaxSize = 16 << 30
	// DefaultCacheSize bounds the retained blob cache at 2 GiB.
	DefaultCacheSize = 2 << 30
	// staleUploadAge is how long an abandoned staging file survives a restart.
	staleUploadAge = 24 * time.Hour
)

// Store manages staging files and the verified blob cache under a single root.
type Store struct {
	stagingDir string
	blobsDir   string
	maxSize    int64

	mu      sync.Mutex
	uploads map[string]*Upload
	now     func() time.Time
}

// Open prepares the store rooted at root, sweeping staging files abandoned by a previous run.
func Open(root string, maxSize int64) (*Store, error) {
	if maxSize <= 0 {
		maxSize = DefaultMaxSize
	}

	s := &Store{
		stagingDir: filepath.Join(root, "staging"),
		blobsDir:   filepath.Join(root, "blobs"),
		maxSize:    maxSize,
		uploads:    make(map[string]*Upload),
		now:        time.Now,
	}

	for _, dir := range []string{s.stagingDir, s.blobsDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("blob: create %s: %w", dir, err)
		}
	}
	if err := s.sweepStaging(); err != nil {
		return nil, err
	}
	return s, nil
}

// Upload describes one in-flight transfer.
type Upload struct {
	ID   string
	Hash string
	Size int64
	// FolderID is the sync folder the client intends to finalize into. It is set by the API
	// layer at creation time and read back at commit time.
	FolderID string

	path  string
	store *Store
	done  bool
	mu    sync.Mutex
}

// CreateUpload reserves a staging file for content with the given hash and size.
func (s *Store) CreateUpload(hash string, size int64) (*Upload, error) {
	hash, err := normaliseHash(hash)
	if err != nil {
		return nil, err
	}
	if size <= 0 {
		return nil, fmt.Errorf("blob: size must be positive")
	}
	if size > s.maxSize {
		return nil, ErrTooLarge
	}

	idBytes := make([]byte, 16)
	if _, err := rand.Read(idBytes); err != nil {
		return nil, err
	}
	id := hex.EncodeToString(idBytes)

	path := filepath.Join(s.stagingDir, id+".part")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return nil, fmt.Errorf("blob: create staging file: %w", err)
	}
	if err := file.Close(); err != nil {
		os.Remove(path)
		return nil, fmt.Errorf("blob: close new staging file: %w", err)
	}

	upload := &Upload{ID: id, Hash: hash, Size: size, path: path, store: s}

	s.mu.Lock()
	s.uploads[id] = upload
	s.mu.Unlock()

	return upload, nil
}

// Upload returns a live upload by ID.
func (s *Store) Upload(id string) (*Upload, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	upload, ok := s.uploads[id]
	return upload, ok
}

// Discard abandons an upload and removes its staging file.
func (s *Store) Discard(id string) error {
	s.mu.Lock()
	upload, ok := s.uploads[id]
	delete(s.uploads, id)
	s.mu.Unlock()
	if !ok {
		return ErrNotFound
	}
	return upload.discard()
}

// Has reports whether a verified blob is already cached.
func (s *Store) Has(hash string) bool {
	normalised, err := normaliseHash(hash)
	if err != nil {
		return false
	}
	info, err := os.Stat(s.blobPath(normalised))
	return err == nil && info.Mode().IsRegular()
}

// Size returns the cached size of a blob.
func (s *Store) Size(hash string) (int64, bool) {
	normalised, err := normaliseHash(hash)
	if err != nil {
		return 0, false
	}
	info, err := os.Stat(s.blobPath(normalised))
	if err != nil || !info.Mode().IsRegular() {
		return 0, false
	}
	return info.Size(), true
}

// Path returns the filesystem path a verified blob is cached at. The caller must not assume
// it exists; check Has first.
func (s *Store) Path(hash string) string {
	normalised, err := normaliseHash(hash)
	if err != nil {
		return ""
	}
	return s.blobPath(normalised)
}

// OpenBlob opens a cached blob for reading. The returned reader reports its size.
func (s *Store) OpenBlob(hash string) (io.ReadCloser, int64, error) {
	normalised, err := normaliseHash(hash)
	if err != nil {
		return nil, 0, err
	}
	file, err := os.Open(s.blobPath(normalised))
	if err != nil {
		return nil, 0, err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, 0, err
	}
	return file, info.Size(), nil
}

// SweepCache deletes the oldest blobs until the cache fits within maxBytes.
func (s *Store) SweepCache(maxBytes int64) error {
	if maxBytes <= 0 {
		maxBytes = DefaultCacheSize
	}

	var blobs []struct {
		path string
		size int64
		mod  time.Time
	}
	var total int64

	err := filepath.Walk(s.blobsDir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		blobs = append(blobs, struct {
			path string
			size int64
			mod  time.Time
		}{path, info.Size(), info.ModTime()})
		total += info.Size()
		return nil
	})
	if err != nil {
		return fmt.Errorf("blob: walk cache: %w", err)
	}

	if total <= maxBytes {
		return nil
	}

	sort.Slice(blobs, func(i, j int) bool { return blobs[i].mod.Before(blobs[j].mod) })
	for _, candidate := range blobs {
		if total <= maxBytes {
			break
		}
		if err := os.Remove(candidate.path); err != nil {
			continue
		}
		total -= candidate.size
	}
	return nil
}

// Progress returns the bytes received so far and the declared total. The received count is
// read from the staging file, so it is correct even if this process never wrote those bytes.
func (u *Upload) Progress() (offset, size int64) {
	u.mu.Lock()
	defer u.mu.Unlock()

	if info, err := os.Stat(u.path); err == nil {
		return info.Size(), u.Size
	}
	return 0, u.Size
}

// WriteAt appends at exactly offset. A mismatch returns the real offset with
// ErrOffsetMismatch so the client can resynchronise without re-sending good bytes.
func (u *Upload) WriteAt(offset int64, r io.Reader) (int64, error) {
	u.mu.Lock()
	defer u.mu.Unlock()

	if u.done {
		return 0, ErrNotFound
	}

	current, err := u.stagingSize()
	if err != nil {
		return 0, err
	}
	if offset != current {
		return current, ErrOffsetMismatch
	}
	if current >= u.Size {
		return current, ErrSizeExceeded
	}

	file, err := os.OpenFile(u.path, os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return current, fmt.Errorf("blob: open staging file: %w", err)
	}
	defer file.Close()

	written, err := io.Copy(file, io.LimitReader(r, u.Size-current))
	if err != nil {
		return current + written, fmt.Errorf("blob: write staging file: %w", err)
	}

	// Reject a client that sends more than it declared rather than silently truncating: the
	// hash would fail later, with a much less useful error.
	if current+written == u.Size {
		var extra [1]byte
		if n, _ := r.Read(extra[:]); n > 0 {
			return current + written, ErrSizeExceeded
		}
	}

	// fsync before acknowledging, so a crash cannot acknowledge bytes that are not on disk.
	if err := file.Sync(); err != nil {
		return current + written, fmt.Errorf("blob: sync staging file: %w", err)
	}
	return current + written, nil
}

// Commit verifies the received bytes and promotes them into the blob cache. It returns the
// cached path and whether the content was already present.
func (u *Upload) Commit() (string, bool, error) {
	u.mu.Lock()
	defer u.mu.Unlock()

	if u.done {
		return "", false, ErrNotFound
	}

	size, err := u.stagingSize()
	if err != nil {
		return "", false, err
	}
	if size != u.Size {
		return "", false, fmt.Errorf("%w: %d of %d bytes", ErrIncomplete, size, u.Size)
	}

	u.done = true

	actual, err := HashFile(u.path)
	if err != nil {
		os.Remove(u.path)
		return "", false, err
	}
	if actual != u.Hash {
		os.Remove(u.path)
		return "", false, fmt.Errorf("%w: got %s, declared %s", ErrHashMismatch, actual, u.Hash)
	}

	target := u.store.blobPath(u.Hash)
	if info, err := os.Stat(target); err == nil && info.Mode().IsRegular() {
		os.Remove(u.path)
		return target, true, nil
	}

	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		os.Remove(u.path)
		return "", false, fmt.Errorf("blob: create cache dir: %w", err)
	}
	if err := os.Rename(u.path, target); err != nil {
		os.Remove(u.path)
		return "", false, fmt.Errorf("blob: promote blob: %w", err)
	}
	return target, false, nil
}

func (u *Upload) stagingSize() (int64, error) {
	info, err := os.Stat(u.path)
	if err != nil {
		return 0, fmt.Errorf("blob: stat staging file: %w", err)
	}
	return info.Size(), nil
}

func (u *Upload) discard() error {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.done {
		return ErrNotFound
	}
	u.done = true
	return os.Remove(u.path)
}

func (s *Store) blobPath(hash string) string {
	return filepath.Join(s.blobsDir, hash[:2], hash)
}

// sweepStaging removes staging files left behind by a previous process.
func (s *Store) sweepStaging() error {
	entries, err := os.ReadDir(s.stagingDir)
	if err != nil {
		return fmt.Errorf("blob: read staging dir: %w", err)
	}
	cutoff := s.now().Add(-staleUploadAge)
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if info.ModTime().Before(cutoff) {
			os.Remove(filepath.Join(s.stagingDir, entry.Name()))
		}
	}
	return nil
}

// HashFile returns the hex BLAKE3-256 digest of a file's contents.
func HashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("blob: open %s: %w", path, err)
	}
	defer file.Close()
	return Hash(file)
}

// Hash returns the hex BLAKE3-256 digest of a reader.
func Hash(r io.Reader) (string, error) {
	hasher := blake3.New()
	if _, err := io.Copy(hasher, r); err != nil {
		return "", fmt.Errorf("blob: hash content: %w", err)
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func normaliseHash(hash string) (string, error) {
	hash = strings.ToLower(strings.TrimSpace(hash))
	if len(hash) != 64 {
		return "", ErrInvalidHash
	}
	if _, err := hex.DecodeString(hash); err != nil {
		return "", ErrInvalidHash
	}
	return hash, nil
}
