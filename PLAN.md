# CloudBox — Product & Technical Plan

**Status:** Draft v0.1 · **Date:** 2026-11-13 · **Owner:** you

---

## 1. What CloudBox is

> **CloudBox turns your own PC into your private cloud.** An Android app that backs up the
> media you choose to the drive you choose on your own machine — and keeps a folder in
> sync between phone and PC. No subscription, no third-party storage, no data leaving home.

One-liner for a store listing:

> *Your PC is the cloud. Pick the photos, videos and music you care about, pick the drive
> they land on, and CloudBox keeps them safe — at home on Wi-Fi, or anywhere over a private
> network.*

### The three things it does

| # | Capability | What the user sees |
|---|------------|--------------------|
| 1 | **Backup** | "My camera photos and videos are copied to `F:\CloudBox\Phone\Pixel-8` and stay in sync." One-way, phone is the source of truth. |
| 2 | **Sync** | "This folder exists identically on my phone and my PC. Edit on either side." Two-way, conflicts never lose data. |
| 3 | **Pull down** | "My music library lives on the PC; the phone keeps an offline copy." One-way, PC → phone. |

The differentiating detail you asked for — **the user picks the target drive** — is a
first-class part of setup, not a config file. The PC agent reports its volumes (label,
filesystem, free space, removable?) and the phone shows them as cards: *C: Windows (SSD,
412 GB free)*, *E: Elements (USB, 1.8 TB free)*.

---

## 2. Who it's for, and the stories that define v1

**Primary user:** someone with a few hundred GB of phone photos, a PC with spare disk, and
no interest in paying €10/month for iCloud/Google One.

**Anti-user:** someone who wants a family NAS with shares, permissions and web access.
That is Nextcloud's job, not ours.

### User stories (v1 acceptance set)

- **S1 — First run.** I install the PC agent, it shows a QR code. I install the app, scan it,
  and I'm paired in under 60 seconds without typing an IP address or password.
- **S2 — Choose destination.** During setup the app lists the PC's drives with free space and
  lets me pick a drive + folder. I can change it later per source.
- **S3 — Choose what to back up.** I toggle *Camera*, *Screenshots*, *Downloads*, *Music*,
  and optionally pick individual albums. I can see an estimate: "12,480 items · 84 GB".
- **S4 — Backup runs unattended.** On Wi-Fi and charging, without me opening the app, new
  photos upload. If I kill the app, it resumes.
- **S5 — Restore.** I get a new phone or nuke a folder; CloudBox pulls my library back,
  preserving capture dates so the gallery sorts correctly.
- **S6 — Two-way folder.** I create `Documents` as a synced folder. I edit a file on the PC;
  it appears on the phone. I edit on both offline; I get `report (conflicted copy from
  DESKTOP 2026-11-13).docx` and lose nothing.
- **S7 — Away from home.** Over my tailnet, backup continues on mobile data (opt-in) or when
  I'm on hotel Wi-Fi.
- **S8 — Trust.** I can see exactly what was transferred, retry a failure, and nothing is
  ever deleted without passing through a trash folder.

### Non-goals (v1)

- ❌ Public share links, multi-user accounts, per-folder ACLs
- ❌ End-to-end encryption (the PC is the trusted endpoint; transport is encrypted)
- ❌ Streaming media from the PC to the phone (design leaves room; built in M5)
- ❌ iOS (Dart keeps the door open; no work spent on it)
- ❌ Docker/NAS/headless-Linux as the primary host (agent should *run*, but UX targets Windows)

---

## 3. Decisions locked

