# CloudBox

**Your PC is the cloud.** CloudBox backs up the photos, videos and music you choose to the
drive you choose on your own machine — and keeps folders in sync between your phone and your
PC. No subscription, no third-party storage, nothing leaves home.

| | |
|---|---|
| **Version** | `0.01.15.11.26` - scheme in [ADR 0001](docs/decisions/0001-versioning.md) |
| **Status** | Pre-release (pre-alpha) · end-to-end upload working (pick files → resumable verified transfer → atomic finalize) |
| **Android** | Flutter (Dart) + Kotlin platform channels |
| **PC agent** | Go, single static binary (`CGO_ENABLED=0`) |
| **Reachability** | LAN, plus optional tailnet via embedded `tsnet` |

---

## Downloads

Tagged releases carry ready-to-install artifacts, built by CI whenever a `v*` tag is pushed.
CloudBox is pre-alpha, so every release is published as a **pre-release** — installable and
dogfoodable, but not yet a stable download:

| Asset | What it is |
|-------|------------|
| `cloudbox-setup-<version>.exe` | Windows installer for the agent + PC app — per-user, optional desktop shortcuts, start-at-sign-in, and Flutter SDK for building the app |
| `cloudbox-<version>.apk` | Android app (universal APK; debug-signed until release signing is configured) |

