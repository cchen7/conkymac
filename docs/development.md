# Development

## Requirements

- Apple Silicon Mac
- Xcode with the Swift 6 toolchain. The deployment target is macOS 14.

There are no package dependencies. Lua 5.4.9 is vendored in `Sources/CLua`.

## Layout

```
Sources/
  ConkyMac/          App, windows, native themes, conky.text renderer, Lua theme host, CLI
  ConkyMacCore/      Collectors, snapshots, sampling, conky.text parser and variables
  ConkyLuaBridge/    Lua host and the CoreGraphics cairo subset (C)
  CLua/              Lua 5.4.9, unmodified
  CSystemPrivate/    SMC and IOReport declarations
Tests/
  ConkyMacCoreTests/   Metrics, sensors math, conky.text parsing and formatting
  ConkyMacTests/       conky.text layout (renderer)
  ConkyLuaBridgeTests/ Lua sandbox, config loading, cairo drawing (pixel checks)
  Fixtures/            Test themes: lua/arcs, lua/text, conkytext/basic
Resources/           Info.plist, app icon (SVG source and .icns)
scripts/             Build, test, validation and packaging scripts
```

## Scripts

All scripts are zsh. They keep SwiftPM's caches and build products in `CONKYMAC_BUILD_DIR` (default `/private/tmp/conkymac-build`), so the repository stays clean.

| Script | What it does |
| --- | --- |
| `scripts/swift.sh <action> [args]` | Runs `swift <action>` with the isolated build directory, e.g. `zsh scripts/swift.sh test -c release`. |
| `scripts/build-app.sh` | Release build, then assembles and ad-hoc signs `$CONKYMAC_BUILD_DIR/ConkyMac.app`. |
| `scripts/validate.sh [--gui]` | Tests, app build, 1×/2× renders, a 5-sample live probe checked by `check-samples.py`; with `--gui`, also a 15-sample GUI smoke run. Results go to `CONKYMAC_RESULTS` (default `/private/tmp/conkymac-validation`). It exits non-zero if any metric is unavailable. |
| `scripts/make-icon.sh` | Regenerates `Resources/AppIcon.icns` from `Resources/AppIcon.svg`. |
| `scripts/package-dmg.sh` | Builds the signed, notarized DMG (see below). |

## Testing

```sh
zsh scripts/swift.sh test -c release
```

The tests use Swift Testing. XCTest's "Executed 0 tests" lines in the output are expected.

Run the bridge tests under AddressSanitizer and UndefinedBehaviorSanitizer after changing C code:

```sh
CONKYMAC_BUILD_DIR=/private/tmp/conkymac-build-asan \
  zsh scripts/swift.sh test -c debug --sanitize=address --sanitize=undefined --filter ConkyLuaBridgeTests
```

### Deterministic renders

`--render` draws a theme from `Snapshot.fixture` at a fixed time (UTC 2026-05-06 14:17:00, also for Lua's `os.date` and `os.time`), with `${updates}` set to 100. Repeated renders of the same build are byte-identical, which makes visual changes easy to spot:

```sh
BIN=$(zsh scripts/swift.sh build -c release --show-bin-path)/ConkyMac
$BIN --render /tmp/simple-plus.png --theme simple-plus
$BIN --render /tmp/text.png --theme Tests/Fixtures/lua/text/text.conf
```

The screenshots in `docs/images/` are produced this way. System font rasterisation can change between macOS versions.

### Third-party themes

Do not commit third-party Conky themes unless their license allows it. Many published themes have no license at all. Test them from a local folder with `--theme /path/to/theme.conf`.

## Releasing

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, and add an entry to `CHANGELOG.md`.
2. One-time setup:
   - The keychain must hold exactly one "Developer ID Application" certificate, or set `CONKYMAC_SIGN_IDENTITY`.
   - Store notarization credentials with `xcrun notarytool store-credentials conkymac-notary --apple-id <Apple ID> --team-id <Team ID>`. The app-specific password is entered interactively. Set `CONKYMAC_NOTARY_PROFILE` to use another profile name.
3. Run `zsh scripts/package-dmg.sh`. It builds an arm64-only app with the hardened runtime and no entitlements, notarizes and staples the app, then builds, notarizes and staples the DMG. The output is `$CONKYMAC_DIST_DIR/ConkyMac-<version>.dmg` (default `$CONKYMAC_BUILD_DIR/dist`).
   - `CONKYMAC_SIGN_IDENTITY=-` rehearses the whole pipeline with an ad-hoc signature and no notarization.
4. Tag the release (`git tag -a vX.Y.Z`), push the tag, and attach the DMG and its SHA-256 to a GitHub release.
