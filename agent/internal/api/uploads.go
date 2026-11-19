package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/blob"
	"github.com/Gyakudos/CloudBox/agent/internal/folder"
)

// Upload endpoints implement §7.1 of docs/sync-protocol.md: create, append by offset, inspect,
// commit. The bytes never touch the sync folder until they have been hashed and verified, so a
// truncated or corrupted transfer can never appear as a real photo.

type createUploadRequest struct {
	Hash     string `json:"hash"`
	Size     int64  `json:"size"`
	FolderID string `json:"folder_id"`
}

type createUploadResponse struct {
	UploadID string `json:"upload_id"`
	Offset   int64  `json:"offset"`
	// Complete is true when the server already holds this content: the client may skip the
	// PATCH phase entirely. This is the dedupe path that makes a second copy of a photo free.
	Complete bool `json:"complete"`
}

func (s *Server) handleCreateUpload(w http.ResponseWriter, r *http.Request) {
	var req createUploadRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "malformed JSON body")
		return
	}

	// A device with a configured backup is pinned to its own folder: the phone cannot name a
	// different folder_id and write into another phone's tree (or the global default).
	folderID := req.FolderID
	if device, ok := deviceFrom(r.Context()); ok && device.Backup.Enabled && device.Backup.FolderID != "" {
		folderID = device.Backup.FolderID
	}
	if _, ok := s.opts.Folders.Get(folderID); !ok {
		writeError(w, http.StatusNotFound, "FOLDER_NOT_FOUND", "no such folder_id")
		return
	}

	// Already cached: the bytes are here, so the client skips the PATCH phase. It still gets an
	// upload ID, because commit is what places the content at the requested path — and for a
	// deduped upload that commit is a metadata-only copy out of the cache.
	if s.opts.Blobs.Has(req.Hash) {
		if upload, err := s.opts.Blobs.CreateDedupedUpload(req.Hash, req.Size); err == nil {
			upload.FolderID = folderID
			writeJSON(w, http.StatusCreated, createUploadResponse{
				UploadID: upload.ID,
				Offset:   upload.Size,
				Complete: true,
			})
			return
		}
		// The cache changed under us (a concurrent sweep). Fall through to a normal upload.
	}

	upload, err := s.opts.Blobs.CreateUpload(req.Hash, req.Size)
	switch {
	case errors.Is(err, blob.ErrInvalidHash):
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "hash must be 64 hex characters")
		return
	case errors.Is(err, blob.ErrTooLarge):
		writeError(w, http.StatusRequestEntityTooLarge, "UPLOAD_TOO_LARGE", "declared size exceeds the server limit")
		return
	case err != nil:
		s.opts.Logger.Error("create upload", "err", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL", "could not create upload")
		return
	}

	upload.FolderID = folderID

	writeJSON(w, http.StatusCreated, createUploadResponse{UploadID: upload.ID, Offset: 0})
}

type uploadStatusResponse struct {
	UploadID string `json:"upload_id"`
	Offset   int64  `json:"offset"`
	Size     int64  `json:"size"`
	State    string `json:"state"`
}

func (s *Server) handleUploadStatus(w http.ResponseWriter, r *http.Request) {
	upload, ok := s.opts.Blobs.Upload(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "UPLOAD_NOT_FOUND", "unknown or finished upload")
		return
	}
	offset, size := upload.Progress()
	writeJSON(w, http.StatusOK, uploadStatusResponse{
		UploadID: upload.ID,
		Offset:   offset,
		Size:     size,
		State:    "uploading",
	})
}

type appendResponse struct {
	Offset int64 `json:"offset"`
}

func (s *Server) handleAppendUpload(w http.ResponseWriter, r *http.Request) {
	upload, ok := s.opts.Blobs.Upload(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "UPLOAD_NOT_FOUND", "unknown or finished upload")
		return
	}

	// Never leak the staging file handle, whatever happens below. Discard is idempotent and
	// returns ErrNotFound once the upload has been committed.
	start, _, err := parseContentRange(r.Header.Get("Content-Range"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", err.Error())
		return
	}

	offset, err := upload.WriteAt(start, r.Body)
	switch {
	case errors.Is(err, blob.ErrOffsetMismatch):
		// Tell the client exactly where to resume rather than making it re-send good bytes.
		writeJSON(w, http.StatusConflict, struct {
			Error  errorBody `json:"error"`
			Offset int64     `json:"offset"`
		}{
			Error:  errorBody{Code: "OFFSET_MISMATCH", Message: "body does not start at the expected offset"},
			Offset: offset,
		})
		return
	case errors.Is(err, blob.ErrSizeExceeded):
		writeError(w, http.StatusRequestEntityTooLarge, "UPLOAD_TOO_LARGE", "body exceeds the declared size")
		return
	case err != nil:
		s.opts.Logger.Error("append upload", "err", err, "upload_id", upload.ID)
		writeError(w, http.StatusInternalServerError, "INTERNAL", "could not write upload")
		return
	}

	writeJSON(w, http.StatusOK, appendResponse{Offset: offset})
}

