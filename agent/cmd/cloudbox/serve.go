package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
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
	"github.com/Gyakudos/CloudBox/agent/internal/logbuf"
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

	// Keep a bounded copy of the log lines so the PC app can show them in its Agent tab without
	// opening a second console window. stderr still gets everything, for the terminal shortcut.
	logs := logbuf.New(logbuf.DefaultLimit)
	logger := slog.New(slog.NewTextHandler(
		io.MultiWriter(os.Stderr, logs),
		&slog.HandlerOptions{Level: slog.LevelInfo},
	))
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

	// Paired phones and their per-device backup folders survive restarts. A corrupt registry is
	// fatal: silently starting empty would leave phones paired on one side only.
	deviceStore, err := devices.NewStoreAt(*dir)
	if err != nil {
		logger.Error("load devices", "err", err)
		return 1
	}

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

	// Re-adopt every persisted device backup root. A drive that has been unplugged (or a folder
	// the user removed) is logged and skipped; one missing phone must not stop the agent.
	for _, dev := range deviceStore.List() {
		cfg := dev.Backup
		if cfg.FolderID == "" || cfg.Root == "" {
			continue
		}
		if info, err := os.Stat(cfg.Root); err != nil || !info.IsDir() {
			logger.Warn("device backup folder is unavailable; skipping",
				"device_id", dev.ID, "root", cfg.Root, "err", err)
			continue
		}
		if _, err := registerBackupFolder(folders, cfg); err != nil {
			logger.Warn("could not register device backup folder; skipping",
				"device_id", dev.ID, "root", cfg.Root, "err", err)
		}
	}

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
		Devices:        deviceStore,
		Blobs:          blobs,
		Folders:        folders,
		Volumes:        volume.List,
		// The PC app's Storage screen is the single source of truth for where backups go. When it
		// changes, bring every paired phone's backup folder along: the phone no longer picks a
		// drive, so a setting made on the PC must actually take effect on paired devices.
		SetDestination: func(volume, subfolder string) (folder.Folder, error) {
			selected, err := destinations.Set(volume, subfolder)
			if err != nil {
				return folder.Folder{}, err
			}
			followDestination(deviceStore, folders, logger, volume, subfolder)
			return selected, nil
		},
		// The desktop app is local: it gets status and the control surface without a device
		// token, over routes guarded to loopback connections (see api/local.go).
		LocalState:   func() api.LocalState { return session.state(destinations) },
		LocalRefresh: func() (api.LocalState, error) { return session.refresh(destinations) },
		LocalLogs:    logs.Lines,
		ListDevices:  func() []devices.Device { return deviceStore.List() },
		RevokeDevice: func(id string) error {
			_, err := deviceStore.RevokeWithError(id)
			return err
		},
		SetDeviceBackup: func(id, vol, sub string, enabled bool) (devices.Device, folder.Folder, error) {
			device, err := deviceStore.UpdateBackup(id, vol, sub, enabled)
			if err != nil {
				return devices.Device{}, folder.Folder{}, err
			}
			selected, err := registerBackupFolder(folders, device.Backup)
			if err != nil {
				return device, folder.Folder{}, err
			}
			return device, selected, nil
		},
		ListBackups: func() []api.BackupInfo { return deviceBackups(deviceStore) },
		// A new phone inherits the current global destination but gets its own folder id and
		// root config, so changing the global choice later cannot silently redirect its backup.
		OnPaired: func(device devices.Device) error {
			choice, ok := destinations.CurrentChoice()
			if !ok {
				return nil
			}
			cfg := devices.BackupConfig{
				FolderID:  devices.BackupFolderID(device.ID),
				Volume:    choice.Volume,
				Subfolder: choice.Subfolder,
				Root:      choice.Root,
				Enabled:   true,
			}
			if _, err := registerBackupFolder(folders, cfg); err != nil {
				return err
			}
			_, err := deviceStore.SetBackupConfig(device.ID, cfg)
			return err
		},
		ServerName: *name,
		Version:    version.Version,
		StartedAt:  time.Now(),
		Logger:     logger,
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

// registerBackupFolder adopts a resolved per-device backup root into the folder registry, so an
// upload addressed to that folder id lands in the phone's own tree.
func registerBackupFolder(folders *folder.Registry, cfg devices.BackupConfig) (folder.Folder, error) {
	finalizer, err := folder.New(cfg.Root, safepath.DefaultPolicy())
	if err != nil {
		return folder.Folder{}, err
	}
	name := cfg.Subfolder
	if name == "" {
		name = destination.DefaultSubfolder
	}
	selected := folder.Folder{ID: cfg.FolderID, Name: name, Root: finalizer.Root}
	if err := folders.Register(cfg.FolderID, name, finalizer); err != nil {
		return folder.Folder{}, err
	}
	return selected, nil
}

// followDestination re-points every paired device's backup at the destination just chosen in the
// PC app. Failures are logged and skipped: one removed or unplugged device must not fail the
// global setting for everyone else, though it may keep uploading to its old folder until it is
// reachable again.
func followDestination(store *devices.Store, folders *folder.Registry, logger *slog.Logger, volume, subfolder string) {
	for _, device := range store.List() {
		updated, err := store.UpdateBackup(device.ID, volume, subfolder, true)
		if err != nil {
			logger.Warn("could not update device backup after destination change",
				"device_id", device.ID, "err", err)
			continue
		}
		if _, err := registerBackupFolder(folders, updated.Backup); err != nil {
			logger.Warn("could not register device backup folder after destination change",
				"device_id", device.ID, "root", updated.Backup.Root, "err", err)
		}
	}
}

// deviceBackups builds the PC app's paired-device rows, including whether each backup root is
// still reachable. Volume names are matched against a fresh enumeration, not trusted from disk.
func deviceBackups(store *devices.Store) []api.BackupInfo {
	devicesList := store.List()
	out := make([]api.BackupInfo, 0, len(devicesList))
	vols, volErr := volume.List()
	for _, device := range devicesList {
		cfg := device.Backup
		info := api.BackupInfo{
			DeviceID:   device.ID,
			DeviceName: device.Name,
			FolderID:   cfg.FolderID,
			Volume:     cfg.Volume,
			Subfolder:  cfg.Subfolder,
			Root:       cfg.Root,
			Enabled:    cfg.Enabled,
			LastSeenAt: device.LastSeenAt,
		}
		if stat, err := os.Stat(cfg.Root); cfg.Root != "" && err == nil && stat.IsDir() {
			info.Available = true
			if cfg.Volume != "" && volErr == nil {
				_, found := volume.Find(vols, cfg.Volume)
				info.Available = found
			}
		}
		out = append(out, info)
	}
	return out
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