| Area | Decision | Why |
|------|----------|-----|
| Reachability | LAN first, **plus tailnet** (`tsnet` embedded) | No public port exposure. Remote access without hosting anything. |
| Sync model | **Bidirectional**, but bounded by folder mode | True two-way where it's wanted, conflict-free by construction where it isn't. See §6. |
| Android | **Flutter** (Dart) + Kotlin platform channels | Your call. Native channels only where Android forces it (MediaStore, FGS). |
| PC agent | **Go, single static binary** (`CGO_ENABLED=0`) | One `.exe`, no runtime, no installer dependency hell, trivially cross-compiled. |
| Transport | HTTPS on 443/8443-ish with **self-signed cert + SPKI pinning** | Works on LAN with no DNS/CA. Pin comes from the pairing QR. |
| Auth | Per-device **bearer token** in Android Keystore, revocable | Adequate behind pinned TLS; far simpler than mTLS in Dart. |
| Discovery | mDNS `_cloudbox._tcp` + manual host:port + tailnet DNS name | Three fallbacks so setup rarely needs typing. |
| File identity | **Content-addressed staging + BLAKE3**, files finalized as real files | Dedupe, free renames, resumable transfers — and the user's drive stays browsable in Explorer. |
| Conflict model | Per-file **vector clocks** (tiny: 2 devices = 2 ints) | Precise causality, no clock trust. |
| Deletion | **Tombstones + `.cloudbox-trash/`** with TTL | Sync engines earn trust by never eating data. |

---

## 4. Architecture

```
┌─────────────────────────────┐            ┌──────────────────────────────────────┐
│  ANDROID (Flutter)          │            │  PC AGENT (Go, one binary)           │
│                             │            │                                      │
│  UI (Material 3)            │            │  ┌────────────┐   ┌───────────────┐  │
│   setup · library · sync    │            │  │ HTTP API   │   │ Tray / Service│  │
│                             │            │  │ (chi)      │   │ + local web UI│  │
│  Sync orchestrator (Dart)   │  HTTPS     │  └─────┬──────┘   └───────────────┘  │
│   ├─ planner (what/when)    │◄──────────►│        │                             │
│   ├─ journal + index        │  pinned    │  ┌─────▼──────┐  ┌───────────────┐  │
│   └─ transfer queue         │  TLS       │  │ Sync engine│  │ Volume probe  │  │
│                             │            │  │ + index DB │  │ (drives/free) │  │
│  background_downloader ─────┼────────────┤  └─────┬──────┘  └───────────────┘  │
│  (WorkManager / UIDT)       │            │        │                             │
│  workmanager (periodic)     │            │  ┌─────▼──────┐  ┌───────────────┐  │
│                             │            │  │ Blob stage │  │ fsnotify watch│  │
│  MediaStore / photo_manager │            │  │ (BLAKE3)   │  │ (PC-side chtg)│  │
│  SQLite (drift)             │            │  └─────┬──────┘  └───────────────┘  │
│  Keystore (token)           │            │        ▼                             │
└─────────────────────────────┘            │  F:\CloudBox\Phone\Pixel-8\...       │
                                           │  (real files, Explorer-browsable)    │
        ┌──────────────────┐               │                                      │
        │ mDNS / tailnet   │               │  tsnet (optional) ──► tailnet        │
        └──────────────────┘               └──────────────────────────────────────┘
```

### Component responsibilities

**PC agent (Go)**
1. **HTTP API** — pairing, sync negotiation, resumable blob transfer, browse/admin.
2. **Sync engine** — journal, vector clocks, conflict resolution, tombstones, trash.
3. **Blob staging store** — `BLAKE3`-addressed, resumable, dedupes renames and duplicates.
4. **Volume probe** — enumerates drives with label/filesystem/free-space/removable flags.
5. **Folder watcher** — `fsnotify` per sync root, with debounce, to catch PC-side edits.
6. **Host shell** — tray icon, autostart, Windows service mode, localhost web UI for logs.

**Android app (Flutter)**
1. **Setup wizard** — QR scan → pin → name device → pick volume → pick sources.
2. **Library/source config** — which MediaStore buckets/albums are included, per-source target.
3. **Sync orchestrator** — decides *what* to transfer and *when*; owns the local journal.
4. **Transfer queue** — `background_downloader` for the bytes; survives process death.
5. **Scheduler** — `workmanager` periodic + constraints (Wi-Fi, charging, battery).
6. **Local index** — SQLite via `drift`; mirrors the server's per-file records.

**Why the phone drives the protocol:** phones are the constrained, frequently-asleep side.
If the server drove, every phone wake-up would require the server to reach a device that may
be asleep behind NAT. Instead the phone pulls: *"here's what I changed since seq 41, what did
you change?"* The PC only needs to be reachable, never initiating.

---

## 5. How the pieces fit — a backup in 8 steps

