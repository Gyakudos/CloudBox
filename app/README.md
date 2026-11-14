# CloudBox Android app

Flutter app. **Not scaffolded yet** — this directory intentionally has no platform shells until
the Flutter SDK is available on the build machine.

## Bootstrap

Run once, from this directory, to generate `android/`, `ios/` and the Gradle project:

```sh
flutter create --org dev.cloudbox --project-name cloudbox --platforms android .
```

Review the generated `pubspec.yaml` afterwards — `flutter create` will overwrite ours — and re-apply
the settings below.

## Version wiring

`lib/core/gen/version.dart` is generated from the repository's `VERSION` file by
`eng/version.ps1` and must never be hand-edited. It is the authoritative version string for
the app UI (About screen, support reports, logs).

`flutter create` derives `versionName`/`versionCode` from `pubspec.yaml`, which cannot express
the five-part scheme. Override both in `android/app/build.gradle.kts` so the installed APK
always matches the file tree:

```kotlin
android {
    defaultConfig {
        // Single source of truth: ../VERSION (0.01.13.11.26)
        val cloudboxVersion = rootProject.file("../VERSION").readText().trim()
        versionName = cloudboxVersion
        versionCode = (cloudboxVersion.split(".").let { p ->
            (p[4].toInt() * 10000) + (p[3].toInt() * 100) + (p[2].toInt())   // YYMMDD
        })
    }
}
```

Keep `pubspec.yaml`'s `version:` field in sync with the mirror value printed by
`eng/version.ps1` (`0.1.13+261113` for this release) - pub's parser rejects the real version
because of the leading zero in `01`.

## Layout

```
lib/
├─ core/
│  ├─ gen/version.dart      generated — do not edit
│  ├─ protocol/             sync-protocol client (pairing, negotiate, blobs)
│  ├─ crypto/               TLS pinning, token storage
│  └─ db/                   drift schema
├─ features/
│  ├─ setup/                QR pairing, drive picker, source selection
│  ├─ library/              sources, progress, transfer history
│  └─ settings/
└─ sync/                    orchestrator, planner, journal
```
