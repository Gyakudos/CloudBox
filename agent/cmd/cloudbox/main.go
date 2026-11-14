// Command cloudbox is the CloudBox PC agent: it turns a PC into a private cloud for the
// CloudBox Android app.
package main

import (
	"fmt"
	"os"

	"github.com/Gyakudos/CloudBox/agent/internal/blob"
	"github.com/Gyakudos/CloudBox/agent/internal/version"
)

const usage = `cloudbox - turn your PC into your private cloud

Usage:
  cloudbox serve            Start the agent (HTTPS API and pairing)
  cloudbox hash <file>      Print the BLAKE3-256 hash of a file
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
	case "hash":
		return runHash(args[1:])
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

// runHash prints the content hash the transfer protocol uses. It exists so a file's identity
// can be reproduced by hand when debugging a transfer, and so scripts can drive the API.
func runHash(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: cloudbox hash <file>")
		return 2
	}
	sum, err := blob.HashFile(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "cloudbox: %v\n", err)
		return 1
	}
	fmt.Println(sum)
	return 0
}
