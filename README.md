# Ure

A native Mac app for watch repair and restoration. The current implementation includes the native shell, recoverable library, watch records, shared caliber records, job intake with repair history, scoped notes, and technical reference links. Further repair features follow in the [planning backlog](docs/planning/issues.md).

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

The main window contains Workshop, Watches, Calibers, Parts, and Archive. Use **Option-Command-1** through **Option-Command-5** to select a section. **Command-comma** opens Settings. Startup creates or reopens the local library. Watches and Calibers have saved-record lists and editors. Other sections remain empty until their features are implemented.

## Watch records

Use **Add Watch** in Watches or **Command-N** to create a record. Only a name is required. Optional identity and specification fields remain unknown until entered. Serial numbers and case references preserve leading zeros and punctuation. Case diameter and lug width use millimetres and must be finite positive numbers.

Use **Save** or **Command-S** to commit the draft. **Cancel** discards it. Changing records or sections, closing the main window, and quitting with unsaved changes offer Save, Discard, or Stay. A failed save keeps the draft and reports the error. Saved changes refresh the list and detail. The list search filters watch identity fields. Change physical condition through an open job. Photos belong to later issues.

## Shared caliber records

Use **Add Caliber** in Calibers or **Command-N** while that section is selected. Only the exact designation is required. Variant and manufacturer remain separate fields. Unknown numeric specifications stay empty. Beat rate and lift angle must be finite and positive. Jewel count and nominal power reserve may also be zero. Add a source note for technical claims. The library starts without seeded caliber facts.

Select a caliber in the watch editor, or choose **Unknown** to clear its link. Several watches can share one caliber. Its saved specifications appear in each linked watch's detail. The caliber detail lists linked watches and opens their records. Clearing one link preserves the caliber and all other watch links. Caliber editing uses the same Save, Cancel, Command-S, and draft protection as watch editing. Shared notes are available in the caliber detail. Technical reference links are available in the caliber detail. Technical files follow in their own issues.

## Job intake and repair history

Use **Start Job** in a watch's repair history. Only a job title is required. Reported problem, agreed scope, intake condition, and owner contact details are optional. Email and phone accept free text. Save creates a Planned job and copies the saved watch identity and exact caliber designation and variant into a versioned intake snapshot. Later watch or caliber edits leave this snapshot unchanged.

Use **Edit Intake** to correct an open job's intake, including its identity snapshot. Those corrections apply to that job only. Job editing uses Save, Cancel, Command-S, and the existing draft protection. A failed write preserves the draft. Cancelling a new intake creates no history entry.

A watch can have several repair jobs, with at most one open job. **Open Job** returns to that existing job. The database also enforces the rule when save requests compete. The watch's history opens earlier jobs for reading. **Back to Watch** returns to its identity and history. Job notes are available in the job detail. Tasks, parts, and files follow in their own issues.

Use **Change Stage** for Planned, In progress, Waiting, Ready, Completed, or Cancelled. Waiting requires a reason. Completed requires an outcome and accepts optional recommendations. Cancelled requires a reason. Ready means ready for final review. Closing locks operational edits. **Reopen Job** selects an open stage and checks that no other job is open for this watch.

Use **Change Condition** to record Unknown, Running, Running poorly, Stopped, or Disassembled with an optional note. Condition and job stage remain independent. Both forms use Save, Cancel, Command-S, and draft protection. Successful changes retain prior and next values in history. History display follows in W019.

## Scoped notes

Use **Add Note** in a watch, job, or caliber detail. Each note belongs to that scope only. Select a saved note to read its full text and dates. A caliber note is shared knowledge in that caliber. It is never copied into a watch or job.

Enter a title, plain text, a kind, and an occurred date. Kinds are Observation, Research, Work log, and Measurement. Measurement uses the same plain-text editor. Text preserves Unicode, line breaks, and spacing. No rich text, HTML rendering, or structured instrument fields are added.

Use **Save**, **Cancel**, or **Command-S**. Editing text keeps the occurred date unless you change it. Created and updated times are separate. Failed saves keep the draft. Switching notes, records, or sections, closing the window, and quitting use the existing Save, Discard, or Stay guard. Closed-job notes remain readable. **Add Note** and **Edit Note** are disabled until the job is reopened. The service also rejects closed-job saves, including an editor opened before closure.

## Technical reference links

Use **Add Link** in a watch, job, or caliber reference section. Each link belongs to that scope only. Enter a title and a complete HTTP or HTTPS URL. Add optional source description and plain-text notes to keep the evidence in context. Several links can coexist in each scope.

Use **Save**, **Cancel**, or **Command-S**. Invalid URLs and failed writes keep the draft. Reference drafts use the existing Save, Discard, or Stay guard for navigation, window closure, and quitting. Closed-job references remain readable. Reopen the job before adding or editing its links.

Select a saved link to read its details. **Open in Browser** opens its saved URL in the default browser. Links are labelled **External reference**. Their linked content is not saved offline. Loading, selecting, and saving do not open a browser or fetch the page.

