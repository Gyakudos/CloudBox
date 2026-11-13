// Package version exposes CloudBox build metadata.
//
// The release version is MAJOR.MINOR.DD.MM.YY and is derived from the repository's VERSION
// file by eng/version.ps1. See docs/decisions/0001-versioning.md.
package version

import (
	"fmt"
	"runtime"
)

// Version is the release version. generated.go supplies the value committed to the
// repository; release builds may override it at link time:
//
//	go build -ldflags "-X github.com/Gyakudos/CloudBox/agent/internal/version.Version=0.01.12.11.26"
var Version = generatedVersion

// Commit is the git revision the binary was built from, injected at link time.
var Commit = "unknown"

// BuildDate is the build timestamp, injected at link time.
var BuildDate = "unknown"

// String renders a single-line, human-readable build identity.
func String() string {
	return fmt.Sprintf("cloudbox %s (commit %s, built %s, %s/%s)",
		Version, Commit, BuildDate, runtime.GOOS, runtime.GOARCH)
}
