// Command cloudbox is the CloudBox PC agent: it turns a PC into a private cloud for the
// CloudBox Android app.
package main

import (
	"fmt"
	"os"

	"github.com/Gyakudos/CloudBox/agent/internal/version"
)

const usage = `cloudbox - turn your PC into your private cloud

Usage:
  cloudbox serve            Start the agent (HTTPS API and pairing)
  cloudbox version          Print version and build information
  cloudbox help             Show this message

Run "cloudbox serve --help" for serve flags.
`

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, usage)
		return 2
	}

	switch args[0] {
	case "serve":
		return runServe(args[1:])
	case "version", "--version", "-v":
		fmt.Println(version.String())
		return 0
	case "help", "--help", "-h":
		fmt.Print(usage)
		return 0
	default:
		fmt.Fprintf(os.Stderr, "cloudbox: unknown command %q\n\n", args[0])
		fmt.Fprint(os.Stderr, usage)
		return 2
	}
}
