# Changelog

All notable changes to CloudBox are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses a
date-stamped version scheme — see [ADR 0001](docs/decisions/0001-versioning.md).

## [Unreleased]

### Added

### Fixed

## [0.05.20.11.26] — 2026-11-20

The destination is now configured once on the PC instead of on every phone.

### Fixed

- **Android no longer asks for a drive.** Pairing now opens the Send screen directly. The phone
  uses the destination folder the agent reports during pairing, so users are no longer stuck on the
  drive picker before they can send anything.
- **PC Storage setting now reaches paired phones.** Changing the drive or folder in the CloudBox
  Windows app updates every paired device's backup folder, so the setting made on the PC actually
  takes effect on the phone.
- **Same-day pre-releases are installable.** Android `versionCode` now includes the minor counter
  (`YYMMDDNN`), so a second release on the same day can be installed over the first.

## [0.04.20.11.26] — 2026-11-20

Android can now back up whole folders, recreating their subfolders on the PC.

### Added

- **Folder uploads on Android** — a "Upload a whole folder" checkbox on the Send screen opens the
  Android folder picker and queues every file in the tree. Subfolders are recreated on the PC under
  the picked folder's name (`DCIM/Camera/photo.jpg`), using a native Storage Access Framework
  bridge because `dart:io` cannot read `content://` documents under scoped storage.

## [0.03.19.11.26] — 2026-11-19

A single desktop shortcut now starts the agent and the PC app together in one window, with an Agent
tab for status and live logs.

### Added

- **One-click agent + app** — opening the PC app now starts `cloudbox.exe serve` hidden if it is not
  already running, so the **CloudBox** desktop shortcut brings up both in one window. Closing the
  window leaves the agent running for phone backups.
- **Agent tab** — the desktop app shows service status and a bounded live tail of the agent log,
  fetched from a new loopback-only `GET /local/logs` endpoint. Successful status/log polls are no
  longer logged at INFO, so the tail stays useful.

## [0.02.19.11.26] — 2026-11-19

The Windows installer now ships the PC companion app and can place shortcuts for it and the agent
on the desktop.

### Added

- **Desktop shortcuts** — the optional “Create CloudBox shortcuts on the desktop” installer task
  adds **CloudBox** (the Flutter desktop app) and **CloudBox Agent** (the `serve` terminal agent)
  to the desktop. The Start Menu entries remain available.
- **Bundled PC app** — the installer now includes the Flutter Windows build under
  `<install dir>\pc`, with its Flutter runtime DLLs and data folder, so one setup `.exe` installs
  both apps. CI uploads the Windows build from the `pc` job and the installer job reuses it.

## [0.01.19.11.26] — 2026-11-19

The PC app grows Paired Devices and Backups tabs, both apps can check GitHub for updates,
Android can scan the pairing QR, and each paired phone gets its own persisted backup folder.

### Added

- **Multiple paired devices with per-device backups** — the agent persists its device registry to
  `<data dir>\devices.json` (token hashes only) and gives every phone its own backup folder. The
  PC app's new **Paired Devices** tab lists phones, mints a fresh code to add another, revokes
  devices, and sets each device's drive/subfolder; the **Backups** tab shows where each device
  currently writes and whether that drive is available. Uploads are pinned to the authenticated
  device's folder, and the Android drive picker updates that device rather than the global default.
- **QR scanning on Android** — the Pair screen can now scan the code shown by the PC app with the
  camera (`mobile_scanner`), with a duplicate-scan guard and clear parse errors. Pasting still works.
- **Update buttons on both apps** — a header action queries the GitHub Releases list (not
  `/releases/latest`, because every build is a pre-release), compares the date-stamped version, and
  opens the platform's `.apk`/`.exe` or release page in the browser.
- **New app icon** — a blue cloud-and-box glyph generated from `brand/make_icons.py`, applied to
  Android mipmaps and the Windows executable/icon resources.
- **PC desktop app** (`pc/`) — a Flutter Windows companion that finds the running agent from its
  `pairing.json` handoff file and talks to it over pinned HTTPS. The Pairing tab shows the live
  one-time code and QR (with expiry countdown and a "show a new code" button); the Storage tab
  lists the PC's drives with capacity, filesystem and removable/network flags and sets the backup
  destination. The app polls the agent every few seconds, so a phone redeeming the code flips the
  screen from "Waiting for phone" to "Phone paired" without a restart. Built with
  `flutter build windows`.
- **Loopback-only local API** in the agent — `GET /local/status`, `POST /local/pairing/refresh`,
  `GET /local/volumes` and `PUT /local/destination` back the desktop app. These routes require no
  device token (the app is the local user), but a socket-peer check rejects any request not coming
  from loopback with `403 LOCAL_ONLY` — a paired phone cannot mint codes or repoint the backup
  folder. Issuing and refreshing the displayed code now share one `pairingSession`, so the QR,
  `pairing.json`, `pairing.png` and the code the API reports can never disagree.
