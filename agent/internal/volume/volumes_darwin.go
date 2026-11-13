//go:build darwin

package volume

import (
	"os"
	"path/filepath"
	"syscall"
)

// List returns the root filesystem plus every mounted volume under /Volumes.
func List() ([]Volume, error) {
	candidates := []string{"/"}

	if entries, err := os.ReadDir("/Volumes"); err == nil {
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			// Skip the synthetic links macOS creates for the boot volume.
			if entry.Name() == "Macintosh HD" {
				continue
			}
			candidates = append(candidates, filepath.Join("/Volumes", entry.Name()))
		}
	}

	vols := make([]Volume, 0, len(candidates))
	for _, mount := range candidates {
		vol := Volume{
			Name: mount,
			Path: mount,
		}
		if mount == "/" {
			vol.Label = "Macintosh HD"
		} else {
			vol.Label = filepath.Base(mount)
		}

		var st syscall.Statfs_t
		if err := syscall.Statfs(mount, &st); err != nil {
			continue
		}
		vol.Total = st.Blocks * uint64(st.Bsize)
		vol.Free = st.Bavail * uint64(st.Bsize)
		v, err := os.Stat(mount)
		if err == nil && v.Mode()&os.ModeSymlink != 0 {
			continue
		}
		vols = append(vols, vol)
	}

	sortVolumes(vols)
	return vols, nil
}
