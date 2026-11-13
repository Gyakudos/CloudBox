//go:build linux

package volume

import (
	"bufio"
	"os"
	"strings"
	"syscall"
)

// realFilesystems lists the filesystem types worth showing in a drive picker. Everything
// else in /proc/mounts is a kernel pseudo-filesystem.
var realFilesystems = map[string]bool{
	"ext2": true, "ext3": true, "ext4": true, "xfs": true, "btrfs": true,
	"f2fs": true, "zfs": true, "vfat": true, "exfat": true,
	"ntfs": true, "ntfs3": true, "fuseblk": true, "hfsplus": true,
}

// List returns the real filesystems currently mounted.
func List() ([]Volume, error) {
	f, err := os.Open("/proc/mounts")
	if err != nil {
		return nil, err
	}
	defer f.Close()

	seenDevice := make(map[string]bool, 16)
	vols := make([]Volume, 0, 16)

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 3 {
			continue
		}
		device, mountpoint, fstype := fields[0], unescapeMount(fields[1]), fields[2]
		if !realFilesystems[fstype] {
			continue
		}
		if seenDevice[device] {
			continue
		}
		seenDevice[device] = true

		vol := Volume{
			Name:   mountpoint,
			Path:   mountpoint,
			FSType: fstype,
		}
		if strings.HasPrefix(device, "/dev/") {
			vol.Label = strings.TrimPrefix(device, "/dev/")
		}
		applyStatfs(&vol, mountpoint)
		vols = append(vols, vol)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}

	sortVolumes(vols)
	return vols, nil
}

func applyStatfs(vol *Volume, path string) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return
	}
	bsize := uint64(st.Bsize)
	vol.Total = st.Blocks * bsize
	vol.Free = st.Bavail * bsize
}

// unescapeMount decodes the octal escapes /proc/mounts uses for spaces and backslashes.
func unescapeMount(s string) string {
	if !strings.Contains(s, "\\") {
		return s
	}
	replacer := strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`)
	return replacer.Replace(s)
}