type commitUploadRequest struct {
	Hash    string `json:"hash"`
	Path    string `json:"path"`
	MtimeMS int64  `json:"mtime_ms"`
	Clock   string `json:"clock"`
}

type commitUploadResponse struct {
	Committed bool   `json:"committed"`
	Path      string `json:"path"`
	Deduped   bool   `json:"deduped"`
	Replaced  bool   `json:"replaced"`
}

func (s *Server) handleCommitUpload(w http.ResponseWriter, r *http.Request) {
	upload, ok := s.opts.Blobs.Upload(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "UPLOAD_NOT_FOUND", "unknown or finished upload")
		return
	}
	var req commitUploadRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "malformed JSON body")
		return
	}
	if !strings.EqualFold(req.Hash, upload.Hash) {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "hash does not match the upload")
		return
	}
	if strings.TrimSpace(req.Path) == "" {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "path is required")
		return
	}

	finalizer, ok := s.folderForUpload(upload)
	if !ok {
		writeError(w, http.StatusNotFound, "FOLDER_NOT_FOUND", "the upload's folder is no longer configured")
		return
	}

	blobPath, deduped, err := upload.Commit()
	if err != nil {
		if errors.Is(err, blob.ErrHashMismatch) {
			s.opts.Logger.Warn("upload hash mismatch", "upload_id", upload.ID, "err", err)
			writeError(w, http.StatusUnprocessableEntity, "HASH_MISMATCH",
				"received bytes do not match the declared hash")
			return
		}
		s.opts.Logger.Error("commit upload", "err", err, "upload_id", upload.ID)
		writeError(w, http.StatusInternalServerError, "INTERNAL", "could not commit upload")
		return
	}

	mtime := time.Time{}
	if req.MtimeMS > 0 {
		mtime = time.UnixMilli(req.MtimeMS)
	}

	result, err := finalizer.Place(req.Path, blobPath, upload.Hash, mtime)
	if err != nil {
		s.opts.Logger.Error("finalize upload", "err", err, "upload_id", upload.ID, "path", req.Path)
		writeError(w, http.StatusBadRequest, "INVALID_PATH", "path could not be written: "+err.Error())
		return
	}

	s.opts.Logger.Info("upload finalized",
		"upload_id", upload.ID, "path", result.Path, "deduped", deduped, "replaced", result.Replaced)

	writeJSON(w, http.StatusOK, commitUploadResponse{
		Committed: true,
		Path:      result.Path,
		Deduped:   deduped,
		Replaced:  result.Replaced,
	})
}

// folderForUpload resolves the sync folder an upload was created for.
func (s *Server) folderForUpload(upload *blob.Upload) (*folder.Finalizer, bool) {
	return s.opts.Folders.Get(upload.FolderID)
}

// parseContentRange parses "bytes N-M/size" and returns the start offset and the total size.
func parseContentRange(header string) (start, total int64, err error) {
	header = strings.TrimSpace(header)
	if header == "" {
		return 0, 0, errors.New("Content-Range header is required")
	}
	rest, ok := strings.CutPrefix(header, "bytes ")
	if !ok {
		return 0, 0, errors.New("Content-Range must use the bytes unit")
	}

	rangePart, sizePart, ok := strings.Cut(rest, "/")
	if !ok {
		return 0, 0, errors.New("Content-Range is missing the total size")
	}
	startPart, _, ok := strings.Cut(rangePart, "-")
	if !ok {
		return 0, 0, errors.New("Content-Range is missing the range end")
	}

	start, err = strconv.ParseInt(strings.TrimSpace(startPart), 10, 64)
	if err != nil || start < 0 {
		return 0, 0, errors.New("Content-Range start is not a valid offset")
	}
	total, err = strconv.ParseInt(strings.TrimSpace(sizePart), 10, 64)
	if err != nil || total <= 0 {
		return 0, 0, errors.New("Content-Range total size is not valid")
	}
	return start, total, nil
}