- **The Windows installer can set up the Flutter SDK.** An optional task (checked by default)
  downloads the pinned Flutter 3.47.8 Windows archive (~1.9 GB), extracts it to
  `%LOCALAPPDATA%\CloudBox\flutter` and adds its `bin` to the user `PATH`, so the Android and PC
  apps can be built on that PC. The agent itself never needs Flutter — the SDK is a developer
  convenience, fetched on demand rather than bundled, and removed again on uninstall.

### Changed

- The local API adds `GET /local/devices`, `DELETE /local/devices/{id}`,
  `PUT /local/devices/{id}/backup` and `GET /local/backups`, all guarded by the existing loopback
  check. A missing device returns `404 DEVICE_NOT_FOUND`.
- `eng/version.ps1` now generates `pc/lib/core/gen/version.dart` alongside the agent and Android
  version files, so the desktop app carries the same five-part version string.
- `cloudbox serve` prints the actual `--addr` it bound in its startup banner instead of always
  claiming `0.0.0.0`.

## [0.01.15.11.26] — 2026-11-15

M1 continues: the drive you pick now decides where your files land, and the phone can send them.
Choose a drive, choose the files, and a resumable, hash-verified transfer writes them onto that
drive. From this release on, tagged builds are published as **pre-releases** while CloudBox is
pre-alpha.

### Added

- **Destination selection** (`internal/destination`) — `PUT /v1/system/destination {volume,
  subfolder}` turns the drive picker into a real choice. The phone sends the *name* of a volume
  the agent itself enumerated, never a path; the agent resolves it against a fresh enumeration,
  roots the default folder at `<drive>\<subfolder>` (default `CloudBox`), registers it under the
  fixed `default` ID, and persists the choice to `<data dir>/destination.json` atomically. An
  unplugged or stale drive returns `ErrUnknownVolume`, and the subfolder passes through the same
  `safepath` rules as an uploaded path. A `--sync-root` given on the command line is the
  operator's decision and still wins on every start.
- **Upload flow in the app** — "Use this drive" records the destination and opens a send screen
  (`lib/ui/send_screen.dart`, `lib/ui/drives_screen.dart`) that picks files with the native
  picker and runs them through a Flutter-free transfer engine (`lib/core/transfer.dart`):
  sequential transfers in 4 MiB chunks with resume, dedupe, cancel and per-file progress.
- **Streaming BLAKE3 in Dart** (`lib/core/hashing.dart`) — the content hash the transfer protocol
  is built on, computed over a stream so a multi-gigabyte video never enters memory. The
  cross-language vectors are locked by tests against the Go agent's `cloudbox hash`.
- `UploadApi` (`lib/core/upload_api.dart`) — the seam the transfer engine talks to, so its
  ordering, resume, dedupe and failure paths are unit-tested against a fake without a live agent.

### Changed

- `POST /v1/uploads` now returns an `upload_id` when the content is already in the dedupe cache,
  so the phone can commit a duplicate as a metadata-only copy instead of re-sending it; `blob`
  gained a deduped upload whose append, progress and commit paths are no-ops.
- **Releases are pre-releases.** The release workflow marks every tag `prerelease: true` and
  `make_latest: false` — CloudBox is pre-alpha, so installs are for dogfooding, not a stable
  download.
- The Android build disables Kotlin incremental compilation (`kotlin.incremental=false`), which
  aborts when the pub cache and the project live on different Windows drives (KT-57286).

## [0.01.13.11.26] — 2026-11-13

M1: the transfer core. A file now travels phone → PC, is verified against its content hash, and
lands as an ordinary file in a folder the user chose — resumably, atomically, and with zero
bytes re-sent when the same content already exists.

### Added

- `internal/safepath` — the one place that trusts nothing. Untrusted, phone-supplied relative
  paths are normalised to NFC, rejected if absolute or containing `..`, and made
  filesystem-safe: Windows reserved names, illegal characters and trailing dots/spaces are
  handled, long components are truncated without splitting a rune or losing the extension, and
  case collisions get a `~1` suffix. Tested against every one of those rules.
- `internal/blob` — resumable, content-addressed staging. Bytes are appended at a fixed offset
  with `fsync` before each ack; the authoritative offset is the staging file's size on disk, so
  a dropped connection or a restart resumes from the same place. Commit re-hashes the received
  bytes with BLAKE3 and only then promotes them into a bounded, age-swept dedupe cache.
- `internal/folder` — finalize-into-folder. Verified content is copied (never hard-linked, so
  Explorer edits cannot poison the cache) through a temp file and an atomic rename, with the
  source mtime preserved so galleries sort by capture date. Includes a folder registry mapping
  the IDs the phone knows to absolute, user-chosen roots.
