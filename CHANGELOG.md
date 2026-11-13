# Changelog

All notable changes to CloudBox are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses a
date-stamped version scheme — see [ADR 0001](docs/decisions/0001-versioning.md).

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

[0.00.13.11.26]: https://github.com/Gyakudos/CloudBox/releases/tag/v0.00.13.11.26
