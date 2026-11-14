//go:build !windows

package safepath

// Extended is a no-op outside Windows, where long paths are not a special case.
func Extended(abs string) string { return abs }
