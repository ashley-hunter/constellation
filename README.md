<img src="assets/icon.svg" width="64" height="64" alt="">

# Constellation

A Mac desktop of agent sessions. Each Claude Code or Codex session is a card, and the ones that
need you come to the front.

## Install

1. Download [Constellation.dmg](https://github.com/ashley-hunter/constellation/releases/latest/download/Constellation.dmg)
   from the latest release.
2. Open it and drag Constellation into Applications.

Needs macOS 27 on Apple silicon, plus [Claude Code](https://claude.com/claude-code) or
[Codex](https://github.com/openai/codex) installed. Constellation updates itself: it checks for a
new release once a day, or choose **Constellation > Check for Updates…**.

## Build from source

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
open Constellation.xcodeproj
```

Run the Constellation scheme. Tests for the core live in the Swift package:

```sh
cd Packages/ConstellationKit && swift test
```

A debug build signs with the `Apple Development` identity of team `3A4A3D69L8`. Building under
another team, set `DEVELOPMENT_TEAM` in `project.yml`, or `CODE_SIGN_IDENTITY: "-"` to sign ad-hoc.

## Releasing

Push a version tag:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

The release workflow builds, notarizes and publishes `Constellation.dmg`, and installed copies
pick it up as an update.
