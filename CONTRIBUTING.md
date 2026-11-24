# Contributing to Deckhand

Thanks for your interest in improving Deckhand.

## Setup

- Xcode 26+ with the Swift 6 toolchain
- Build the core package: `cd DeckhandCore && swift build`
- Run tests: `cd DeckhandCore && swift test`
- Open the app: `open Deckhand.xcodeproj`

## Workflow

1. Fork and create a branch: `feat/<scope>-<description>` or `fix/<scope>-<description>`
2. Keep changes focused; add tests for new behavior in `DeckhandCore/Tests`
3. Run `swift test` and make sure CI passes
4. Open a PR against `main` and fill in the template

## Guidelines

- Device logic belongs in the `DeckhandCore` package with unit tests; the app target is views only
- Test parsers against real CLI output fixtures (watch for CRLF from `adb emu` console replies)
- Swift 6 strict concurrency; no new compiler warnings
- Commit format: `<type>(<scope>): <description>` (e.g. `fix(core): handle offline adb serials`)

## Reporting bugs

Use the bug report issue template and include your macOS version, Xcode version, and Android SDK location.

## Releasing

Releases are built, signed, notarized and published by `.github/workflows/release.yml`.

- **Tag push** (`git tag v1.2.0 && git push --tags`) builds that tag and publishes a GitHub release.
- **Actions → Release → Run workflow** with *release* ticked bumps the version (`patch`, `minor` or `major`), builds, pushes the bump commit and tag, and publishes the release. With *release* unticked it only builds and uploads the zip and dmg as a workflow artifact (unsigned when the secrets below are missing).

Release notes are the matching `## [x.y.z]` section of `CHANGELOG.md`, or GitHub's generated notes when there is none.

Repository secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | base64 of the *Developer ID Application* `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `APPLE_CERTIFICATE_PASSWORD` | password of the `.p12` |
| `APPLE_IDENTITY_ID` | signing identity, e.g. `Developer ID Application: Name (TEAMID)` (optional, the first Developer ID identity in the `.p12` is used when empty) |
| `APPLE_ID` | Apple ID e-mail used for notarization |
| `APPLE_PASSWORD` | app-specific password for that Apple ID |
| `APPLE_TEAM_ID` | 10 character team id |
