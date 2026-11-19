# CloudBox Sync Protocol — v0.1 (draft)

Companion to [`../PLAN.md`](../PLAN.md) §6. This is the wire contract between the Go agent and
the Flutter app. **Freeze this before either side is written**, or you'll debug two
mutually-confident interpreters.

---

## 0. Design constraints

| Constraint | Consequence |
|------------|-------------|
| The phone is frequently asleep, behind NAT, on a flaky link | **Phone always initiates.** Server is purely reactive: no push, no long-poll, no callbacks. |
| No common CA, no DNS on a home LAN | Self-signed TLS + SPKI pin delivered out-of-band in the pairing QR. |
| The user browses the target drive in Explorer | Final files are real files with real names; content-addressing is staging-only. |
| Users bulk-copy 50k+ files | Cheap fingerprints first (`size`,`mtime`); hash only when needed. |
| Exactly two peers in v1 (N designed, 2 optimised) | Vector clocks are 2 integers. Don't reach for CRDTs or Merkle trees. |
| Data loss is unrecoverable trust loss | Deletes are tombstones; every destructive act goes through trash. |

---

## 1. Identifiers

| Name | Shape | Notes |
|------|-------|-------|
| `server_id` | 16 bytes hex | Generated at agent first run; also the TLS cert CN. |
| `device_id` | 16 bytes hex | Generated on the phone at pairing; stable for the install. |
| `folder_id` | 16 bytes hex | Server-assigned, one per sync root. |
| `file_id` | int64 | Local to each side's DB. **Never** crosses the wire. Paths are the shared key. |
| `rel_path` | string | Relative to the folder root. Always `/`-separated, **NFC-normalised**, no leading `/`, no `..`. |
| `hash` | 32 bytes | BLAKE3-256 of the plaintext file content. |
| `seq` | int64 | Monotonic per side; position in that side's journal. |
| `clock` | `{device_id: int}` | Vector clock. JSON object. |

`rel_path` is the only stable cross-device identity. Renames therefore look like
delete+create at the API level — and that's fine, because content-addressing makes the
"create" free (§7).

---

## 2. Pairing

```
PC tray UI                          Phone
──────────                          ─────
generate one-time token (5 min TTL)
render QR:
  {"v":1,
   "sid":"a1b2…",
   "eps":["192.168.1.42:8443",
          "desktop.local:8443",
          "cloudbox.tailnet.ts.net:8443"],
   "pin":"sha256-spki-base64",
   "tok":"one-time-base64"}
                                    scan → try `eps` in order, 2 s connect timeout each
                                    verify cert SPKI == pin   (hard fail otherwise)
                                    POST /v1/pair  {token, device_name, platform,
                                                    app_version, pubkey?}
        ◄───────────────────────────
  validate token, burn it
  201 {device_id, device_token, server_name, folders:[]}
                                    store device_token in Android Keystore
                                    GET /v1/system/volumes
```

Rules:

- Token is single-use and dies on first successful pair **or** TTL expiry.
- `device_token` is 32 random bytes, sent as `Authorization: Bearer <hex>`, stored as an
  Argon2/bcrypt hash server-side. Never logged.
- The pin is compared against the **SPKI** (public key) digest, not the whole cert, so cert
  renewal with the same key doesn't force re-pairing.