1. Phone wakes on a sync trigger (periodic worker, app open, or "Sync now").
2. Phone discovers the PC: last-good address → mDNS → tailnet name.
3. Phone `POST /v1/sync/negotiate` with `{folder_id, since_seq: 41, changes: [...]}`.
4. Server applies phone changes to its index, detects conflicts, replies with its own journal
   delta since the phone's last-seen server seq.
5. Phone diffs the two journals to build a transfer plan (uploads, downloads, deletes, conflicts).
6. Bytes move: `PATCH /v1/uploads/{id}?offset=N` upward, `GET /v1/blobs/{hash}` downward,
   both resumable and content-verified (`BLAKE3` matches or the transfer is rejected).
7. Server finalizes: atomically `link()`/`rename()` from staging into the target drive path,
   sets mtime from the source, indexes it. Phone marks the record synced.
8. Both sides advance their watermarks; journal entries below both watermarks are pruned.

Latency budget: negotiating 10,000 changed entries should be one round trip (~200 KB JSON,
paginated if larger) plus transfers. Metadata-only sync of 50k files should finish in seconds.

---

## 6. Folder modes — where "two-way" gets bounded

Full bidirectional sync everywhere is how these apps become footguns. CloudBox gives each
source folder exactly one of three modes, chosen at setup:

