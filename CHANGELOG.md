# Changelog

All notable changes to CloudBox are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses a
date-stamped version scheme — see [ADR 0001](docs/decisions/0001-versioning.md).

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

[0.01.13.11.26]: https://github.com/Gyakudos/CloudBox/releases/tag/v0.01.13.11.26
[0.00.13.11.26]: https://github.com/Gyakudos/CloudBox/releases/tag/v0.00.13.11.26
