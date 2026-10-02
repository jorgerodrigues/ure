# Watch records verification

Recorded on 2 October 2026. W003 is implemented on `w003-watch-records`. Native UI acceptance remains pending. The associated GitHub story is [#1](https://github.com/jorgerodrigues/ure/issues/1).

## Implementation

- The forward `v2-watches` migration adds identity and specification fields, UUIDs, and UTC timestamps. It uses W002's snapshot and generation-switch process. Existing metadata and original files are preserved.
- The save service validates a required name and optional finite positive dimensions. Identifiers remain text. Blank optional fields become absent values. Duplicate watch names and identifiers are allowed.
- Database reads and mutations run through the library coordinator. GRDB observation refreshes the watch list and selected detail after committed changes. Incoming records do not replace an open draft.
- Watches provides a native list, identity search, detail view, and editor. Add Watch and Cmd-N start a draft. Save and Cmd-S persist it. Cancel discards it. Field validation and write failures keep the draft.
- Record and section navigation, main-window closing, and app termination share Save, Discard, and Stay protection. Pending saves block repeated saves and navigation. A failed save cancels pending navigation or termination.
- The AppKit window adapter forwards the original SwiftUI window delegate's other callbacks and restores that delegate when removed. It defers closing until an asynchronous save succeeds. SwiftUI's [dismissal dialog](https://developer.apple.com/documentation/swiftui/view/dismissalconfirmationdialog(_:shouldpresent:actions:)) lets non-cancel actions proceed with dismissal as soon as their action returns, so it cannot directly guard a pending asynchronous write.
- No job, caliber-management, archive, condition-change, photo, or customer feature is added.

## Verification

Commands use `XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` on this development Mac. The workaround is not committed.

| Check | Result |
| --- | --- |
| `make check XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Strict formatting/lint, Debug build, and isolated unit tests passed |
| Unit cases | 46 passed, with no failures or skipped cases |
| `make release XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Unsigned optimized Release build passed |
| Focused XCUITest run | Runner failed to initialize with `Timed out while enabling automation mode.` No UI assertions ran |
| Graphical-session diagnostic | macOS reported `CGSSessionScreenIsLocked=Yes` |

Unit coverage includes name-only and complete on-disk round trips, Unicode and leading-zero identifiers, optional values, localized dimensions, invalid and nonfinite dimensions, duplicate names, missing records, timestamp preservation, committed observation, failed SQLite writes, retry, Cancel, dirty navigation, repeated saves, and migration from W002 with unchanged originals.

A later unit rerun stalled during XCTest session setup. Its process sample showed the test host waiting for the IDE session before reaching any test. Stopping the stalled runs and restarting the user's XCTest service restored the unit runner. All 46 cases then passed. This did not remove the locked-screen limit on native UI testing.

Test launches retain the shared scheme's marker and isolated temporary path. `URE_TEST_LIBRARY_ID` accepts only a UUID and only for marked test launches. It allows a restart test to reopen its own fixture. Tests cannot use it to select the normal library or an arbitrary path.

Result bundles are retained under `~/Developer/test-assets/w003-watch-records/`. The failed native run is `w003-native-ui.xcresult`.

## Remaining checks

Unlock the Mac and rerun the focused native journeys. They cover creation, Cmd-S, validation correction, Cancel, restart persistence, dirty section navigation, window closing, app termination, Settings, recovery, and both appearances. No test was removed or skipped to hide the initialization failure.

The W001 minimum-window resize gate, a macOS 27.0 run, and remote CI remain pending. The focused W003 command does not select the existing resize test. The implementation branch has not been merged into the default branch.

```sh
xcodebuild -project Ure.xcodeproj -scheme Ure \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData SDK_STAT_CACHE_ENABLE=NO \
  -parallel-testing-enabled NO \
  -only-testing:UreUITests/WatchUITests \
  -only-testing:UreUITests/WorkshopUITests/testKeyboardNavigationAndSettings \
  -only-testing:UreUITests/WorkshopUITests/testWindowLaunchesInBothAppearances \
  -only-testing:UreUITests/WorkshopUITests/testRecoveryKeepsDamagedLibraryWhenRetried \
  -resultBundlePath "$HOME/Developer/test-assets/w003-watch-records/w003-native-ui-retry-$(date +%Y%m%d-%H%M%S).xcresult" \
  test
```