- Re-pairing the same physical phone creates a new `device_id`; the old one must be revoked
  explicitly from the tray (so a lost phone can't be resurrected by re-pairing a new one).

---

## 3. Folder modes (authoritative semantics)

`mode` is server-side state, editable from the phone. It governs **who may write what** — this
is what keeps `backup` conflict-free.

| Mode | Phone→PC | PC→Phone | Delete propagates | Clock concurrency possible? |
|------|:--------:|:--------:|:-----------------:|:---------------------------:|
| `backup` | ✅ | ❌ | ❌ (PC deletes → tombstone only) | **No** — single writer |
| `down` | ❌ | ✅ | ✅ PC→phone | **No** — single writer |
| `sync` | ✅ | ✅ | ✅ both ways (via trash) | **Yes** — full resolution rules |

Server rejects any write to a `backup` folder that claims to originate from the PC side, and
any phone-originated upload to a `down` folder (`409 MODE_CONFLICT`). This is the invariant
that makes `backup` trivially correct: **only one side ever mutates it.**

---

## 4. The file record

Both sides store, per `(folder_id, rel_path)`:

```json
{
  "path": "DCIM/Camera/IMG_20261113_141002.jpg",
  "size": 4194304,
  "mtime_ms": 1763043002123,
  "hlc": "0000019a2f3c1b22:0007:a1b2c3d4",
  "hash": "9f2c…32 bytes hex",
  "hash_state": "full",
  "clock": {"d-pixel8": 17, "d-desktop": 4},
  "deleted": false
}
```

- **`size` + `mtime_ms`** are the cheap fingerprint. If both match, assume unchanged (this is
  what makes a 50k-file scan take seconds, not hours).
- **`hash`** is computed lazily. `hash_state`: `none` → `partial` (transfer in progress) →
  `full`. A background "scrub" job upgrades `none`→`full` opportunistically.
- **`hlc`** is a hybrid logical clock: `"<unix_hex>:<counter_hex>:<device_id>"`. It is
  comparable as a string and always advances, even if wall clocks are wrong. Used for
  human-facing "newer" decisions (which side keeps the canonical name) — **never** for
  causality.
- **`deleted`** marks a tombstone: the record survives for `tombstone_ttl` (default 90 d) so
  deletes can't be resurrected by a stale peer, then is GC'd once acknowledged (§9).

### Vector clock comparison

```
compare(a, b):
  a_le_b = ∀k: a[k] <= b[k]      # a is dominated by (or equal to) b
  b_le_a = ∀k: b[k] <= a[k]
  both      → EQUAL
  a_le_b    → BEFORE     (b is newer)
  b_le_a    → AFTER      (a is newer)
  neither   → CONCURRENT (possible conflict)
```
Missing key = 0. On any accepted local mutation: `clock[self] += 1`, and on merge:
`clock[k] = max(local[k], remote[k])` for every key.

---

## 5. Journal

Append-only, per folder, monotonically increasing `seq`:

```sql
journal(seq INTEGER PRIMARY KEY, folder_id, path, op, clock, record_json, created_at)
-- op ∈ {upsert, delete}
```

- Every local mutation appends one entry **in the same transaction** as the `files` update.
- Each side persists `peer_seq` = the highest remote `seq` it has fully applied.
- Journal rows may be pruned when `seq <= min(acked_seq over all peers)`.
- `acked_seq` is reported by the peer on every negotiate call (§6.3) — a two-way watermark.

No entry is ever mutated. If a negotiation fails halfway, the reader simply replays from the
last `peer_seq`. That's the entire crash-recovery story.

---

## 6. Session flow

A session is one HTTP request-response chain, all over one TLS connection, all idempotent.

### 6.1 Negotiate

`POST /v1/folders/{folder_id}/negotiate`

```json
{
  "device_id": "d-pixel8",
  "since_seq": 412,             // my view of your journal
  "acked_seq": 980,             // highest of MY seqs you have applied (your watermark)
  "changes": [                  // my journal entries since our last successful session
    {"seq": 41, "path": "DCIM/Camera/a.jpg", "op": "upsert",
     "record": { …file record… }},
    {"seq": 42, "path": "DCIM/Camera/b.jpg", "op": "delete",
     "record": {"path":"DCIM/Camera/b.jpg","deleted":true,"clock":{…},"hlc":"…"}}
  ],
  "limit": 5000
}
```

Response:

```json
{
  "since_seq": 412,
  "next_seq": 447,
  "acked_seq": 41,                 // your new watermark on my journal
  "changes": [ …my journal delta since 412… ],
  "conflicts": [
    {"path":"Docs/report.docx",
     "resolution":"conflict_copy",
     "winner":"remote",
     "loser_path":"Docs/report (conflicted copy from DESKTOP 2026-11-13).docx"}
  ],
  "need_hashes": ["Docs/big.iso"],  // ambiguous cases: send me your hash
  "has_more": false
}
```

Rules:

- `changes` is capped by `limit`; if `has_more`, the phone repeats with the returned `next_seq`.
- The server applies the phone's `changes` **before** computing its own delta, so the response
  already reflects any conflicts caused by this batch.
- Applying is transactional per batch. If the connection dies after apply but before the
  response is read, the phone retries from its old `peer_seq` — the server must treat a
  re-sent `upsert` with an `EQUAL` clock as a **no-op**, not an error. Idempotency is required.

### 6.2 Reconciliation (server side, per path)

```
L = local record, R = incoming record
if R.absent:                        continue
cmp = compare(L.clock, R.clock)
if cmp == EQUAL:                    no-op
if cmp == BEFORE:                   fast-forward → L = R
if cmp == AFTER:                    ignore R (I'm ahead; R is stale)
if cmp == CONCURRENT:               → §6.4
```

### 6.3 Applying the far side's delta (phone side)

Symmetric, with one asymmetry: the phone **cannot** write to a folder the server declares
read-only for it (`backup` PC-side deletes). Those arrive as `tombstone` directives and the
phone just advances its watermark without deleting anything locally.

### 6.4 Concurrent case

```
if L.deleted and R.deleted:        merge clocks; delete; done
if L.deleted and not R.deleted:    resurrect R  (modification beats deletion)
if not L.deleted and R.deleted:    resurrect L
if both present:
    if L.size != R.size:                     conflict — no hashing needed
    elif L.hash and R.hash and L.hash == R.hash:  merge clocks; no transfer
    elif not both hashed:                    response includes path in `need_hashes`
    else:                                     conflict → §6.5
```

**`need_hashes` round trip** (only on the ambiguous path — same size, both unhashed): the phone
hashes those files locally, sends `POST …/hashes {path: hash}`, and the server hashes its copies
in the background and replies. If equal → clocks merge, nothing transfers. This is what keeps
byte-identical duplicate photos from generating spurious conflict copies.

### 6.5 Conflict copies

Deterministic, so both sides independently agree without extra round trips:

1. Winner = greater `hlc`; tie → lexicographically smaller `device_id`.
2. Loser is written to
   `"<stem> (conflicted copy from <DEVICE_NAME> <YYYY-MM-DD>)<ext>"`.
   If that name exists, append ` 2`, ` 3`, …
3. The conflict copy's clock = `merge(L.clock, R.clock)` with `self += 1` — strictly *after*
   both, so it can never conflict again.
4. Both records are journaled as normal `upsert`s; the copy propagates like any other file.

A conflict copy is a **success state**, not an error. The UI says "kept both versions" and
links to the copy.

---

## 7. Content transfer

Content-addressed, resumable, verified. No file is ever partially visible at its final path.

### 7.1 Upload

```
POST /v1/uploads                 {hash, size, folder_id}  → 201 {upload_id, offset: 0, complete}
PATCH /v1/uploads/{upload_id}    body: bytes, header: Content-Range: bytes N-M/size
PATCH (repeat, on failure)       → 200 {offset: M+1}     (server tells you where to resume)
GET  /v1/uploads/{upload_id}     → 200 {offset, size, state}
POST /v1/uploads/{upload_id}/commit  {hash, path, mtime_ms, clock}
                                 → 200 {committed:true, path, deduped, replaced}
                                 | 422 HASH_MISMATCH
```

`complete: true` on create means the server already holds the content: skip the PATCH phase.
A PATCH whose `Content-Range` start does not match the server's offset gets `409 OFFSET_MISMATCH`
with the real `offset` in the body.

Server behaviour:
1. Bytes land in `.cloudbox/cache/staging/<upload_id>.part` with `fsync` before each ack. The
   authoritative offset is the staging file's **size on disk**, not in-memory state, so a
   dropped connection, a retried request, or a server restart all resume from the same place.
2. On `commit`, re-verify BLAKE3 over the whole staged file. Mismatch → `422 HASH_MISMATCH` and
   the staging file is **deleted**, not retained: a hostile or buggy client must not be able to
   fill the disk with content that will never verify. The client re-uploads from `offset 0`.
3. Dedupe: if `blobs[hash]` already exists and is `verified`, the commit is a metadata-only
   operation — this is why renames, moves, and duplicate photos cost no bandwidth.
4. Finalize atomically: sanitize the path (§8), copy (not hard-link) into place via a temp name
   + `os.Rename`. Set mtime **from the source**, so galleries sort by capture date.
5. Only then update `files` + append the journal entry, in one transaction. (M1 finalizes the
   file; the `files` index and journal arrive with the sync engine in M3.)

If the process dies between 4 and 5, the startup reconciler finds a file present with no index
row and adopts it by hashing — never deletes.

### 7.2 Download

```
GET /v1/blobs/{hash}?offset=N     → 206, Range-capable, ETag = hash
```

Same verification on the phone side. Phone writes to `.../CloudBox/.tmp/<hash>.part`, verifies,
then `rename()`s into the sync folder.

### 7.3 Why fixed-offset resumption (and not chunk hashes)

Chunk-level verification is the right answer eventually, but offset resumption + whole-file
verification is enough for v1 and roughly 5× less code. Revisit only if users report
"large video always restarts".

---

## 8. Path handling

Applied on ingest, before any filesystem write:

1. Normalise Unicode to **NFC**.
2. Convert `\` → `/`; reject absolute paths, `..`, empty segments, drive letters.
3. Reject/replace characters illegal on the target OS (Windows: `< > : " | ? *`, NUL, trailing
   dot/space; reserved basenames `CON PRN AUX NUL COM1..9 LPT1..9`).
