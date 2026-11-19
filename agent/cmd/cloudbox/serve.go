package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/Gyakudos/CloudBox/agent/internal/api"
	"github.com/Gyakudos/CloudBox/agent/internal/blob"
	"github.com/Gyakudos/CloudBox/agent/internal/destination"
	"github.com/Gyakudos/CloudBox/agent/internal/devices"
	"github.com/Gyakudos/CloudBox/agent/internal/folder"
	"github.com/Gyakudos/CloudBox/agent/internal/identity"
	"github.com/Gyakudos/CloudBox/agent/internal/mdns"
	"github.com/Gyakudos/CloudBox/agent/internal/pairing"
	"github.com/Gyakudos/CloudBox/agent/internal/safepath"
	"github.com/Gyakudos/CloudBox/agent/internal/version"
	"github.com/Gyakudos/CloudBox/agent/internal/volume"
)

const defaultPort = 8443

func runServe(args []string) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	dir := fs.String("dir", defaultDataDir(), "data directory for the agent's identity and state")
	addr := fs.String("addr", ":"+strconv.Itoa(defaultPort), "HTTPS listen address")
	name := fs.String("name", defaultServerName(), "display name shown in the app")
	pairTTL := fs.Duration("pair-ttl", 5*time.Minute, "lifetime of a pairing token")
	syncRoot := fs.String("sync-root", filepath.Join(defaultDataDir(), "CloudBox"), "folder that receives backups; the phone picks a drive, this is the root on it")
	syncName := fs.String("sync-name", "CloudBox", "display name for the sync folder")
	blobCacheMB := fs.Int("blob-cache-mb", 2048, "blob cache size cap in MiB")
	advertise := fs.Bool("mdns", true, "advertise cloudbox.local over mDNS")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	ident, err := identity.LoadOrCreate(*dir)
	if err != nil {
		logger.Error("load identity", "err", err)
		return 1
	}

	pairings := pairing.NewManager(*pairTTL)

	// The transfer core: a bounded blob cache and the sync folders the phone may write into.
	blobs, err := blob.Open(filepath.Join(*dir, "cache"), int64(*blobCacheMB)<<20)
	if err != nil {
		logger.Error("open blob store", "err", err)
		return 1
	}

	folders := folder.NewRegistry()
	destinations := destination.New(*dir, folders, volume.List, safepath.DefaultPolicy())

	// Precedence: an explicit --sync-root is the operator's decision and always wins; otherwise
	// a drive the user picked from the phone is restored; otherwise (a first run) the default
	// root is adopted.
	var selected folder.Folder
	if !flagSet(fs, "sync-root") {
		restored, ok, restoreErr := destinations.Restore()
		switch {
		case restoreErr != nil:
			logger.Warn("could not restore the saved destination; using the default root", "err", restoreErr)
		case ok:
			selected = restored
			logger.Info("restored destination", "root", restored.Root)
		}
	}
	if selected.ID == "" {
		adopted, err := destinations.Adopt(*syncRoot, *syncName)
		if err != nil {
			logger.Error("open sync folder", "root", *syncRoot, "err", err)
			return 1
		}
		selected = adopted
	}
	logger.Info("sync folder ready", "id", selected.ID, "root", selected.Root)

	port := listenPort(*addr)
	session := newPairingSession(*dir, *name, ident, pairings, port, logger)
	snap, err := session.issue()
	if err != nil {
		logger.Error("issue pairing token", "err", err)
		return 1
	}

	srv := api.New(api.Options{
		Identity:       ident,
		Pairing:        pairings,
		Devices:        devices.NewStore(),
		Blobs:          blobs,
		Folders:        folders,
		Volumes:        volume.List,
		SetDestination: destinations.Set,
		// The desktop app is local: it gets status and the control surface without a device
		// token, over routes guarded to loopback connections (see api/local.go).
		LocalState:   func() api.LocalState { return session.state(destinations) },
		LocalRefresh: func() (api.LocalState, error) { return session.refresh(destinations) },
		ServerName:   *name,
		Version:      version.Version,
		StartedAt:    time.Now(),
		Logger:       logger,
	})

	printBanner(ident, *name, *addr, port, snap.expires, *pairTTL, snap.qrPath, snap.qrWritten, snap.payload)

	// Advertise last, once everything that could fail has. The TXT records carry identity only
	// — never the pairing token, because anyone on the LAN can read them.
	if *advertise {
		advertiser, err := mdns.Advertise(
			mdns.InstanceName(*name),
			port,
			mdns.TXTRecords(ident.ServerID, *name, version.Version),
		)
		if err != nil {
			logger.Warn("mDNS advertisement failed; discovery will rely on IP addresses", "err", err)
		} else {
			defer advertiser.Close()
			logger.Info("advertising over mDNS", "service", mdns.Service, "instance", mdns.InstanceName(*name))
		}
	}

	httpSrv := &http.Server{
		Addr:              *addr,
		Handler:           srv.Handler(),
		TLSConfig:         ident.TLSConfig(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := httpSrv.Shutdown(shutdownCtx); err != nil {
			logger.Warn("graceful shutdown failed", "err", err)
		}
	}()

	logger.Info("listening", "addr", *addr, "version", version.Version)
	if err := httpSrv.ListenAndServeTLS("", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("server stopped", "err", err)
		return 1
	}
	logger.Info("shutdown complete")
	return 0
}

