# W032 first-release acceptance

First-release acceptance is **pending**. The complete isolated behavioral suite passes on the development Mac. Native tests exposed application defects and test-query defects. Their focused regressions pass. The corrected full native run passed fourteen tests before Automation Mode became disabled. Native acceptance on minimum macOS 27.0 and optimized native performance remain untested. The W031 async image-memory observation remains unresolved. Neither this report nor a green CI run declares the release complete.

Recorded on 4 October 2026 for [W032, issue #28](https://github.com/jorgerodrigues/ure/issues/28). Dependencies #25, #26, and #27 were checked closed. PRs #55, #56, and #57 were checked merged. The fixed implementation base is `cb5a15a3cd7dfb6ce6579bb063f7c3c73fedca2b` on the live default branch, `w002-recoverable-library`.

Hardware: Mac16,8, Apple M4 Pro, 48 GiB. Development system: macOS 27.2 beta, build 26B5091g. Toolchain: Xcode 27.0, build 27A266a. The proposed minimum is macOS 27.0 on Apple silicon. No minimum-OS Mac was available for local native acceptance. CI separately verified the builds and isolated unit suite on macOS 27.0, build 26A428.

## Restored gates and demonstrated fixes

CI now runs `make check XCODE_EXTRA_FLAGS='-parallel-testing-enabled NO'` and `make release` on pull requests and pushes to the actual default branch. `make check` selects only `UreTests`. Serial test execution retains every test and its internal concurrency checks. UI and device automation remain off CI. Swift 6, complete concurrency checking, and warnings as errors remain enabled. Local commands also pass `SDK_STAT_CACHE_ENABLE=NO` for the development beta's build-cache stall. CI keeps the default SDK cache settings.

The first restored CI run compiled the Debug app and test bundles on macOS 27.0, then reached its 15-minute limit without reporting test results. A diagnostic rerun was started without source changes. The local full suite passed with serial test execution, including all concurrent-write and restore-activation tests. CI now uses that setting. The original stall's cause is not established. Final CI evidence is recorded in the PR.

The first full execution found four failing test definitions. None was removed or skipped.

- Timeline history assertions compared saved text with a draft's trailing whitespace. They now compare the original saved task and part values. The later rename and deletion must still preserve the historical values.
- Photo edge panning differed by about `1e-13` points after layout. Both coordinates now use the existing test's `0.01`-point tolerance. Movement, reverse movement, edge bounds, and retained magnification still have assertions.
- PDF scale assertions mixed `Double` and `CGFloat`, which Swift Testing reported unequal despite the same numeric value. Explicit numeric conversion fixes that assertion. Execution also showed PDFKit reset the configured maximum to 100 when assigning a document. The reader now reapplies 0.1 and 8 after assignment. The regression requires the maximum to remain 8 and both zoom limits to hold.
- The WAL backup test initially opened a writable reader before checking package contents. That reader could create sidecars. The test now checks the complete package inventory first and opens a read-only reader. This exposed an actual retained shared-memory file in the staged WAL snapshot. Snapshots now require rollback-journal mode, close their writer, and remove only the disposable staged shared-memory file before hashing and publication. Live database settings and original bytes are preserved. The regression requires committed WAL records, a self-contained package, and the exported database's `delete` journal mode. See [SQLite's WAL file rules](https://sqlite.org/wal.html).

Native execution then reproduced three application defects. The watch editor assigned focus too early for keyboard creation. It now yields once in its view task before assigning Name focus and checks cancellation. Search result clicks between the title and context did nothing. A rectangular content shape now includes that gap. The native accessibility tree omitted the task-progress group's value. Its label now includes the complete progress summary. Native tests check the empty, mixed, and reopened-task summaries. Spoken VoiceOver acceptance remains pending.

An actual APFS disk-full check also found a restore preflight defect. Important-usage capacity could report zero despite physical free space. The preflight now uses the greater reported capacity. Missing capacity still rejects staging. The filesystem evidence and regression coverage are recorded below.

Correct mouse resizing exposed a window-size defect. The old 650-point content minimum produced a 702-point window with its toolbar. The main window now subtracts its measured vertical safe-area inset from the content limit. It reaches an actual 1000 × 650 frame. The toolbar remains native; its height is not hardcoded. See Apple's [content-based window sizing](https://developer.apple.com/documentation/swiftui/windowresizability) and [window frame](https://developer.apple.com/documentation/appkit/nswindow/frame) definitions.

The UI changes follow the existing native controls. Live Paper Ure screen rules were read through JSX and computed styles. The file has no document, task, search, or W032 feature page. No visual redesign, decoder optimization, new cache, package, or schema migration was added.

## Executed evidence

| Check | Result |
| --- | --- |
| `make check XCODE_EXTRA_FLAGS='SDK_STAT_CACHE_ENABLE=NO -parallel-testing-enabled NO'` | Passed formatting/lint, unsigned Debug, and all 282 unit test definitions across 49 suites; 539 executions including parameter cases, zero failures or skips |
| Entire `BackupExportTests` suite | Passed after snapshot fix; the earlier individual method filter selected zero tests and is not counted as evidence |
| `ReleaseJourneyTests` | Passed on a fresh library and the frozen v10 and v15 libraries |
| Optimized app, `make release` | Passed with the native focus, search, accessibility, restore-capacity, and window-size fixes |
| `make recovery` | Passed all 58 scenarios with the restore-capacity fix; retained run `3bde85a0-87a8-488a-9f9c-f0ab061f063b` |
| Fresh source build without local config or prior derived data | Passed `make check` and `make release` before the later native and restore-capacity fixes, in an isolated source copy with new derived data and no `Config/Local.xcconfig`; the beta cache flag was passed explicitly |
| CI on macOS 27.0 | [Run 37184716702](https://github.com/jorgerodrigues/ure/actions/runs/37184716702) passed formatting, Debug, all 280 definitions / 537 executions including parameter cases, and optimized Release on reviewed implementation `ff8044ed7960a1695b8dfedec6e2b155148b1060`; no native UI tests ran |
| Local native tests | Focused regressions passed; corrected full run had 14 passes and 11 failures after Automation Mode became disabled; results and the remaining gate are recorded below |
| Independent read-only review and final CI | Results recorded in the PR before acceptance or merge |

The full suite reports a runtime priority-inversion warning in the existing `BackupExportTests` semaphore latch. The latch deliberately blocks an export checkpoint to test concurrent reads and writes. This is test instrumentation, not a passing native responsiveness measurement. The existing AppIntents metadata-extraction notice remains. There are no Swift compiler warnings or errors.

Build and test logs stay under ignored `.build/w032/`. Review logs stay under `.build/w032-review/`. The latest passing unit result is `ure-20261004-113752.xcresult` under `~/Developer/test-assets/w032-release-acceptance/`. The folder also retains failed and interrupted results for diagnosis. Remove only that branch folder when its PR is done. Frozen W029 inputs and the retained W031 performance fixture were preserved.

## First-release journeys

`ReleaseJourneyTests` loads W029's frozen SQL, manifest, and original bytes from the test bundle. It does not recreate the historical schema with current migrations. Each run uses a new temporary library and production `LibraryCoordinator` access. The source dumps remain unchanged. Supported forward migrations run before the repair journey.

| Specification journey | Executed evidence | Remaining native evidence |
| --- | --- | --- |
| 1. Name-only watch, restart, saved record | Watch service/state tests, native creation/edit/cancel/restart, and unchanged keyboard-only long Unicode watch test passed | Complete both-appearance repair journey |
| 2. Job, notes, tasks, parts, several links, restart | Combined journey and service/state suites passed; native timeline, task, URL-only part, supplier and procurement flows passed; exact manufacturer and supplier codes and both saved URLs survive | Reopen saved URLs through explicit native Open actions |
| 3. Imported originals after source removal, offline viewing | Combined journey removes sources, restarts, decodes the photo, and reads all PDF pages from managed originals; photo/document suites also passed | Disconnect networking and use native main/reference viewers, import and export panels, security-scoped access |
| 4. Waiting job, Arrived part, task availability without status change | Combined journey, task-part/procurement suites, and native saved-selection/arrival/cancellation/unlink/restart passed | Availability refresh beside a pinned reference |
| 5. Done, Skipped, added/reopened tasks and no-task progress | Combined journey and progress/order/state suites passed; native keyboard and mouse reorder, restart, and empty/mixed/reopened accessibility summaries passed | Spoken progress with VoiceOver |
| 6. Completion with unresolved tasks and a later job | Combined journey and transition/history suites passed; native closure validation/reopening and intake/timeline/source navigation passed; first intake and outcome unchanged | Complete later-job journey in native UI |
| 7. Complete backup and isolated restore | Combined journey compares every table's saved values and every original's size/SHA-256 on fresh, v10, and v15 runs; restore suites passed | Native save/open panels, review, confirmation, export originals, recovery-copy action |
| 8. Cancellation, disk-full, corruption and interruption | Isolated fault-injection suites, retained 58-case process matrix, and actual APFS disk-full/permission checks passed | Native file panels, sandbox grants, external-volume boundaries, cancellation/recovery and rollback permission failure |
| 9. Keyboard, VoiceOver, light/dark | Native watch navigation Save/Discard/Stay, validation failure and restart, and close/quit draft protection passed | Complete keyboard workflow, VoiceOver, remaining window/appearance/accessibility settings |

The combined journey captures every saved table after restart and compares it with the isolated restored library. It checks that older fixture rows survive, links retain their exact URLs, waiting-task state stays unchanged after arrival, skipped tasks leave the progress denominator, reopening reduces progress, and a second job leaves the completed repair intact. It checks all backup and restored originals against saved SHA-256 and sizes. The backup manifest remains unchanged after restore. These are domain/storage checks. They do not replace native acceptance.

## Native run and remaining checklist

The initial partial run could not establish the cause of the keyboard failure. Two uninterrupted reproductions also failed. The watch editor requested focus before its text field was mounted. It now yields once in its view task before assigning focus and rejects a cancelled task. The unchanged keyboard test then passed three consecutive executions. Its result is `keyboard-minimal-focus-20261004.xcresult`.

The subsequent complete run executed all 25 native tests. Twelve passed and thirteen failed, with 25 failed assertions or actions. Its result is `ure-20261004-102231.xcresult`. The exported control trees and recordings are retained for diagnosis. This failed run is not acceptance evidence for the remaining tests. Application fixes and test corrections are recorded with their focused rerun results below.

The tests also had defects that concealed or misreported outcomes. Native combined text stores content in its value. Timeline text could appear as both a parent and a child. Queries now target exact source buttons, saved row IDs, or the appropriate value. The no-results query follows the system's actual combined search message and requires zero result buttons. Removal confirmation is scoped to its sheet because the Touch Bar also contains Remove. Supplier fields and task rows scroll fully into view before input. Edit Job uses its keyboard command when native toolbar overflow hides the button. No test was removed or skipped.

The task-drag predicate previously matched the group label Testing on every row. It now requires the exact moved task ID before and after restart. Both task dragging and window resizing used the SDK's touch gesture. The corrected tests use its mouse-drag API. Window acceptance requires both dimensions to reach the minimum range; a no-op resize cannot pass.

Focused reruns passed reference-window draft preservation, task validation/closure/restart, timeline/source routing, procurement corrections and restart, duplicate-note search with Save/Stay, saved task-part availability, watch creation/edit/cancel/restart, Parts overview routing, keyboard watch creation, and Workshop filter/edit routing. The retained results are `navigation-fixes-20261004.xcresult` and `native-regressions-20261004.xcresult`. These are partial reruns. The latter still used the old drag gestures and unscoped removal confirmation. Their corrected rerun is tracked separately.

The proper mouse drag passed exact task ordering, persisted ordering after restart, and progress after reopening a Done task. Sheet-scoped supplier removal passed both cancellation and saved removal. These results are in `native-mouse-fixes-20261004.xcresult`; its resize case still exposed the 702-point frame. The subsequent `native-window-insets-20261004.xcresult` passed both the URL-only part journey with scrolling and the actual 1000 × 650 window after the sizing fix.

The corrected complete run is `ure-20261004-111530.xcresult`. All fourteen archive, caliber, job, part, and Parts overview tests passed. Search then lost its accessibility connection during setup. The ten subsequent tests failed before behavioral checks with `Not authorized for performing UI testing actions`. The result is fourteen passes, eleven failures, and no skips. It is not a passing native suite.

The system log recorded an Automation Mode state-change notification at 11:34:36. At 11:34:38 the app rejected the automation connection because Automation Mode was disabled. The cause of that state change is unknown. A fresh runner then timed out while enabling automation mode before any native checks ran. `/usr/bin/automationmodetool status` confirms that Automation Mode is disabled and requires user authentication. The full rerun is blocked until that authentication is complete. The added minimum-window watch and caliber editor checks compile but remain unexecuted; the earlier basic window-size check passed.

Actual storage checks used a disposable 2 GiB APFS disk image. The driver filled it with 2,100,297,728 bytes until the filesystem returned ENOSPC. PDF import, replacement backup export, and restore staging then failed safely. A source file with permissions removed also rejected import. Each failure preserved all twelve tables, database integrity and foreign keys, the library pointer, every original's bytes, size and SHA-256, and the prior complete backup. After space was freed, reopening twice, import, export, and restore all succeeded. The volume was unmounted after verification. The retained summary is `.build/w032/storage-results/summary.json`.

The storage run also reproduced a restore preflight defect. Foundation reported zero important-usage capacity on the image while the volume still had physical free space. Restore now uses the greater of physical free space and important-usage capacity. Missing capacity still fails closed. Regression tests cover physical space with a zero important-usage result, a truly full volume, purgeable capacity, and unavailable capacity. These filesystem checks do not establish native panel or sandbox-grant acceptance.

Carry these gates from all earlier verification reports into the next acceptance pass. Older reports remain historical evidence; this checklist owns their current pending status.

- [ ] Finish the complete corrected native suite with `URE_TESTING=1` and an isolated library. Focused watch/caliber, job, tasks, parts/suppliers, workshop/parts overview, search, timeline, and archive/removal flows passed. The complete run must also pass exact-record targeting, failed-save retention, and editor controls at the actual minimum window size.
- [ ] Complete [W030's keyboard and accessibility checklist](keyboard-access-verification.md): all create/edit/reference/backup/restore flows without a pointer; VoiceOver labels, selection and honest progress; long text; 1000 × 650 and large windows; both appearances; inactive windows; increased contrast, larger system text, Reduce Motion, Reduce Transparency, and both glass-opacity settings.
- [ ] Check photo focus, panning, fit/zoom, adjacent photos; PDF focus, page navigation and zoom; read-only reference-window command permissions; scrolling to every reference action. Check fit and decode orientation, color, PNG transparency and HEIC with native viewers.
- [ ] Finish navigation, main-window close, and quit Save/Discard/Stay combinations. Verify failed Save preserves text and exact selection. Escape from the guard must Stay. Closing the reference window must preserve a main-window draft.
- [ ] Complete [W029's native recovery and storage gates](process-recovery-verification.md) and [backup export](backup-export-verification.md), [restore staging](restore-staging-verification.md), and [restore activation](restore-activation-verification.md) panel journeys. Include damaged opens, sandbox grants, external volume, cancellation, actual storage/permission failures, rollback failure and complete-generation recovery.
- [ ] Run the full repair and backup/restore journey in native UI against fresh and upgraded isolated libraries. Disconnect networking for saved photos/PDFs. Verify original export bytes and restored records.
- [ ] Measure optimized native usable-window time against 3 seconds and native warm list/search response against 300 ms using the unchanged W031 fixture. Record cache state, hardware, build mode, scrolling and task input while thumbnails decode. CLI data-layer timings are not native timing evidence.
- [ ] Profile native allocations in main and reference photo viewers during open, adjacent navigation and close. Explain W031's async worker growth to about 1.9 GiB after 20 large originals, including about 1.53 GB after warmup. Its retainer and native lifetime remain unknown. No speculative product image fix was retained. Preserve the fixture and baseline summaries; compare any demonstrated fix on the same fixture and optimized mode.
- [ ] Run on minimum macOS 27.0, or keep that gate explicitly pending. Development beta evidence cannot establish minimum-OS acceptance.

The [handover guide](../handover.md) covers build/launch, entering a repair, the sandbox library location, backups, and disposable restore testing. Its native file-panel and launch sequence remains part of the pending checklist. No App Store submission, notarization account change, updater, or cloud service is included. W032 is the last planned story. Keep issue #28 open until the acceptance evidence is complete.
