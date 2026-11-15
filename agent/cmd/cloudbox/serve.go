package main

import (
	"context"
	"encoding/json"
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
	"github.com/Gyakudos/CloudBox/agent/internal/discovery"
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

	srv := api.New(api.Options{
		Identity:       ident,
		Pairing:        pairings,
		Devices:        devices.NewStore(),
		Blobs:          blobs,
		Folders:        folders,
		Volumes:        volume.List,
		SetDestination: destinations.Set,
		ServerName:     *name,
		Version:        version.Version,
		StartedAt:      time.Now(),
		Logger:         logger,
	})

	token, expires, err := pairings.Issue()
	if err != nil {
		logger.Error("issue pairing token", "err", err)
		return 1
	}

	port := listenPort(*addr)
	payload := pairing.Payload{
		V:   1,
		SID: ident.ServerID,
		EPs: discovery.LocalEndpoints(port),
		Pin: ident.Pin,
		Tok: token,
	}
	raw, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		logger.Error("encode pairing payload", "err", err)
		return 1
	}

	payloadPath := filepath.Join(*dir, "pairing.json")
	if err := os.WriteFile(payloadPath, append(raw, '\n'), 0o600); err != nil {
		logger.Warn("could not write pairing payload", "path", payloadPath, "err", err)
	}

	// The QR image is what the user actually scans. The payload itself is public (it is shown
	// on screen), but the file is still written 0600: it carries a live pairing token.
	qrPath := filepath.Join(*dir, "pairing.png")
	qrWritten := false
	if png, err := pairing.QRPNG(string(raw)); err != nil {
		logger.Warn("could not render QR image", "err", err)
	} else if err := os.WriteFile(qrPath, png, 0o600); err != nil {
		logger.Warn("could not write QR image", "path", qrPath, "err", err)
	} else {
		qrWritten = true
	}

	printBanner(ident, *name, port, expires, *pairTTL, payloadPath, qrPath, qrWritten, raw)

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

func printBanner(ident *identity.Identity, name string, port int, expires time.Time, ttl time.Duration, payloadPath, qrPath string, qrWritten bool, payload []byte) {
	fmt.Printf("\nCloudBox %s\n", version.Version)
	fmt.Printf("  server       %s\n", name)
	fmt.Printf("  listen       https://0.0.0.0:%d\n", port)
	fmt.Printf("  server id    %s\n", ident.ServerID)
	fmt.Printf("  cert pin     %s\n", ident.Pin)
	fmt.Printf("  pairing ttl  %s (expires %s)\n", ttl, expires.Format(time.RFC3339))
	fmt.Printf("  payload      %s\n", payloadPath)
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
