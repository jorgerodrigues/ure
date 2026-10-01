# Ure

A native Mac app for watch repair and restoration. The current implementation includes the native shell and W002 recoverable library. Watch records and repair features follow in the [planning backlog](docs/planning/issues.md).

## Requirements

- An Apple silicon Mac running macOS 27 or later.
- Xcode 27 or later, with the macOS 27 SDK and Swift 6.4 compiler.
- Xcode selected as the active developer directory. Check with `xcode-select -p`.

Xcode resolves the sole runtime package, [GRDB 7.11.1](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1), through Swift Package Manager. The exact version and resolved revision are committed. Xcode includes the formatter and test frameworks.

## Build and run

Open `Ure.xcodeproj`, select the shared **Ure** scheme, and run. Or use:

```sh
make run
```

Local runs use ad-hoc signing. No Apple developer account is required. App Sandbox is enabled. Hardened Runtime is configured for distribution; Xcode disables it for local ad-hoc builds. The current bundle identifier is `local.ure.app`; settle an owner-controlled identifier before distribution and before storing valuable data.

The main window contains Workshop, Watches, Calibers, Parts, and Archive. Use **Option-Command-1** through **Option-Command-5** to select a section. **Command-comma** opens Settings. Lists remain empty until watch and repair features are implemented. Startup now creates or reopens the library metadata database.

## Local library and recovery

The app resolves its Library folder inside sandboxed Application Support. Settings shows its location. `active-library.json` selects one directory under `generations/`. Each generation holds `library.sqlite`, `manifest.json`, and `originals/`. Original files and SQLite writes share one coordinator. Database access, file copies, and hashing run away from the main actor.

Startup validates the active pointer, manifest, database integrity, foreign keys, and migration history before opening a writer. Existing data is never replaced with an empty database after a failed open. The recovery screen shows the failure and library location. Retry rechecks the saved library.

Before upgrading, the coordinator creates a recovery snapshot under `recovery/`. It uses SQLite's backup API, copies originals, and records file sizes and SHA-256 hashes. It applies migrations to a new generation copied from that snapshot. The active pointer changes atomically only after validation passes. Failed migrations keep the original generation active. Old generations and recovery snapshots are retained.

Recovery copies are local protection against app failures. User-exported backups and restore controls belong to later issues. Do not keep valuable records only in this app before the Recovery and Release milestones pass.

## Verification

```sh
make lint       # Formatting and unsafe Swift constructs
make build      # Unsigned Debug build, including compiler type and concurrency checks
make release    # Unsigned optimized Release build
make test       # Swift Testing unit tests
make test-ui    # XCUITest keyboard navigation, Settings, and light/dark window launch
make test-all   # All tests
make check      # Lint, Debug build, and unit tests
```

On this development Mac, macOS 27.2 beta with Xcode 27 stalls in `clang-stat-cache`. The ignored `Config/Local.xcconfig` sets `SDK_STAT_CACHE_ENABLE = NO`. Make commands pass this optional config to app and package targets. This affects build-time file caching only. A fresh checkout on the same machine can use `make run XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`, or create the same local config. CI retains Xcode's default cache setting. Direct `xcodebuild` commands can pass `-xcconfig Config/Local.xcconfig` when the file exists.

For a focused test:

```sh
xcodebuild -project Ure.xcodeproj -scheme Ure \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -only-testing:UreTests/AppConfigurationTests \
  -resultBundlePath "$HOME/Developer/test-assets/$(git branch --show-current | tr / -)/ure-focused-$(date +%Y%m%d-%H%M%S).xcresult" \
  test
```

Test launches receive a unique temporary library location. The shared scheme sets `URE_TESTING=1`, and native test-host markers also force isolation. UI tests set the marker on each app launch. A Debug-only damaged-pointer seed requires the explicit test marker. No test opens the normal user library.

Derived data stays in the ignored `.build/` directory. Test result bundles and captures go in `~/Developer/test-assets/<branch>/`. Native UI tests require a logged-in graphical session and [Accessibility permission for Xcode Helper](https://developer.apple.com/documentation/xcuiautomation/recording-ui-automation-for-testing). Keep captures while the branch is active, then remove that branch's folder when work is complete.

## Architecture and performance

SwiftUI views render state and forward actions. Observation owns feature state. The app uses Swift 6 language mode, complete concurrency checks, approachable concurrency, and main-actor isolation by default. Immutable values explicitly opt out of actor isolation. The library coordinator is a dedicated actor. Image processing must also use dedicated actors or `@concurrent` work; an `async` function alone does not move expensive work off the main actor.

Use standard navigation, controls, and window APIs for the current macOS appearance and accessibility behavior. Keep observation close to the views that need it. Lists must use stable record IDs. Load originals only for viewers and decode thumbnails off the main actor. Add caching or extra layers only after profiling shows a need.

The Release configuration enables optimization and whole-module compilation. The shared scheme's Profile action uses Release. Use **Product > Profile** with Instruments' SwiftUI and Time Profiler tools to find expensive updates and main-thread work. The realistic library benchmarks remain W031; this empty shell does not establish their performance.

## Project context

- [Specification](docs/planning/specification.md)
- [Implementation issues](docs/planning/issues.md)
- [W001 foundation](docs/planning/issues/W001.md)
- [Setup verification and pending gates](docs/planning/setup-verification.md)
- [W002 library verification](docs/planning/library-verification.md)

The user approved the current-platform direction and W002's SQLite/GRDB design on 1 October 2026. Separate repair jobs and shared caliber knowledge remain proposed product choices. The next implementation issue is W003, which adds watch records.

The GitHub Actions workflow uses the [macOS 27 arm64 runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) and Xcode 27. It runs format/lint, Debug and Release builds, and isolated unit tests. Remote CI remains unverified until a GitHub remote is configured.

Current platform references: [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements/), [Observation](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro), [Swift concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html), and [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).
