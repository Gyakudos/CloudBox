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
	"github.com/Gyakudos/CloudBox/agent/internal/devices"
	"github.com/Gyakudos/CloudBox/agent/internal/discovery"
	"github.com/Gyakudos/CloudBox/agent/internal/identity"
	"github.com/Gyakudos/CloudBox/agent/internal/pairing"
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

	srv := api.New(api.Options{
		Identity:   ident,
		Pairing:    pairings,
		Devices:    devices.NewStore(),
		Volumes:    volume.List,
		ServerName: *name,
		Version:    version.Version,
		StartedAt:  time.Now(),
		Logger:     logger,
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

	printBanner(ident, *name, port, expires, *pairTTL, payloadPath, raw)

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

func printBanner(ident *identity.Identity, name string, port int, expires time.Time, ttl time.Duration, payloadPath string, payload []byte) {
	fmt.Printf("\nCloudBox %s\n", version.Version)
	fmt.Printf("  server       %s\n", name)
	fmt.Printf("  listen       https://0.0.0.0:%d\n", port)
	fmt.Printf("  server id    %s\n", ident.ServerID)
	fmt.Printf("  cert pin     %s\n", ident.Pin)
	fmt.Printf("  pairing ttl  %s (expires %s)\n", ttl, expires.Format(time.RFC3339))
	fmt.Printf("  payload      %s\n", payloadPath)
	fmt.Printf("\nPairing payload (render as a QR code for the app):\n%s\n", payload)
	fmt.Printf("\nSanity check:\n  curl -k https://127.0.0.1:%d/healthz\n\n", port)
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
