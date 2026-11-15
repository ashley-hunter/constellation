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

`.github/workflows/release.yml` tests, builds, signs with Developer ID, notarizes, and publishes
`Constellation.dmg` with the `appcast.xml` that installed copies check for updates. Running the
workflow by hand with no tag builds without publishing.

It reads these repository secrets: `MAC_CERTIFICATE_P12` (base64), `MAC_CERTIFICATE_PASSWORD`,
`APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` and `SPARKLE_PRIVATE_KEY`. The Sparkle
key's original is in the login keychain of the Mac that made it (`generate_keys --account
constellation -x <file>` exports it); its public half is `SUPublicEDKey` in `project.yml`.
