//go:build !windows && !linux && !darwin

package volume

import "errors"

// List is unimplemented on this platform.
func List() ([]Volume, error) {
	return nil, errors.New("volume: unsupported platform")
}
