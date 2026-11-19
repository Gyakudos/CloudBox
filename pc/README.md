# CloudBox PC

The Flutter Windows companion app for CloudBox. It shows the agent's live pairing code/QR and
lets you choose which drive receives your phone's backups — the PC-side setup flow that used to
live only in the agent's terminal banner.

## How it finds the agent

The app reads `<data dir>\pairing.json` (by default `%APPDATA%\CloudBox`) to learn the agent's
certificate pin and a loopback endpoint. It never scans the network. It then talks to the agent's
loopback-only `/local/*` API over pinned HTTPS — see [`../docs/sync-protocol.md`](../docs/sync-protocol.md#14-local-ui-api-pc-desktop-app).

If the agent is not running, the app shows a "start CloudBox" message rather than a blank screen.

## Development

```powershell
flutter analyze
flutter test
flutter build windows
```

The built executable lands in `build\windows\x64\runner\Release\cloudbox_pc.exe`.

`lib/core/gen/version.dart` is generated from the repository `VERSION` file by
`eng/version.ps1`; never edit it by hand. The certificate pinning code mirrors
`../app/lib/core/pinning.dart` — keep the two in sync.