## Managed original import infrastructure

W009 ([PR #36](https://github.com/jorgerodrigues/ure/pull/36)) adds the internal `FileImportService` API for JPEG, PNG, HEIC, and PDF originals. The approved limits are 100 MB (100,000,000 bytes) per original and 200 files per batch. It detects content rather than trusting extensions, keeps unchanged original bytes, and stores file size, SHA-256, dimensions, and orientation. Each import uses a generated storage key. Source filenames stay metadata only. Cancellation and per-file failures preserve committed assets. Startup recovery removes unreferenced interrupted imports through the coordinator's mutation gate. Photo and PDF import controls follow in W010 and W011.

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
make check      # Full lint, Debug build, and unit tests; deferred CI gate at W032
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

Test launches receive a unique temporary library location. The shared scheme sets `URE_TESTING=1`, and native test-host markers also force isolation. UI tests set the marker on each app launch. A valid UUID in `URE_TEST_LIBRARY_ID` lets a marked restart test reuse its own temporary library. It cannot select an arbitrary path or affect an unmarked launch. A Debug-only damaged-pointer seed requires the explicit test marker. No test opens the normal user library.

Derived data stays in the ignored `.build/` directory. Test result bundles and captures go in `~/Developer/test-assets/<branch>/`. Native UI tests require a logged-in graphical session and [Accessibility permission for Xcode Helper](https://developer.apple.com/documentation/xcuiautomation/recording-ui-automation-for-testing). Keep captures while the branch is active, then remove that branch's folder when work is complete.

## Architecture and performance

SwiftUI views render state and forward actions. Observation owns feature state. The app uses Swift 6 language mode, complete concurrency checks, approachable concurrency, and main-actor isolation by default. Immutable values explicitly opt out of actor isolation. The library coordinator is a dedicated actor. Image processing must also use dedicated actors or `@concurrent` work; an `async` function alone does not move expensive work off the main actor.

Use standard navigation, controls, and window APIs for the current macOS appearance and accessibility behavior. Keep observation close to the views that need it. Lists must use stable record IDs. Load originals only for viewers and decode thumbnails off the main actor. Add caching or extra layers only after profiling shows a need.

The Release configuration enables optimization and whole-module compilation. The shared scheme's Profile action uses Release. Use **Product > Profile** with Instruments' SwiftUI and Time Profiler tools to find expensive updates and main-thread work. The realistic library benchmarks remain W031; this empty shell does not establish their performance.

## Project context

- [Specification](docs/planning/specification.md)
- [Implementation roadmap](docs/planning/issues.md)
- [GitHub issues](https://github.com/jorgerodrigues/ure/issues)
- [W001 foundation verification and pending gates](docs/planning/setup-verification.md)
- [W002 library verification](docs/planning/library-verification.md)
- [W003 watch verification and pending native UI acceptance](docs/planning/watch-verification.md)
- [W004 caliber verification](docs/planning/caliber-verification.md)
- [W005 job intake verification](docs/planning/job-verification.md)
- [W006 job stages and watch condition verification](docs/planning/job-stage-verification.md)
- [W007 scoped notes verification](docs/planning/note-verification.md)
- [W008 technical references verification](docs/planning/reference-verification.md)
- [W009 managed file import verification](docs/planning/file-import-verification.md)
- [Design: brand, app icon, and macOS 27 screen rules](docs/design/README.md)

The user approved the current-platform direction and W002's SQLite/GRDB storage design on 1 October 2026. Shared caliber records and the repair history rule were approved on 2 October 2026. Watch, caliber, intake, stage, and condition forms use explicit Save and Cancel editing. W003, W004, and W005 are merged through [PR #29](https://github.com/jorgerodrigues/ure/pull/29), [PR #31](https://github.com/jorgerodrigues/ure/pull/31), and [PR #32](https://github.com/jorgerodrigues/ure/pull/32). W006 is merged in [PR #33](https://github.com/jorgerodrigues/ure/pull/33). W007 is merged in [PR #34](https://github.com/jorgerodrigues/ure/pull/34). W008 is implemented in [PR #35](https://github.com/jorgerodrigues/ure/pull/35). Native UI and device checks are deferred to release acceptance by agreement. GitHub holds story descriptions, acceptance criteria, and current status. The repository holds the specification and verification evidence.

The GitHub Actions workflow uses the [macOS 27 arm64 runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) and Xcode 27. During rapid implementation, it runs `make lint` and `make build` only. Unit test execution and the Release build return to CI in [W032 (#28)](https://github.com/jorgerodrigues/ure/issues/28) before first-release acceptance. Release builds are not required for each story during this phase. Keep behavioral tests current and compile affected tests when needed. The [GitHub remote](https://github.com/jorgerodrigues/ure) is configured. Native UI and device checks run locally during release acceptance and never on CI.

Current platform references: [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements/), [Observation](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro), [Swift concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html), and [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).
