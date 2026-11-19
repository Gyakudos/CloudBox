# CloudBox Android app

The Flutter client. Pairs with the PC agent over pinned TLS, lists the agent's drives, and sends
the files you pick to the drive you choose over a resumable, hash-verified transfer.

## Build & test

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release        # → build/app/outputs/flutter-apk/app-release.apk
```

From the repository root, `pwsh eng/build-apk.ps1` stages the APK as
`dist/cloudbox-<version>.apk`. CI pins Flutter **3.47.8** so a moving `stable` cannot break
`flutter analyze` between releases.

## Version wiring

`lib/core/gen/version.dart` is generated from the repository's `VERSION` file by
`eng/version.ps1` and must never be hand-edited. It is the authoritative version string for the
app UI (About screen, support reports, logs).

The five-part scheme cannot be expressed in `pubspec.yaml` (strict semver) or Gradle, so
`android/app/build.gradle.kts` reads `VERSION` directly and derives both values, and
`eng/version.ps1 -Check` verifies they agree:

```kotlin
android {
    defaultConfig {
        // Single source of truth: ../../VERSION (0.01.15.11.26). The Gradle root project is
        // android/, so the repository root is two levels up.
        val cloudboxVersion = rootProject.file("../../VERSION").readText().trim()
        versionName = cloudboxVersion
        versionCode = cloudboxVersion.split(".").let { p ->
            require(p.size == 5) { "VERSION must be MAJOR.MINOR.DD.MM.YY, got $cloudboxVersion" }
            (p[4].toInt() * 10000) + (p[3].toInt() * 100) + p[2].toInt()   // YYMMDD
        }
    }
}
```

Keep `pubspec.yaml`'s `version:` field in sync with the mirror value printed by
`eng/version.ps1` (`0.1.15+261115` for this release) — pub's parser rejects the real version
because of the leading zero in `01`.

## Layout

```
lib/
├─ core/
│  ├─ gen/version.dart      generated — do not edit
│  ├─ agent_client.dart     pinned-TLS client; implements UploadApi
│  ├─ upload_api.dart       interface the transfer engine talks to (test seam)
│  ├─ transfer.dart         Flutter-free transfer engine (resume, dedupe, cancel)
│  ├─ hashing.dart          streaming BLAKE3-256 (the protocol's content ID)
│  ├─ models.dart           wire models: volumes, tickets, status, commit results
│  ├─ pinning.dart          SPKI pin extraction and verification
│  ├─ pairing_payload.dart  parse/validate the agent's pairing code
│  └─ update_checker.dart   check GitHub Releases for a newer pre-release build
└─ ui/
   ├─ pair_screen.dart      scan a QR or paste the pairing code, pair over pinned TLS
   ├─ qr_scan_screen.dart   camera scanner using mobile_scanner
   ├─ update_button.dart    header Update button and release dialog
   ├─ drives_screen.dart    list drives; "Use this drive" sets the destination
   └─ send_screen.dart      pick files and watch the upload progress
```

## Android build notes

- `android/gradle.properties` sets `kotlin.incremental=false`: Kotlin's incremental compiler
  aborts when the pub cache (`C:`) and the project (`F:`) sit on different Windows drives
  (KT-57286).
- The release APK is debug-signed until release signing is configured.
