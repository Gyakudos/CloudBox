//go:build windows

package volume

import (
	"strings"

	"golang.org/x/sys/windows"
)

const maxVolumeNameLen = 261 // MAX_PATH

// List returns every mounted drive letter that can carry a filesystem.
func List() ([]Volume, error) {
	mask, err := windows.GetLogicalDrives()
	if err != nil {
		return nil, err
	}

	vols := make([]Volume, 0, 8)
	for i := 0; i < 26; i++ {
		if mask&(1<<uint(i)) == 0 {
			continue
		}
		root := string(rune('A'+i)) + ":\\"
		vol, ok := describe(root)
		if !ok {
			// Empty optical drives and disconnected mapped drives fail to describe; skip.
			continue
		}
		vols = append(vols, vol)
	}

	sortVolumes(vols)
	return vols, nil
}

func describe(root string) (Volume, bool) {
	rootPtr, err := windows.UTF16PtrFromString(root)
	if err != nil {
		return Volume{}, false
	}

	var (
		volumeName     [maxVolumeNameLen]uint16
		filesystemName [maxVolumeNameLen]uint16
		serial         uint32
		maxComponent   uint32
		flags          uint32
	)

	err = windows.GetVolumeInformation(
		rootPtr,
		&volumeName[0], maxVolumeNameLen,
		&serial, &maxComponent, &flags,
		&filesystemName[0], maxVolumeNameLen,
	)
	if err != nil {
		return Volume{}, false
	}

	var freeToCaller, totalBytes, totalFree uint64
	if err := windows.GetDiskFreeSpaceEx(rootPtr, &freeToCaller, &totalBytes, &totalFree); err != nil {
		return Volume{}, false
	}

	driveType := windows.GetDriveType(rootPtr)

	return Volume{
		Name:      strings.TrimSuffix(root, "\\"),
		Label:     windows.UTF16ToString(volumeName[:]),
		Path:      root,
		FSType:    windows.UTF16ToString(filesystemName[:]),
		Total:     totalBytes,
		Free:      freeToCaller,
		Removable: driveType == windows.DRIVE_REMOVABLE,
		Network:   driveType == windows.DRIVE_REMOTE,
	}, true
}
