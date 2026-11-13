# ADR 0001 — Version scheme

- **Status:** Accepted
- **Date:** 2026-11-13
- **Deciders:** project owner

## Context

CloudBox is a pre-release, single-developer project that ships two artifacts on independent
cadences: a Go PC agent and an Android app. While the feature set is still moving, the most
useful thing a version string can tell us is *how old is this build*, not which API generation
it belongs to. Android also imposes a hard constraint: `versionCode` must be a monotonically
increasing integer, and installs with a lower code are rejected.

Semantic versioning answers "is this a breaking change?" — a question nobody is asking yet.
A date answers "is this newer than the build I have?" — which is asked constantly during
pre-alpha dogfooding.

## Decision

The version is **`MAJOR.MINOR.DD.MM.YY`**, zero-padded, exactly five dot-separated parts:

```
0.00.13.11.26
│ │  └─┴─┴── 2026-11-13  (day . month . two-digit year)
│ └───────── minor: 00 for the whole pre-alpha, reserved for protocol generations
└─────────── major: 0 until the protocol is frozen and v1 ships
```

- `MAJOR` stays `0` while the sync protocol may break between builds.
- `MINOR` is `00` throughout pre-alpha. It is not a build counter — it is held in reserve so
  that a breaking protocol change can be signalled as `0.01.…` without touching `MAJOR`.
- The date is the day the version is *cut*, in the owner's local time. No timezone arithmetic,
  no UTC conversion — a version is a label, not a timestamp.
- The date is encoded as day, then month, then year (`DD.MM.YY`) because that is the ordering
  the owner reads and writes.

`VERSION` at the repository root is the **single source of truth**. Everything else is
generated or derived:

| Artifact | Value for `0.00.13.11.26` | Mechanism |
|----------|---------------------------|-----------|
| `VERSION` | `0.00.13.11.26` | hand-edited, the only editable copy |
| git tag | `v0.00.13.11.26` | annotated tag at release |
| Go `version.Version` | `0.00.13.11.26` | `agent/internal/version/generated.go` |
| Dart `kCloudBoxVersion` | `0.00.13.11.26` | `app/lib/core/gen/version.dart` |
| Android `versionName` | `0.00.13.11.26` | read from `VERSION` by Gradle |
| Android `versionCode` | `261113` | `YYMMDD` = `26 11 13` |
| Dart `pubspec.yaml` version | `0.0.13+261113` | pub requires strict semver |

Generated files are produced by `eng/version.ps1`. CI runs `eng/version.ps1 -Check` and fails
if a generated file has drifted from `VERSION`.

## Consequences

**Good**

- Build age is legible at a glance, in the tray, in logs, and in the app's About screen.
- `versionCode` is monotonic without a separate counter to maintain, and sorts correctly.
- One file to edit per release; drift is caught by CI rather than by a user reporting a
  mismatched build.

**Bad / accepted**

- The string does **not** sort lexicographically across month and year boundaries
  (`0.00.05.12.26` < `0.00.13.11.26` is false). Ordering authority is the git tag and
  `CHANGELOG.md`, not `sort`.
- `versionCode` has day granularity, so **at most one installable release per day**. A second
  build on the same day reuses the code and is not installable over the first. Pre-release
  local builds must therefore use a distinct code (e.g. `+$versionCode` plus a hand-set
  `--build-name`), or simply not be installed over a shipped build.
- `MAJOR.MINOR` is nearly meaningless until v1; expect the date to do all the work.
- Dart's `pubspec.yaml` cannot express the five-part version (pub enforces
  `major.minor.patch+build` with no leading zeros), so the authoritative string lives in the
  generated Dart constant and Android `versionName`, while pubspec carries a lossy mirror.

## Alternatives considered

| Option | Why rejected |
|--------|--------------|
| Strict SemVer (`0.1.0`) | Requires deciding what "breaking" means for a two-artifact pre-alpha; adds a decision per commit and communicates nothing useful to a single developer. |
| Calendar versioning `YYYY.MM.DD` (`2026.11.13`) | Valid — rejected only because the owner specified the `0.00.DD.MM.YY` layout. Equivalent information. |
| Build number only (`build 42`) | Loses the date; hard to reason about a build found on an old phone. |
| Git-describe (`0.00.13+3-gabc1234`) | Excellent for CI provenance, poor for store display. Kept as a *supplement* via `version.Commit`, not as the primary string. |

## When this should be revisited

Revisit when the first public release is cut: a shipped `1.0.0` communicates a protocol and UX
commitment that a date cannot. The intended transition is `MAJOR.MINOR.DD.MM.YY` during
pre-alpha → `MAJOR.MINOR.PATCH` from v1.0.0, keeping the date in `CHANGELOG.md`.