| Mode | Direction | Deletes propagate? | Typical use |
|------|-----------|--------------------|-------------|
| `backup` | Phone → PC | **Never.** PC-side deletes are recorded as tombstones (so they don't re-upload) but phone deletes never touch the vault. | DCIM, Screenshots, WhatsApp media |
| `sync` | Both ways | Yes, but always into `.cloudbox-trash/` first. Conflicts → conflict copies. | Documents, Notes, project folders |
| `down` | PC → Phone | Yes on the PC side, mirrored to the phone copy. | Music, podcasts, offline video |

**Why this matters:** `backup` mode is conflict-free *by construction* — there is only one
writer, so no vector clock can ever be concurrent. That means the riskiest code path (M3)
isn't on the critical path for the most common use case (M1). You get a shippable backup app
before you get a sync engine.

**Conflict policy (`sync` mode only).** Never lose data; prefer deterministic outcomes:

- Both sides changed, content identical → merge clocks, transfer nothing.
- Both sides changed, content differs → newer mtime keeps the canonical name, older becomes
  `<name> (conflicted copy from <DEVICE> <YYYY-MM-DD>).<ext>`. Ties broken by lowest device ID.
- Deleted on one side, modified on the other → **modification wins**, the file is resurrected.
- Deleted on both sides → delete, merge clocks.

Full protocol, including the vector-clock algorithm and HTTP surface:
**[`docs/sync-protocol.md`](docs/sync-protocol.md)**.

---

## 7. Data model

### On the PC

```
F:\CloudBox\                          ← sync root chosen by user (any drive)
├── Phone\Pixel-8\DCIM\Camera\…        ← backup target, real files, normal names
├── Documents\…                        ← sync folder, two-way
├── .cloudbox-trash\2026-11-13\…       ← deleted files, retained N days
└── .cloudbox\                         ← internal
    ├── cloudbox.db                    ← SQLite: index, journal, devices
    ├── staging\<hash-prefix>\<hash>   ← in-flight + dedupe blobs
    └── logs\
```

Files live **as real files** in real folders — the user can browse, copy, and back up the
result with any other tool. Staging is only a rest stop, not the permanent store.

### SQLite schema (PC side)

```sql
devices(id TEXT PK, name TEXT, token_hash BLOB, created_at, last_seen_at,
        acked_seq INTEGER, revoked INTEGER)

folders(id TEXT PK, rel_name TEXT, local_path TEXT, mode TEXT,      -- backup|sync|down
        enabled INTEGER, created_at)

files(id INTEGER PK, folder_id TEXT, rel_path TEXT,                 -- NFC, '/'-separated
      size INTEGER, mtime_ms INTEGER, hlc TEXT,
      hash BLOB, hash_state TEXT,                                   -- none|partial|full
      clock TEXT,                                                   -- JSON {device_id: counter}
      deleted INTEGER, deleted_at, seq INTEGER,                     -- seq = local journal position
      UNIQUE(folder_id, rel_path))

journal(seq INTEGER PK, folder_id TEXT, file_id INTEGER, op TEXT,   -- upsert|delete|move
        clock TEXT, created_at)

blobs(hash BLOB PK, size INTEGER, refcount INTEGER, verified INTEGER)

transfers(id TEXT PK, folder_id, rel_path, direction TEXT, bytes_total, bytes_done,
          state TEXT, last_error, attempts, updated_at)
```

Key indexes: `files(folder_id, seq)`, `files(folder_id, rel_path)`, `journal(folder_id, seq)`,
`blobs(refcount)`.

### On the phone

Same `files`/`journal` shape plus:
- `sources(id, kind, media_store_bucket, include_pattern, target_folder_id, mode, enabled)`
- `media_ref(source_id, media_store_id, rel_path, size, mtime, hash, hash_state, synced_seq)`
- `settings`, `server_endpoints(host, port, pin_sha256, last_ok_at, priority)`

---

## 8. PC agent design notes

**Language/libs:** Go 1.24+, stdlib `net/http` with 1.22+ method patterns (no router needed),
`modernc.org/sqlite` (pure Go → no cgo), `zeebo/blake3`, `fsnotify`, `tailscale.com/tsnet`,
`getlantern/systray` (or `energye/systray`), `kardianos/service` for Windows service mode.

**Windows specifics that *will* bite — handle in v1, not later:**

| Issue | Handling |
|-------|----------|
| Drive letters change / USB unplugged | Persist volume identity (serial + label), not the letter. Mark folder `unavailable`, pause sync, resume on reconnect. |
| `MAX_PATH` 260 | Prefix long paths with `\\?\`. Test with deep album nesting. |
| Reserved names (`CON`, `NUL`, `COM1`…) and `: ? * " < > \|` | Sanitize on finalize; store the reversible mapping in the DB. |
| Case-insensitive collisions (`IMG.JPG` vs `img.jpg`) | Detect and suffix `~1`; log it. |
| FAT32 4 GB file limit | Detect FS from the volume probe; warn before a >4 GB video is attempted. |
| Antivirus locking files mid-read | Retry with backoff; never corrupt a blob (write to temp, fsync, rename). |
| Firewall prompt on first run | Offer to add the rule; document the manual path. |
| Sleep / shutdown mid-transfer | Transfers are resumable by offset; index is transactional. |
| Unicode NFC/NFD | Normalize to NFC on ingest; compare normalized. |

**Concurrency:** one writer goroutine per folder; transfers parallel across folders. All index
writes in a single SQLite writer goroutine with batched transactions (avoids lock contention
and gives crash-consistency for free).

**tsnet:** a config toggle. When enabled, the agent joins the tailnet as `cloudbox` and
advertises `https://cloudbox.<tailnet>.ts.net`. LAN stays available simultaneously — the phone
prefers LAN (faster, no relay) and falls back to the tailnet. Zero config change for the user
beyond one "Enable remote access" button that prints a one-time auth URL.

---

## 9. Android app design notes

**Flutter packages:** `background_downloader` (transfers), `workmanager` (periodic sync),
`drift` + `sqlite3_flutter_libs` (index), `photo_manager` (media enumeration + thumbnails),
`on_audio_query` or a MediaStore channel (music), `mobile_scanner` (QR), `flutter_secure_storage`
(token), `riverpod`, `go_router`, `connectivity_plus`, `device_info_plus`.

**The Android constraints that shape the UX — be explicit with users:**

1. **Two permissions, two jobs.** Full-library backup needs `READ_MEDIA_IMAGES/VIDEO/AUDIO`
   (Android 13+). The Photo Picker only supports manual one-off selection. Setup must request
   the full set, with a plain-language rationale and a "limited selection" fallback.
2. **Background execution is hostile.** WorkManager is capped at ~9 minutes per run; long
   transfers must either resume across cycles (`background_downloader` does this automatically)
   or run in a **foreground service** with `foregroundServiceType="dataSync"` plus a persistent
   notification. v1 plan: user-initiated sync = FGS (honest progress bar); overnight sync =
   WorkManager + resume.
3. **OEM battery killers.** Xiaomi/Huawei/Oppo/Samsung aggressively kill background work. Ship
   a "Make backup reliable" help card with per-OEM instructions and a battery-optimisation
   exemption request.
4. **Doze + airplane mode.** Never show a scary error for "network unavailable" — queue and
   retry with exponential backoff capped at 6 h.
5. **Where the two-way folder lives.** Scoped storage makes an arbitrary writable folder hard.
   v1 writes the phone side of `sync` folders into **app-private** storage
   (`Android/data/<pkg>/files/CloudBox/`) and exposes it through the app's own browser, with a
   "Save to gallery" action that inserts via MediaStore. SAF tree URIs are a v2 option (they
   cost reliable mtimes and IO speed).
6. **Keep the index hot.** Opening the app should show real state instantly — the index lives in
   SQLite, not in a network call.

**Battery/network policy (user-facing toggles):** Wi-Fi only (default on), charging only
(default on), allow tailnet/mobile data, "aggressive sync while charging", per-source
scheduling windows (e.g. 02:00–06:00).

---

## 10. Security model

| Concern | v1 answer |
|---------|-----------|
| Eavesdropping on LAN | TLS with self-signed cert; phone pins SHA-256 SPKI from the pairing QR. Wrong pin = hard fail, no user override. |
| Impersonating the PC | Pin. An attacker on the LAN cannot MITM without the private key. |
| Unauthorised phone | Pairing token is single-use, 5-minute TTL, shown only on the PC tray UI. Afterwards each device has a revocable token in Android Keystore. |
| Internet exposure | None by default. Overlay network only; no port forwarding, no relay we operate. |
| Data at rest on PC | Plaintext (the PC is the trust boundary), inside the user's own filesystem/backup. Optional per-folder encryption is a post-v1 toggle. |
| Leaked phone | Revoke from the PC tray UI; token dies immediately. |
| Malicious path traversal | Every `rel_path` is validated against `..`, absolute paths, drive letters, and symlink escape before any write. |

---

## 11. Roadmap

Effort assumes one developer, full-time. Halve nothing; double it if it's evenings-and-weekends.

### M0 · Foundations — 1–2 weeks
Monorepo, CI, Go agent skeleton with `/healthz`, cert generation, mDNS advertise; Flutter app
skeleton with pairing screen.
**Done when:** app finds the agent on the LAN and completes a TLS-pinned handshake.

### M1 · Shippable one-way backup — 4–6 weeks ⭐ *first real product*
Pairing QR, volume probe + drive picker, source selection, full+incremental scan, resumable
`BLAKE3` uploads, staging → atomic finalize, backup-mode journal (no delete propagation),
progress UI, retry.
**Done when:** 20 GB / 20k photos back up unattended overnight, resume after a mid-transfer
reboot, and produce a byte-identical target with correct mtimes.

### M2 · Unattended & trustworthy — 2–3 weeks
WorkManager scheduling + foreground service, network/battery policies, OEM help card,
PC tray + autostart + Windows service, logs UI, transfer history, free-space guard,
trash folder, "verify library" scrub pass.
**Done when:** a week of normal phone use needs zero manual intervention, and a corrupted
upload is detected by the scrub.

### M3 · Two-way sync engine — 4–6 weeks ⭐ *highest risk*
Journal exchange, vector clocks, conflict copies, tombstones + watermark GC, `sync` and `down`
modes, `fsnotify` PC-side change capture, phone-side app-private sync folder, restore-to-new-phone
flow.
**Done when:** the convergence simulator passes (see §12) and a deliberate offline-edit-both-sides
test ends with both versions present and nothing lost.

### M4 · Away from home — 1–2 weeks
`tsnet` toggle, tailnet discovery, endpoint fallback ordering, mobile-data policy, optional
Wake-on-LAN for the sleeping PC.
**Done when:** backup completes over a tailnet-only connection from a foreign Wi-Fi.

### M5 · Beyond backup — 4+ weeks
Browse/stream the PC library from the phone (range requests, server-side thumbnails),
on-this-day, storage report, dedupe report, share-to-CloudBox targets, optional per-folder
encryption, SAF-based visible sync folders.

### Explicitly deferred
Delta/block-level sync for huge files, multi-device mesh (3+), public shares, iOS, versioning
history beyond trash.

---

## 12. Testing strategy

The part that decides whether this app is trustworthy:

1. **Protocol conformance tests** (Go): golden JSON request/response pairs for negotiate, apply,
   conflict, and transfer-finalize.
2. **Convergence simulator** ⭐ — a Go harness with two virtual devices over a temp-dir
   filesystem, each with a fault injector. It applies random `create/modify/delete/rename/
   truncate` operations on both sides, randomly partitions the network, randomly drops responses
   mid-transfer, then reconnects until quiescent. Asserts: (a) both sides converge to identical
   content, (b) no user file is ever lost without a trash/conflict record, (c) idempotent
   re-sync does zero work. Run thousands of seeds in CI. *This is the only credible way to
   validate a sync engine.*
3. **Property tests** on path sanitisation and reconciliation (no path escapes, no collisions).
4. **Real-device matrix**: Pixel (stock Android 16), Samsung (One UI), a Xiaomi (killer
   background), one Android 11 device. Physical Windows 10 + 11, USB exFAT drive, FAT32 SD card.
5. **Chaos runs**: pull the USB drive mid-transfer; sleep the PC; kill the app from recents;
   fill the disk to 100%.

---

## 13. Repo layout

Scaffolded at `0.00.13.11.26` — see [ADR 0001](docs/decisions/0001-versioning.md).

```
CloudBox/
├─ VERSION                    ← single source of truth: MAJOR.MINOR.DD.MM.YY
├─ PLAN.md
├─ CHANGELOG.md
├─ eng/version.ps1            ← regenerates version artifacts; -Check in CI
├─ docs/
│  ├─ sync-protocol.md        ← the spec
│  └─ decisions/              ← short ADRs as we make calls
├─ agent/                     ← Go
│  ├─ cmd/cloudbox/main.go
│  ├─ internal/api/           ← handlers, auth middleware
│  ├─ internal/syncer/        ← journal, clocks, conflicts, trash
│  ├─ internal/blob/          ← staging, hashing, resumable IO
│  ├─ internal/volume/        ← drive enumeration (per-OS)
│  ├─ internal/store/         ← sqlite
│  ├─ internal/net/           ← tls, mDNS, tsnet
│  └─ internal/simulator/     ← convergence harness
└─ app/                       ← Flutter
   ├─ lib/core/gen/version.dart   ← generated, do not edit
   ├─ lib/core/               ← protocol client, crypto, endpoints
   ├─ lib/features/setup|library|sync|settings
   ├─ lib/sync/               ← orchestrator, planner, journal
   └─ android/app/src/main/kotlin/  ← MediaStore + FGS channels
```

---

## 14. Open questions

1. **Music: MediaStore or folder roots?** Album art and playlists live better as folders, but
   enumerating is uglier. Affects the `down` mode design.
2. **Two-way on the phone: app-private or SAF?** App-private is simpler and reliable; SAF is
   visible in Files and other apps. Leaning app-private + "Save to gallery" for v1.
3. **Trash retention default** — 30 days, forever, or size-capped (e.g. 5% of volume)?
4. **Multi-phone support in v1?** The schema allows it; the UI and conflict policy get more
   opinions. Suggest: allow it, but one phone at a time per source.
5. **Distribution** — Play Store (background-permission justification needed), direct APK, or
   both? Affects how aggressively we can ask for battery exemptions.
6. **Licence** — MIT/Apache for the agent? Decide before the first commit.
7. **Do we ship the Windows agent as installer, portable zip, or both?** Portable zip first.

---

## 15. Next actions

1. Answer the open questions above (or accept the leanings).
2. ~~`git init` + monorepo skeleton + CI.~~ Done at `0.00.13.11.26`.
3. Write `docs/sync-protocol.md` v0.2 → freeze the wire format before either side gets cosy
   with its own assumptions.
4. ~~M0 agent half: pinned TLS, `/healthz`, pairing, drive enumeration.~~ Done at
   `0.00.13.11.26` and proven end to end by `eng/smoke.ps1`. Still missing from M0: rendering
   the payload as an actual QR image, and mDNS advertisement of `cloudbox.local`.
5. M0 app half: QR scan → pin check → pair → drive picker. Blocked on Flutter.

**Toolchain status.** Go 1.27.4 is installed and the agent builds, vets, tests and
cross-compiles for Linux and macOS. `flutter`/`dart` and the Android SDK are still missing, so
the app cannot be scaffolded or run yet. JDK 21 is present at `F:\dev\jdk21`. Install order
that unblocks the most work: Flutter (bundles Dart) → Android SDK via
`flutter doctor --android-licenses`.