See [Releases](https://github.com/Gyakudos/CloudBox/releases). To build them yourself, see
[Getting started](#getting-started).

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
│  ├─ version.ps1              regenerate generated version constants (-Check in CI)
│  ├─ build-apk.ps1            flutter build apk → dist/cloudbox-<version>.apk
│  ├─ build-installer.ps1      cross-compile agent + Inno Setup → dist/cloudbox-setup-<version>.exe
│  └─ smoke.ps1                end-to-end agent smoke test
├─ installer/                  Inno Setup script + autostart launcher
├─ docs/
│  ├─ sync-protocol.md
│  └─ decisions/
├─ agent/                      Go PC agent
│  ├─ cmd/cloudbox/
│  └─ internal/
│     ├─ api/                  HTTPS surface (pair, volumes, uploads)
│     ├─ blob/                 content-addressed resumable staging cache
│     ├─ folder/               atomic finalize into a sync root
│     ├─ safepath/             untrusted path sanitisation (NFC, Windows rules)
│     ├─ mdns/                 _cloudbox._tcp advertisement
│     ├─ pairing/ · identity/ · devices/ · discovery/ · volume/
│     └─ version/              generated constants
├─ app/                        Flutter Android app
│  ├─ lib/core/                pinned HTTPS client, pairing payload, models, transfer engine
│  ├─ lib/ui/                  pairing, drive-picker and send screens
│  └─ lib/core/gen/            generated version constants (do not edit)
├─ pc/                         Flutter Windows companion app
│  ├─ lib/core/                pinned HTTPS client for /local/*, config reader, models
│  ├─ lib/features/            pairing and storage screens
│  └─ lib/core/gen/            generated version constants (do not edit)
└─ dist/                       release artifacts (git-ignored, built by CI)
```

## Prerequisites

| Toolchain | Version | Needed for |
|-----------|---------|------------|
| Go | ≥ 1.26 | `agent/` |
| Flutter | ≥ 3.47 (Dart ≥ 3.13) | `app/`, `pc/` — CI pins 3.47.8 |
| Android SDK | API 35+ | `app/` — Android builds |
| JDK | 17+ | Android Gradle builds (JDK 21 present here) |

## Getting started

**PC agent** — M0 + M1 work: it serves a pinned-TLS API, pairs a device by QR, lists real
drives, and accepts resumable, verified uploads that land as real files in a chosen folder.

```sh
cd agent
go run ./cmd/cloudbox version
go run ./cmd/cloudbox serve            # prints a scannable QR code for pairing
go run ./cmd/cloudbox hash <file>      # BLAKE3-256, the transfer protocol's content ID
go build -o bin/cloudbox.exe ./cmd/cloudbox
```

`cloudbox serve` writes the pairing payload to `<data dir>/pairing.json` and a scannable image
to `<data dir>/pairing.png`, and advertises `_cloudbox._tcp` over mDNS (default data dir is
`%APPDATA%\CloudBox`). Flags: `--addr`, `--dir`, `--name`, `--pair-ttl`, `--sync-root`
(the folder that receives backups), `--sync-name`, `--blob-cache-mb`, `--mdns`.

Run the end-to-end smoke test (boots the real server, pairs, lists volumes, rejects replay and
out-of-order appends, uploads a file, commits it into the sync folder, and checks dedupe):

```powershell
pwsh eng/smoke.ps1
```

**Android app** — Flutter. Pairs over pinned TLS, lists the PC's drives, then sends files to the
drive you pick. Scan the QR shown by the PC app or paste the pairing code the agent prints, choose
a drive, pick the files to back up, and watch a resumable, hash-verified transfer land on the PC.
Tick **Upload a whole folder** to back up a folder tree instead: every file inside is queued and
its subfolders are recreated on the PC under the picked folder's name. The **Update** button in the
header checks GitHub Releases for a newer build.

```sh
cd app
flutter pub get
flutter analyze
flutter test
flutter build apk --release        # → build/app/outputs/flutter-apk/app-release.apk
```

Or, from the repository root, `pwsh eng/build-apk.ps1` stages the APK as
`dist/cloudbox-<version>.apk`. The Android `versionName`/`versionCode` are read straight from
`VERSION` in `android/app/build.gradle.kts`; see `app/README.md` for the details.

**PC desktop app** — a Flutter Windows companion with five tabs: **Pairing** (live code/QR),
**Storage** (the default drive), **Paired Devices** (add, remove, and set a backup folder for each
phone), **Backups** (where each device currently writes), and **Agent** (service status and a live
tail of the agent log). The **Update** button in the header checks GitHub Releases for a newer
build. Opening the app starts `cloudbox.exe serve` hidden if it is not already running, so a single
desktop shortcut brings up both; closing the window leaves the agent running so phones can keep
backing up. It finds the agent from `%APPDATA%\CloudBox\pairing.json` and uses its loopback-only
`/local/*` API over pinned HTTPS, so no phone token is involved. Paired devices and their
per-device folders are persisted in `%APPDATA%\CloudBox\devices.json`.

```sh
cd pc
flutter pub get
flutter analyze
flutter test
flutter build windows            # → build/windows/x64/runner/Release/cloudbox_pc.exe
```

See `pc/README.md` for how discovery and pinning work.

**Windows installer** — installs the agent and the PC companion app per-user (no administrator
required), adds Start Menu entries, and can add desktop shortcuts and start the agent at sign-in:

```powershell
pwsh eng/build-installer.ps1       # → dist/cloudbox-setup-<version>.exe
```

The installer writes the agent to `%LOCALAPPDATA%\Programs\CloudBox` and the Flutter app to its
`pc` subfolder. The optional **desktop shortcuts** task adds **CloudBox** (the desktop app) and
**CloudBox Agent** (the `serve` console) to the desktop. It also registers an optional autostart
entry under `HKCU` and offers a firewall rule when run as an administrator. Running **CloudBox**
from the Start Menu or the desktop opens the desktop app, which starts the agent hidden if needed
and shows its status and logs in the **Agent** tab. **CloudBox Agent** still opens the raw console
for debugging. The autostart entry launches the agent hidden at sign-in.

It also offers an optional **Flutter SDK** task (checked by default): it downloads the pinned
Flutter 3.47.8 Windows archive (~1.9 GB) from Google's release bucket, extracts it to
`%LOCALAPPDATA%\CloudBox\flutter`, and adds its `bin` to the user `PATH`, so the Android and PC
apps can be built on that PC. The agent itself never needs Flutter — the SDK is only there for
building the apps, and it is removed again on uninstall. Uncheck the task if you don't want it.

Building the apps on that PC still needs Git for Windows and Visual Studio Build Tools (for the
PC app); the Android app additionally needs the Android SDK and a JDK 17+. The installer sets up
only the Flutter SDK.

## Versioning

`VERSION` holds `MAJOR.MINOR.DD.MM.YY`, e.g. `0.01.15.11.26` = minor 01, released
**2026-11-15**. Generated artifacts must never be hand-edited:

```powershell
pwsh eng/version.ps1          # regenerate after changing VERSION
pwsh eng/version.ps1 -Check   # verify generated files are current (used in CI)
```

Git tags carry a `v` prefix: `v0.01.15.11.26`. See
[ADR 0001](docs/decisions/0001-versioning.md) for the mapping to Android `versionCode` and the
Dart `pubspec.yaml` constraint.

## License

Not chosen yet — see `PLAN.md` §14, open question 6.
