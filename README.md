# CloudBox

**Your PC is the cloud.** CloudBox backs up the photos, videos and music you choose to the
drive you choose on your own machine — and keeps folders in sync between your phone and your
PC. No subscription, no third-party storage, nothing leaves home.

| | |
|---|---|
| **Version** | `0.00.13.11.26` — scheme in [ADR 0001](docs/decisions/0001-versioning.md) |
| **Status** | Pre-alpha · M0 agent core working (pairing, TLS pinning, drive enumeration) |
| **Android** | Flutter (Dart) + Kotlin platform channels |
| **PC agent** | Go, single static binary (`CGO_ENABLED=0`) |
| **Reachability** | LAN, plus optional tailnet via embedded `tsnet` |

---

## What it does

Every folder CloudBox manages is in exactly one of three modes:

| Mode | Direction | Deletes propagate | Typical use |
|------|-----------|-------------------|-------------|
| `backup` | phone → PC | never | Camera, screenshots, WhatsApp media |
| `sync` | both ways | yes, always via trash | Documents, notes |
| `down` | PC → phone | PC side only | Music, offline video |

`backup` is conflict-free *by construction* — one writer, so no vector clock can ever be
concurrent. That is why the most common use case ships before the sync engine exists.

**Design principles**

- The user picks the **drive**, not just a folder: the agent reports every volume with label,
  filesystem and free space.
- Files land as **real files** in real folders. Content-addressing is staging-only, so your
  drive stays browsable in Explorer.
- **Never lose data.** Deletes go through `.cloudbox-trash/`; conflicting edits become
  `… (conflicted copy from DESKTOP 2026-11-13).ext`.
- **No inbound internet exposure.** Overlay network only. No port forwarding, no relay we run.

## Documentation

| Document | What's in it |
|----------|--------------|
| [`PLAN.md`](PLAN.md) | Product scope, architecture, data model, security, roadmap, risks |
| [`docs/sync-protocol.md`](docs/sync-protocol.md) | Wire contract: pairing, journal, vector clocks, conflicts, resumable transfer |
| [`docs/decisions/`](docs/decisions/) | Short architecture decision records |
| [`CHANGELOG.md`](CHANGELOG.md) | Release history |

## Repository layout

```
CloudBox/
├─ VERSION                     single source of truth for the release version
├─ eng/                        build & version tooling
├─ docs/
│  ├─ sync-protocol.md
│  └─ decisions/
├─ agent/                      Go PC agent
│  ├─ cmd/cloudbox/
│  └─ internal/
└─ app/                        Flutter Android app
   └─ lib/core/gen/            generated version constants (do not edit)
```

## Prerequisites

| Toolchain | Version | Needed for |
|-----------|---------|------------|
| Go | ≥ 1.26 | `agent/` |
| Flutter | ≥ 3.24 (Dart ≥ 3.5) | `app/` |
| Android SDK | API 35+ | `app/` — Android builds |
| JDK | 17+ | Android Gradle builds (JDK 21 present here) |

## Getting started

**PC agent** — M0 works: it serves a pinned-TLS API, pairs a device, and lists real drives.

```sh
cd agent
go run ./cmd/cloudbox version
go run ./cmd/cloudbox serve            # prints the pairing payload and its cert pin
go build -o bin/cloudbox.exe ./cmd/cloudbox
```

`cloudbox serve` writes the pairing payload to `<data dir>/pairing.json` (default data dir is
`%APPDATA%\CloudBox`). Flags: `--addr` (default `:8443`), `--dir`, `--name`, `--pair-ttl`.

Run the end-to-end smoke test (boots the real server, pairs, lists volumes, checks replay
rejection):

```powershell
pwsh eng/smoke.ps1
```

**Android app** — not scaffolded yet. Generate the platform shells first, then re-apply the
version overrides recorded in `app/README.md`:

```sh
cd app
flutter create --org dev.cloudbox --project-name cloudbox --platforms android .
```

## Versioning

`VERSION` holds `MAJOR.MINOR.DD.MM.YY`, e.g. `0.00.13.11.26` = minor 00, released
**2026-11-13**. Generated artifacts must never be hand-edited:

```powershell
pwsh eng/version.ps1          # regenerate after changing VERSION
pwsh eng/version.ps1 -Check   # verify generated files are current (used in CI)
```

Git tags carry a `v` prefix: `v0.00.13.11.26`. See
[ADR 0001](docs/decisions/0001-versioning.md) for the mapping to Android `versionCode` and the
Dart `pubspec.yaml` constraint.

## License

Not chosen yet — see `PLAN.md` §14, open question 6.