- Upload API: `POST /v1/uploads`, `PATCH /v1/uploads/{id}` (Content-Range, resumable),
  `GET /v1/uploads/{id}`, `POST /v1/uploads/{id}/commit`, all bearer-authenticated. Offset
  mismatch returns `409` with the real resume offset; a hash mismatch returns `422` and never
  reaches the sync folder.
- `internal/mdns` — `_cloudbox._tcp` advertisement with identity-only TXT records; the pairing
  token is deliberately never advertised.
- QR rendering: `cloudbox serve` writes a scannable `pairing.png` and prints the code to the
  terminal for headless machines.
- `cloudbox hash <file>` — prints the BLAKE3-256 content ID the transfer protocol uses.
- `GET /v1/system/info` now lists configured sync folders.
- **Android app** (`app/`) — the first Flutter client. Pairs by pasting the agent's pairing code
  over pinned TLS: the certificate's SPKI digest must match the code, and the Dart pin is
  cross-checked against the Go agent's value by a committed test vector. After pairing it lists
  the PC's drives with capacity, filesystem and removable/network flags. Pin extraction walks
  the certificate's ASN.1 directly, because Dart's `X509Certificate` exposes only the full DER.
- **Windows installer** (`installer/`, `eng/build-installer.ps1`) — an Inno Setup package for the
  agent alone (the Flutter toolchain is build-time only, never a PC runtime dependency).
  Installs per-user without elevation, adds a Start Menu entry that shows a pairing code, offers
  an optional start-at-sign-in entry that launches the agent hidden, and adds a Windows Firewall
  rule for TCP 8443 when run as administrator.
- **Release automation** — CI builds `cloudbox-<version>.apk` and
  `cloudbox-setup-<version>.exe` and attaches both to the GitHub Release on a `v*` tag push.

### Changed

- `cloudbox serve` gains `--sync-root`, `--sync-name`, `--blob-cache-mb` and `--mdns`.
- The end-to-end smoke test now covers the whole transfer: pair, upload, reject an out-of-order
  append, commit into the sync folder, verify the file on disk, and confirm dedupe.
- Staging files are deleted on a hash mismatch rather than retained, so a hostile client cannot
  fill the disk with content that will never verify.
- The staging store no longer holds a file handle for an upload's lifetime, removing a handle
  leak on abandoned transfers.
- Bumped `golang.org/x/net` and `golang.org/x/sys` so the mDNS dependency links on
  `darwin/arm64` with a modern Go toolchain.

## [0.00.13.11.26] — 2026-11-13

Initial repository scaffold. No functional releases yet; the version scheme starts here.

### Added

- `PLAN.md` — product definition, architecture, folder modes, data model, security model,
  milestone roadmap (M0–M5) and risk register.
- `docs/sync-protocol.md` — wire-level spec for pairing, journal exchange, vector-clock
  reconciliation, conflict copies, resumable content-addressed transfer, and tombstone GC.
- `docs/decisions/0001-versioning.md` — version scheme and artifact mapping.
- Version tooling: `VERSION` as single source of truth, `eng/version.ps1` generator with a
  `-Check` mode for CI, generated Go and Dart version constants, derived Android `versionCode`.
- Go agent skeleton: module definition and a `cloudbox version` command so build identity is
  verifiable end to end.
- **M0 agent core** (`cloudbox serve`):
  - `internal/identity` — stable server ID, self-signed ECDSA TLS certificate, SHA-256 SPKI
    pin, atomic first-run creation. Pin generation and pinned-handshake behaviour are tested,
    including rejection of a wrong pin.
  - `internal/pairing` — single-use, TTL-bounded pairing tokens; compact QR payload matching
    the wire spec.
  - `internal/devices` — bearer-token device registry with revocation; tokens stored as
    SHA-256 digests and never in the clear.
  - `internal/volume` — drive enumeration for the setup drive picker: Windows drive letters
    with label, filesystem, capacity, free space and removable/network flags; Linux
    `/proc/mounts` and macOS `/Volumes` equivalents.
  - `internal/api` — HTTPS surface with `GET /healthz`, `POST /v1/pair`,
    `GET /v1/system/info` and `GET /v1/system/volumes`, bearer auth, structured JSON errors,
    request logging and panic recovery.
  - `internal/discovery` — ordered pairing endpoint candidates (LAN IPv4, mDNS name, loopback).
- Tests across identity, pairing, devices, volume, discovery and the API pair flow.
- CI workflow: version-drift check, `go build`, `go vet`, `go test`.

[0.01.15.11.26]: https://github.com/Gyakudos/CloudBox/releases/tag/v0.01.15.11.26
[0.01.13.11.26]: https://github.com/Gyakudos/CloudBox/releases/tag/v0.01.13.11.26
[0.00.13.11.26]: https://github.com/Gyakudos/CloudBox/releases/tag/v0.00.13.11.26
