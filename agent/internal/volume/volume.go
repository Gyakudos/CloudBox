// Package volume enumerates the drives the user can choose as a backup destination.
//
// This is the backend for the drive picker in the app's setup flow: every entry carries a
// label, filesystem, capacity and a removability flag, so the phone can render "E: Elements
// (USB, 1.8 TB free)" and warn about FAT32's 4 GB file limit before a long video is attempted.
package volume

import "sort"

// Volume describes one mountable filesystem.
type Volume struct {
	// Name is the drive letter ("C:") on Windows or the mount point ("/", "/Volumes/Data")
	// elsewhere. It is the short label the phone shows on a card.
	Name string `json:"name"`
	// Label is the filesystem volume label, which may be empty.
	Label string `json:"label"`
	// Path is the absolute path to pass to the OS; normally identical to Name on Windows
	// with a trailing separator.
	Path string `json:"path"`
	// FSType is the filesystem name ("NTFS", "exFAT", "ext4"). Empty when unknown.
	FSType string `json:"fs_type"`
	// Total is the capacity in bytes.
	Total uint64 `json:"total_bytes"`
	// Free is the space available to the current user in bytes.
	Free uint64 `json:"free_bytes"`
	// Removable marks USB sticks and SD cards, which may vanish mid-transfer.
	Removable bool `json:"removable"`
	// Network marks mapped or network-mounted filesystems.
	Network bool `json:"network"`
}

// sortVolumes gives List a stable, human-sensible order: fixed disks first, then removable,
// then network, each group ordered by name.
func sortVolumes(vols []Volume) {
	rank := func(v Volume) int {
		switch {
		case v.Network:
			return 2
		case v.Removable:
			return 1
		default:
			return 0
		}
	}
	sort.SliceStable(vols, func(i, j int) bool {
		if rank(vols[i]) != rank(vols[j]) {
			return rank(vols[i]) < rank(vols[j])
		}
		return vols[i].Name < vols[j].Name
	})
}
