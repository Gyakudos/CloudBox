package blob

import (
	"bytes"
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newStore(t *testing.T, maxSize int64) *Store {
	t.Helper()
	store, err := Open(t.TempDir(), maxSize)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return store
}

func content(t *testing.T, n int) []byte {
	t.Helper()
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return buf
}

func hashOf(t *testing.T, data []byte) string {
	t.Helper()
	sum, err := Hash(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("Hash: %v", err)
	}
	return sum
}

func TestUploadRoundTripPromotesToCache(t *testing.T) {
	store := newStore(t, DefaultMaxSize)
	data := content(t, 4096)
	hash := hashOf(t, data)

	upload, err := store.CreateUpload(hash, int64(len(data)))
	if err != nil {
		t.Fatalf("CreateUpload: %v", err)
	}
	t.Cleanup(func() { store.Discard(upload.ID) })

	// Send it in three pieces, the way a flaky phone connection would.
	mid := len(data) / 3
	for _, chunk := range [][]byte{data[:mid], data[mid : 2*mid], data[2*mid:]} {
		offset, _ := upload.Progress()
		if _, err := upload.WriteAt(offset, bytes.NewReader(chunk)); err != nil {
			t.Fatalf("WriteAt(%d): %v", offset, err)
		}
	}

	offset, size := upload.Progress()
	if offset != size {
		t.Fatalf("progress = %d/%d, want complete", offset, size)
	}

	path, existed, err := upload.Commit()
	if err != nil {
		t.Fatalf("Commit: %v", err)
	}
	if existed {
		t.Fatal("Commit reported the blob already existed")
	}
	if !store.Has(hash) {
		t.Fatal("blob is not in the cache after commit")
	}
	if filepath.Base(path) != hash {
		t.Fatalf("blob path %q does not end in the hash", path)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read blob: %v", err)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("cached bytes differ from the uploaded bytes")
	}
	if size, ok := store.Size(hash); !ok || size != int64(len(data)) {
		t.Fatalf("Size = %d, %v; want %d, true", size, ok, len(data))
	}
}

func TestWriteAtRejectsOffsetMismatchWithRealOffset(t *testing.T) {
	store := newStore(t, DefaultMaxSize)
	data := content(t, 1024)
	hash := hashOf(t, data)

	upload, err := store.CreateUpload(hash, int64(len(data)))
	if err != nil {
		t.Fatalf("CreateUpload: %v", err)
	}
	if _, err := upload.WriteAt(0, bytes.NewReader(data[:512])); err != nil {
		t.Fatalf("first WriteAt: %v", err)
	}

	// A resumed client that guessed wrong must be told the real offset so it can seek
	// without re-sending good bytes.
	got, err := upload.WriteAt(0, bytes.NewReader(data[512:]))
	if !errors.Is(err, ErrOffsetMismatch) {
		t.Fatalf("error = %v, want ErrOffsetMismatch", err)
	}
	if got != 512 {
		t.Fatalf("reported offset = %d, want 512", got)
	}

	if _, err := upload.WriteAt(512, bytes.NewReader(data[512:])); err != nil {
		t.Fatalf("resume at the real offset: %v", err)
	}
	if _, _, err := upload.Commit(); err != nil {
		t.Fatalf("Commit after resume: %v", err)
	}
}

func TestCommitRejectsHashMismatchAndRemovesStaging(t *testing.T) {
	store := newStore(t, DefaultMaxSize)
	data := content(t, 2048)
	// Declare the hash of different content: the server must hash what actually arrived.
	lie := hashOf(t, content(t, 2048))

	upload, err := store.CreateUpload(lie, int64(len(data)))
	if err != nil {
		t.Fatalf("CreateUpload: %v", err)
	}
	if _, err := upload.WriteAt(0, bytes.NewReader(data)); err != nil {
		t.Fatalf("WriteAt: %v", err)
	}
	if _, _, err := upload.Commit(); !errors.Is(err, ErrHashMismatch) {
		t.Fatalf("error = %v, want ErrHashMismatch", err)
	}
	if store.Has(lie) {
		t.Fatal("a corrupt upload was promoted into the cache")
	}
	if stagingFiles(t, store) != 0 {
		t.Fatal("staging file survived a failed commit")
	}
}

func TestCommitRejectsIncompleteUpload(t *testing.T) {
	store := newStore(t, DefaultMaxSize)
	data := content(t, 1000)
	hash := hashOf(t, data)

	upload, err := store.CreateUpload(hash, int64(len(data)))
	if err != nil {
		t.Fatalf("CreateUpload: %v", err)
	}
	t.Cleanup(func() { store.Discard(upload.ID) })
	if _, err := upload.WriteAt(0, bytes.NewReader(data[:400])); err != nil {
		t.Fatalf("WriteAt: %v", err)
	}
	if _, _, err := upload.Commit(); !errors.Is(err, ErrIncomplete) {
		t.Fatalf("error = %v, want ErrIncomplete", err)
	}
}

func TestWriteAtRejectsMoreThanDeclared(t *testing.T) {
	store := newStore(t, DefaultMaxSize)
	data := content(t, 256)
	hash := hashOf(t, data)

	upload, err := store.CreateUpload(hash, 128)
	if err != nil {
		t.Fatalf("CreateUpload: %v", err)
	}
	t.Cleanup(func() { store.Discard(upload.ID) })
	if _, err := upload.WriteAt(0, bytes.NewReader(data)); !errors.Is(err, ErrSizeExceeded) {
		t.Fatalf("error = %v, want ErrSizeExceeded", err)
	}
}

func TestCreateUploadValidatesArguments(t *testing.T) {
	store := newStore(t, 1024)
	valid := hashOf(t, []byte("x"))

	if _, err := store.CreateUpload("nothex", 1); !errors.Is(err, ErrInvalidHash) {
		t.Errorf("bad hash error = %v, want ErrInvalidHash", err)
	}
	if _, err := store.CreateUpload(valid, 0); err == nil {
		t.Error("zero size was accepted")
	}
	if _, err := store.CreateUpload(valid, 2048); !errors.Is(err, ErrTooLarge) {
		t.Errorf("oversize error = %v, want ErrTooLarge", err)
	}
}

func TestDedupeReturnsExistingBlob(t *testing.T) {
	store := newStore(t, DefaultMaxSize)
	data := content(t, 512)
	hash := hashOf(t, data)

	first, _ := store.CreateUpload(hash, int64(len(data)))
	first.WriteAt(0, bytes.NewReader(data))
	if _, existed, err := first.Commit(); err != nil || existed {
		t.Fatalf("first commit = %v, %v; want false, nil", existed, err)
	}

	second, _ := store.CreateUpload(hash, int64(len(data)))
	second.WriteAt(0, bytes.NewReader(data))
	_, existed, err := second.Commit()
	if err != nil {
		t.Fatalf("second commit: %v", err)
	}
	if !existed {
		t.Fatal("second commit of identical content did not report dedupe")
	}
	if stagingFiles(t, store) != 0 {
		t.Fatal("deduped staging file was left behind")
	}
}

func TestDiscardRemovesStagingFile(t *testing.T) {
	store := newStore(t, DefaultMaxSize)
	data := content(t, 128)
	upload, _ := store.CreateUpload(hashOf(t, data), int64(len(data)))
	upload.WriteAt(0, bytes.NewReader(data[:64]))

	if err := store.Discard(upload.ID); err != nil {
		t.Fatalf("Discard: %v", err)
	}
	if stagingFiles(t, store) != 0 {
		t.Fatal("staging file survived Discard")
	}
	if _, ok := store.Upload(upload.ID); ok {
		t.Fatal("discarded upload is still registered")
	}
	if err := store.Discard(upload.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second Discard = %v, want ErrNotFound", err)
	}
}

func TestSweepCacheEvictsOldestBlobs(t *testing.T) {
	store := newStore(t, DefaultMaxSize)

	var hashes []string
	for i := 0; i < 3; i++ {
		data := content(t, 1000)
		hash := hashOf(t, data)
		upload, _ := store.CreateUpload(hash, int64(len(data)))
		upload.WriteAt(0, bytes.NewReader(data))
		path, _, err := upload.Commit()
		if err != nil {
			t.Fatalf("commit %d: %v", i, err)
		}
		// Age each blob so eviction order is deterministic.
		when := time.Now().Add(time.Duration(i) * time.Hour)
		if err := os.Chtimes(path, when, when); err != nil {
			t.Fatalf("chtimes: %v", err)
		}
		hashes = append(hashes, hash)
	}

	// Cap below two blobs' worth, so the two oldest must go.
	if err := store.SweepCache(1500); err != nil {
		t.Fatalf("SweepCache: %v", err)
	}

	if store.Has(hashes[0]) || store.Has(hashes[1]) {
		t.Error("oldest blobs were not evicted")
	}
	if !store.Has(hashes[2]) {
		t.Error("newest blob was evicted")
	}
}

func TestOpenSweepsStaleStagingFiles(t *testing.T) {
	root := t.TempDir()
	staging := filepath.Join(root, "staging")
	if err := os.MkdirAll(staging, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	stale := filepath.Join(staging, "abandoned.part")
	fresh := filepath.Join(staging, "inflight.part")
	for _, path := range []string{stale, fresh} {
		if err := os.WriteFile(path, []byte("partial"), 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}
	old := time.Now().Add(-48 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	if _, err := Open(root, DefaultMaxSize); err != nil {
		t.Fatalf("Open: %v", err)
	}

	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("stale staging file was not swept")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Error("recent staging file was swept; a restart would lose a live upload")
	}
}

func TestHashFileMatchesHash(t *testing.T) {
	data := content(t, 777)
	path := filepath.Join(t.TempDir(), "f.bin")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	fromFile, err := HashFile(path)
	if err != nil {
		t.Fatalf("HashFile: %v", err)
	}
	if fromFile != hashOf(t, data) {
		t.Fatal("HashFile and Hash disagree")
	}
	if len(fromFile) != 64 || strings.ToLower(fromFile) != fromFile {
		t.Fatalf("hash %q is not 64 lowercase hex characters", fromFile)
	}
}

func stagingFiles(t *testing.T, store *Store) int {
	t.Helper()
	entries, err := os.ReadDir(store.stagingDir)
	if err != nil {
		t.Fatalf("read staging dir: %v", err)
	}
	return len(entries)
}