4. Truncate each segment to 255 **bytes** at a UTF-8 boundary.
5. Detect case-insensitive collisions on case-insensitive filesystems → suffix `~1`, `~2`.
6. Reject symlinks escaping the root; the server never follows a symlink out of a folder.
7. Enforce a total-path guard (`\\?\` prefix on Windows) rather than failing.

The `files.rel_path` column stores the **sanitised** path, and a `path_map` table keeps the
original for round-tripping back to the phone. The server is authoritative on sanitisation —
the phone must accept whatever path the server reports.

---

## 9. Deletes, trash, and tombstone GC

- **Never** unlink directly. `os.Rename` into `<root>/.cloudbox-trash/<YYYY-MM-DD>/<rel_path>`.
- Retention: `trash_ttl_days` (default 30), size-capped at 5% of the volume; oldest evicted first.
- A tombstone is a `files` row with `deleted=1`, a bumped clock, and a journal entry.
- GC of tombstones only when `seq <= min(peer.acked_seq)` **and** older than `tombstone_ttl`.
  A device that has been offline longer than the TTL must do a **full re-index** on reconnect
  rather than an incremental one (`GET /v1/folders/{id}/entries?cursor=…`), otherwise a delete
  it never saw could resurrect a file. The server detects this via `since_seq < pruned_seq` and
  replies `410 RESYNC_REQUIRED`.

This single rule prevents the classic "deleted photos came back" bug that plagues naive sync
implementations.

---

## 10. Failure and retry matrix

| Failure | Behaviour |
|---------|-----------|
| Network dies mid-`PATCH` | Client re-`GET`s offset, resumes. Bytes are never re-sent from 0. |
| Server restarts mid-batch | Batch is transactional → rolled back; client retries from `peer_seq`. |
| Response lost after apply | Retry is idempotent (clock `EQUAL` → no-op). |
| Disk full on PC | `507 INSUFFICIENT_STORAGE` + free-space telemetry; agent pauses folder, tray shows it; phone UI surfaces "PC is out of space on E:". |
| Target drive unplugged | Volume identity check fails → folder `unavailable`; transfers queue, nothing is lost. |
| Hash mismatch | `422`; discard staging, retry twice, then quarantine the item and report it. |
| Clock skew > 5 min | HLC protects ordering; a warning is logged (mtime display may look odd). |
| `410 RESYNC_REQUIRED` | Full re-index of that folder, then resume incremental. |

---

## 11. Worked examples

**E1 — Plain backup.** Phone adds `IMG_1.jpg` (never seen). Journal `seq 41 upsert`.
Server: no local record → `L.absent` → accept, request upload → verify → finalize →
journal `seq 901`. Next negotiate: phone sees `901`, marks synced. Total: 1 negotiate,
1 upload, 1 commit.

**E2 — PC deletes a backed-up file, then reruns.** `backup` folder. Server tombstones `seq 902`.
Phone receives a tombstone for a `backup` folder and **does not delete locally**; it just
advances its watermark. Phone keeps uploading new files; the old one is never re-uploaded
because the tombstone's clock dominates.

**E3 — Same photo added on both sides.** Identical bytes, same size, different names.
Different paths → two records. Both exist. Content is stored once (dedupe). No conflict,
because conflicts are path-scoped.

**E4 — `sync` folder, both edit offline.** PC edits `plan.md` at 09:00 (clock
`{pc:5, phone:2}`), phone edits at 09:05 (clock `{pc:4, phone:3}`). `CONCURRENT`, hashes
differ → WINNER by HLC = phone (newer). Phone's version keeps the name; PC's becomes
`plan (conflicted copy from DESKTOP 2026-11-13).md` with clock `{pc:6, phone:4}`. Nothing lost.

**E5 — Rename 40 GB of videos.** 200 records deleted, 200 created with new paths, all hashes
already in `blobs`. Zero bytes transferred; 400 metadata ops; PC finalizes via hardlinks.

**E6 — Phone offline for 200 days, then reconnects.** `since_seq` is below `pruned_seq` →
`410 RESYNC_REQUIRED` → phone lists the folder in pages and rebuilds. Safe because tombstones
were GC'd, so the resync is authoritative.

---

## 12. Invariants the simulator must prove (§PLAN 12)

1. **Convergence.** After quiescence, both sides hold identical `{path → hash}` maps (modulo
   trash and conflict copies, which are themselves converged files).
2. **No silent loss.** Every path that ever existed on either side is present as: live file,
   trash entry, or tombstone.
3. **Idempotence.** Re-running a fully-synced session performs zero transfers and zero writes.
4. **Determinism.** Both sides independently choose the same conflict winner and copy name.
5. **Bounded work.** A single-file change costs O(1) journal entries and at most one transfer.
6. **Crash safety.** Killing either side at any instruction yields a state that a retry converges
   from — verified with a deterministic fault-injecting scheduler, not random sleeps.

---

## 13. Open protocol questions

1. **Multi-phone (N=3+).** Vector clocks still work; conflict copies multiply. Do we aggregate
   to a "server clock" per file instead? Defer, but keep keys free-form so it's not a migration.
2. **`need_hashes` batching.** One trip per ambiguous path vs one batched call — do batched.
3. **Compression in transit?** Photos/videos are already compressed. Skip v1; revisit for text
   folders (deflate small files > 1 KB).
4. **Delta sync for >1 GB files.** Add rsync-style rolling hashes in M5 — the E5 rename trick
   already covers the common case.
5. **`/v1/folders/{id}/entries` pagination cursor.** Path-keyset vs `seq`-offset. Path-keyset is
   stable under mutation; prefer it.

---

## 14. Local UI API (PC desktop app)

Everything above is the phone ↔ agent contract. The Flutter Windows companion (`pc/`) uses a
separate, deliberately smaller surface to show the pairing code and set the backup drive. It is
**not** part of the sync protocol and a paired phone cannot reach it.

| Route | Purpose |
|-------|---------|
| `GET /local/status` | Current code, expiry, whether it is still unredeemed, pin, endpoints, chosen destination, QR bytes. |
| `POST /local/pairing/refresh` | Issue a fresh code for adding another device; returns the same envelope. |
| `GET /local/volumes` | Same drive list the phone sees (`{volumes:[…]}`). |
| `PUT /local/destination` | Same `{volume, subfolder}` choice as `/v1/system/destination`. |
| `GET /local/devices` | Paired phones (`{devices:[…]}`), newest first; each carries its backup config. |
| `DELETE /local/devices/{id}` | Revoke a paired phone and invalidate its token (`{deleted:true}`; `404 DEVICE_NOT_FOUND` if unknown). |
| `PUT /local/devices/{id}/backup` | `{volume, subfolder, enabled}` → `{device, folder}`; resolve and persist that phone's backup folder. |
| `GET /local/backups` | Per-device backup rows (`{backups:[…]}`: device id/name, folder id, volume, subfolder, root, `available`, `enabled`, `last_seen_at`). |

Paired devices and their backup folders are stored in `<data dir>/devices.json` (token digests
only). Every new phone inherits the current global destination at pairing time but gets its own
folder id, `backup-<device_id>`, and its own root config; it is pinned to that folder for uploads
regardless of the `folder_id` it sends. `PUT /local/devices/{id}/backup` repoints one phone using
the same volume/subfolder validation as the phone's destination endpoint. A backup root whose
drive is unplugged is reported `available:false` and skipped at startup rather than aborting it.
For a phone that already has a per-device folder, `PUT /v1/system/destination` (the drive picker in
the Android app) repoints **that device's** folder too; it no longer silently changes only the
global default. Only the PC's `PUT /local/destination` changes the global fallback.

Rules:

- **Loopback only.** Every `/local/*` request is rejected with `403 {error:{code:"LOCAL_ONLY"}}`
  unless the socket peer is `127.0.0.1`, `::1` or another loopback address. Checking the TCP peer
  (not a `Host` header) means a DNS name pointing at the PC cannot bypass it. A phone on the LAN
  can pair and upload, but cannot mint codes or repoint the backup folder.
- **No device token.** The desktop app *is* the local user and already has the agent's data
  directory; a bearer token would add nothing. It still pins TLS using the pin from
  `pairing.json`, so it cannot be impersonated by another process on the machine.
- **Discovery is a file, not the network.** The app reads `<data dir>/pairing.json` (written on
  every start and every refresh) to learn the pin and prefer a loopback endpoint from `eps`.
  Startup with no agent running is a friendly "start CloudBox" message, not a network scan.
- **One live code.** Startup and Refresh both go through the agent's `pairingSession`, so the QR
  image, the handoff files and `/local/status` always describe the same token. Status checks use a
  non-consuming `Valid()` lookup, so polling cannot invalidate the code being displayed.
