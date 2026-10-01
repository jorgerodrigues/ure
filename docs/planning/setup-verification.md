# Native foundation verification

Recorded on 1 October 2026. W001 is implemented locally. Its native UI acceptance is still pending.

## Platform

- Target: macOS 27.0 or later, Apple silicon only.
- Toolchain: Xcode 27.0, build 27A266a; Swift 6.4, Swift 6 language mode; macOS 27.0 SDK.
- Development OS: macOS 27.2 beta, build 26B5091g.
- UI: SwiftUI, Observation, native split navigation, one main window, native Settings, and keyboard commands.
- Concurrency: complete checking, approachable concurrency, main actor by default, and nonisolated immutable configuration and navigation values.
- Runtime dependencies: Apple frameworks only. The recoverable database belongs to W002.

## Completed checks

| Check | Result |
| --- | --- |
| `make lint` | Passed with strict swift-format lint and force-operation rules |
| `make build` | Unsigned Debug build passed |
| `make release` | Unsigned optimized Release build passed |
| `make check` | Format/lint, Debug build, and unit tests passed through the documented command |
| Unit cases | Six passed, including the actual native test host receiving an isolated library |
| `make run` | Passed; the locally signed app launched and remained running |
| Signature verification | `codesign --verify --deep --strict` passed for the local Debug app |
| Project files | Xcode project and entitlements passed plist validation; referenced configuration files exist |

The test cases cover production path resolution, the explicit test marker, both native XCTest markers, separate paths for independent test launches, and the native test host's actual configuration. No test opens the normal user library.

## Pending checks

`make test-all` built all test targets and passed its six unit cases. The UI runner failed to initialize with `Timed out while enabling automation mode.` None of its UI assertions ran. Keyboard navigation, Settings, resizing to the minimum size, and the two appearance checks remain pending.

Apple's [UI automation guidance](https://developer.apple.com/documentation/xcuiautomation/recording-ui-automation-for-testing) requires Accessibility access for Xcode Helper. Check that permission and retry `make test-ui` in a logged-in graphical session. If initialization still fails after authorization, diagnose the runner before treating this as an app failure.

The app was launched on the development OS. A macOS 27.0 run is pending. The GitHub Actions workflow is prepared for the macOS 27 arm64 runner, but no remote exists and no remote CI run has occurred.

The empty app shell does not verify the realistic-library performance targets. W031 must measure those with the stated dataset and Release build. Full repair and recovery journeys remain future work.

## Local toolchain issue

The default build stalled for several minutes in `clang-stat-cache`. A process sample showed its main thread waiting in `CFRunLoopRun` with no active cache work. Disabling `SDK_STAT_CACHE_ENABLE` allowed Debug, Release, and test builds to finish.

The ignored `Config/Local.xcconfig` contains that setting on this Mac. The tracked base configuration includes it only when present. The workaround changes build-time SDK file caching, not app runtime behavior. It is not applied to CI or other checkouts by default.

Xcode's App Intents metadata tool reports `Metadata extraction skipped, no AppIntents.framework dependency found`. The shell has no App Intents. Swift compilation and lint have no outstanding diagnostics. No empty App Intents implementation was added to suppress the tool message.

Local ad-hoc builds use App Sandbox. Xcode disables Hardened Runtime for ad-hoc signing. Distribution signing, an owner-controlled bundle identifier, and release acceptance remain separate work.

