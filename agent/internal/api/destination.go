package api

import (
	"errors"
	"net/http"
	"strings"

	"github.com/Gyakudos/CloudBox/agent/internal/destination"
	"github.com/Gyakudos/CloudBox/agent/internal/folder"
)

// The destination endpoint turns the drive picker into a real choice. The phone sends the name
// of a volume the agent itself enumerated — never a path — and the agent roots the default sync
// folder there. See package destination for why the name, and not a path, is the right input.

type setDestinationRequest struct {
	Volume    string `json:"volume"`
	Subfolder string `json:"subfolder"`
}

type setDestinationResponse struct {
	Folder folder.Folder `json:"folder"`
}

func (s *Server) handleSetDestination(w http.ResponseWriter, r *http.Request) {
	var req setDestinationRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "malformed JSON body")
		return
	}
	if strings.TrimSpace(req.Volume) == "" {
		writeError(w, http.StatusBadRequest, "BAD_REQUEST", "volume is required")
		return
	}

	selected, err := s.opts.SetDestination(req.Volume, req.Subfolder)
	switch {
	case errors.Is(err, destination.ErrUnknownVolume):
		writeError(w, http.StatusNotFound, "VOLUME_NOT_FOUND", "the PC no longer has that drive")
		return
	case errors.Is(err, destination.ErrInvalidSubfolder):
		writeError(w, http.StatusBadRequest, "INVALID_SUBFOLDER", "the folder name is not usable on that drive")
		return
	case err != nil:
		s.opts.Logger.Error("set destination", "err", err, "volume", req.Volume)
		writeError(w, http.StatusInternalServerError, "INTERNAL", "could not change the destination")
		return
	}

	s.opts.Logger.Info("destination changed", "folder_id", selected.ID, "root", selected.Root)
	writeJSON(w, http.StatusOK, setDestinationResponse{Folder: selected})
}