func printBanner(ident *identity.Identity, name, addr string, port int, expires time.Time, ttl time.Duration, qrPath string, qrWritten bool, payload []byte) {
	fmt.Printf("\nCloudBox %s\n", version.Version)
	fmt.Printf("  server       %s\n", name)
	fmt.Printf("  listen       https://%s\n", displayAddr(addr, port))
	fmt.Printf("  server id    %s\n", ident.ServerID)
	fmt.Printf("  cert pin     %s\n", ident.Pin)
	fmt.Printf("  pairing ttl  %s (expires %s)\n", ttl, expires.Format(time.RFC3339))
	fmt.Printf("  payload      %s\n", filepath.Join(ident.Dir, pairingFileName))
	if qrWritten {
		fmt.Printf("  qr image     %s\n", qrPath)
	}
	fmt.Printf("\nScan this with the CloudBox app:\n")
	if text, err := pairing.QRText(string(payload)); err == nil {
		fmt.Print(text)
	} else {
		fmt.Printf("\n%s\n", payload)
	}
	fmt.Printf("\nSanity check:\n  curl -k https://127.0.0.1:%d/healthz\n\n", port)
}

// displayAddr renders the --addr value for the banner. An empty host (":8443") is a wildcard
// bind, shown as 0.0.0.0; a concrete bind such as 127.0.0.1 is shown as given so the printed URL
// is one the user can actually open.
func displayAddr(addr string, port int) string {
	host, _, err := net.SplitHostPort(addr)
	if err != nil || host == "" {
		host = "0.0.0.0"
	}
	return net.JoinHostPort(host, strconv.Itoa(port))
}

// flagSet reports whether the named flag was given on the command line. An explicitly set
// --sync-root is an operator decision and takes precedence over a saved destination.
func flagSet(fs *flag.FlagSet, name string) bool {
	set := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == name {
			set = true
		}
	})
	return set
}

// listenPort extracts the port from a listen address, falling back to the default.
func listenPort(addr string) int {
	_, portText, err := net.SplitHostPort(addr)
	if err != nil {
		return defaultPort
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port == 0 {
		return defaultPort
	}
	return port
}

func defaultDataDir() string {
	if dir, err := os.UserConfigDir(); err == nil {
		return filepath.Join(dir, "CloudBox")
	}
	return ".cloudbox"
}

func defaultServerName() string {
	if name, err := os.Hostname(); err == nil && name != "" {
		return name
	}
	return "CloudBox PC"
}
