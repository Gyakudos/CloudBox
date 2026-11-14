//go:build windows

package safepath

import "strings"

// Extended prefixes an absolute path with the Windows extended-length marker when it is long
// enough to hit MAX_PATH, so deeply nested album folders do not fail to open.
func Extended(abs string) string {
	if len(abs) < 248 || strings.HasPrefix(abs, `\\?\`) {
		return abs
	}
	if strings.HasPrefix(abs, `\\`) {
		// UNC: \\server\share -> \\?\UNC\server\share
		return `\\?\UNC\` + strings.TrimPrefix(abs, `\\`)
	}
	return `\\?\` + abs
}
