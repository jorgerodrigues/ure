# W032 first-release acceptance

First-release acceptance is **pending**. The complete isolated behavioral suite passes on the development Mac. Native acceptance stopped after desktop interference. Minimum macOS 27.0 and optimized native performance remain untested. The W031 async image-memory observation remains unresolved. Neither this report nor a green CI run declares the release complete.

Recorded on 4 October 2026 for [W032, issue #28](https://github.com/jorgerodrigues/ure/issues/28). Dependencies #25, #26, and #27 were checked closed. PRs #55, #56, and #57 were checked merged. The fixed implementation base is `cb5a15a3cd7dfb6ce6579bb063f7c3c73fedca2b` on the live default branch, `w002-recoverable-library`.

Hardware: Mac16,8, Apple M4 Pro, 48 GiB. Development system: macOS 27.2 beta, build 26B5091g. Toolchain: Xcode 27.0, build 27A266a. The proposed minimum is macOS 27.0 on Apple silicon. No minimum-OS Mac was available in this run.

## Restored gates and demonstrated fixes

CI now runs `make check` and `make release` on pull requests and pushes to the actual default branch. `make check` selects only `UreTests`. UI and device automation remain off CI. Swift 6, complete concurrency checking, and warnings as errors remain enabled. Local commands pass `XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` for the development beta's build-cache stall. CI uses its default settings.

The first full execution found four failing test definitions. None was removed or skipped.

- Timeline history assertions compared saved text with a draft's trailing whitespace. They now compare the original saved task and part values. The later rename and deletion must still preserve the historical values.
- Photo edge panning differed by about `1e-13` points after layout. Both coordinates now use the existing test's `0.01`-point tolerance. Movement, reverse movement, edge bounds, and retained magnification still have assertions.
- PDF scale assertions mixed `Double` and `CGFloat`, which Swift Testing reported unequal despite the same numeric value. Explicit numeric conversion fixes that assertion. Execution also showed PDFKit reset the configured maximum to 100 when assigning a document. The reader now reapplies 0.1 and 8 after assignment. The regression requires the maximum to remain 8 and both zoom limits to hold.
- The WAL backup test initially opened a writable reader before checking package contents. That reader could create sidecars. The test now checks the complete package inventory first and opens a read-only reader. This exposed an actual retained shared-memory file in the staged WAL snapshot. Snapshots now require rollback-journal mode, close their writer, and remove only the disposable staged shared-memory file before hashing and publication. Live database settings and original bytes are preserved. The regression requires committed WAL records, a self-contained package, and the exported database's `delete` journal mode. See [SQLite's WAL file rules](https://sqlite.org/wal.html).

The PDF state change follows the existing reader controls. Live Paper Ure screen rules were read through JSX and computed styles. The file has no document or W032 feature page. No visual redesign, decoder optimization, new cache, package, or schema migration was added.

## Executed evidence

| Check | Result |
| --- | --- |
| `make check XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Passed formatting/lint, unsigned Debug, and all 280 unit test definitions; 537 runs including parameter cases, zero failures or skips |
| Entire `BackupExportTests` suite | Passed after snapshot fix; the earlier individual method filter selected zero tests and is not counted as evidence |
| `ReleaseJourneyTests` | Passed on a fresh library and the frozen v10 and v15 libraries |
| Optimized app, `make release` | Passed on the final snapshot implementation |
| `make recovery` | Passed all 58 scenarios on the final snapshot implementation; retained run `f9de07ab-28b0-44d7-9420-ca1250075990` |
| Fresh source build without local config or prior derived data | Passed `make check` and `make release` in an isolated source copy with new derived data and no `Config/Local.xcconfig`; the beta cache flag was passed explicitly |
| Local native watch tests | Three completed tests passed before the run was interrupted; see below |
| Independent read-only review and final CI | Results recorded in the PR before acceptance or merge |

The full suite reports a runtime priority-inversion warning in the existing `BackupExportTests` semaphore latch. The latch deliberately blocks an export checkpoint to test concurrent reads and writes. This is test instrumentation, not a passing native responsiveness measurement. The existing AppIntents metadata-extraction notice remains. There are no Swift compiler warnings or errors.

Build, test, and review logs stay under ignored `.build/w032/`. The passing unit result is `ure-20261004-082048.xcresult` under `~/Developer/test-assets/w032-release-acceptance/`. The folder also retains failed and interrupted results for diagnosis. Remove only that branch folder when its PR is done. Frozen W029 inputs and the retained W031 performance fixture were preserved.

## First-release journeys

`ReleaseJourneyTests` loads W029's frozen SQL, manifest, and original bytes from the test bundle. It does not recreate the historical schema with current migrations. Each run uses a new temporary library and production `LibraryCoordinator` access. The source dumps remain unchanged. Supported forward migrations run before the repair journey.

| Specification journey | Executed evidence | Remaining native evidence |
| --- | --- | --- |
| 1. Name-only watch, restart, saved record | Watch service/state tests and native `testCreateEditCancelAndRestart` passed | Keyboard-only long Unicode journey and both appearances |
| 2. Job, notes, tasks, parts, several links, restart | Combined journey and service/state suites passed; exact manufacturer and supplier codes and both saved URLs survive | Native creation and reopening URLs through explicit Open actions |
| 3. Imported originals after source removal, offline viewing | Combined journey removes sources, restarts, decodes the photo, and reads all PDF pages from managed originals; photo/document suites also passed | Disconnect networking and use native main/reference viewers, import and export panels, security-scoped access |
| 4. Waiting job, Arrived part, task availability without status change | Combined journey and task-part/procurement suites passed | Native availability refresh in main and pinned reference workflows |
| 5. Done, Skipped, added/reopened tasks and no-task progress | Combined journey and progress/order/state suites passed | Native task editing, drag and keyboard reorder, spoken progress |
| 6. Completion with unresolved tasks and a later job | Combined journey and transition/history suites passed; first intake and outcome unchanged | Native closure summaries, completion forms, reopen conflict, history routing |
| 7. Complete backup and isolated restore | Combined journey compares every table's saved values and every original's size/SHA-256 on fresh, v10, and v15 runs; restore suites passed | Native save/open panels, review, confirmation, export originals, recovery-copy action |
| 8. Cancellation, disk-full, corruption and interruption | Isolated fault-injection suites and retained 58-case process matrix passed | Actual disk exhaustion, external-volume/permission boundaries, native cancellation/recovery; injected errors are not physical storage tests |
| 9. Keyboard, VoiceOver, light/dark | Native watch navigation Save/Discard/Stay, validation failure and restart, and close/quit draft protection passed | Complete keyboard workflow, VoiceOver, remaining window/appearance/accessibility settings |

The combined journey captures every saved table after restart and compares it with the isolated restored library. It checks that older fixture rows survive, links retain their exact URLs, waiting-task state stays unchanged after arrival, skipped tasks leave the progress denominator, reopening reduces progress, and a second job leaves the completed repair intact. It checks all backup and restored originals against saved SHA-256 and sizes. The backup manifest remains unchanged after restore. These are domain/storage checks. They do not replace native acceptance.

## Native run and remaining checklist

The local run selected WatchUITests and WorkshopUITests. `testCreateEditCancelAndRestart`, `testDirtySectionNavigationSupportsStaySaveAndDiscard`, and `testDirtyWindowCloseAndQuitKeepTheDraftWhenCancelled` passed. During `testKeyboardCreateEditCancelAndStayWithLongName`, XCUITest repeatedly reported an interrupting dialog from Dia before keyboard input. Later assertions failed. The runner was stopped with SIGINT. This is an incomplete native run, with no reliable verdict for that keyboard test. The remaining selected tests did not complete. An idle desktop is required before rerunning. No other application's dialog was dismissed.

Carry these gates from all earlier verification reports into the next acceptance pass. Older reports remain historical evidence; this checklist owns their current pending status.

- [ ] Rerun focused native tests on an idle Mac with `URE_TESTING=1` and a unique library UUID. Complete watch/caliber, job, tasks, parts/suppliers, workshop/parts overviews, search, timeline, and archive/removal flows. Check exact-record menu targeting and failed-save retention.
- [ ] Complete [W030's keyboard and accessibility checklist](keyboard-access-verification.md): all create/edit/reference/backup/restore flows without a pointer; VoiceOver labels, selection and honest progress; long text; 1000 × 650 and large windows; both appearances; inactive windows; increased contrast, larger system text, Reduce Motion, Reduce Transparency, and both glass-opacity settings.
- [ ] Check photo focus, panning, fit/zoom, adjacent photos; PDF focus, page navigation and zoom; read-only reference-window command permissions; scrolling to every reference action. Check fit and decode orientation, color, PNG transparency and HEIC with native viewers.
- [ ] Finish navigation, main-window close, and quit Save/Discard/Stay combinations. Verify failed Save preserves text and exact selection. Escape from the guard must Stay. Closing the reference window must preserve a main-window draft.
- [ ] Complete [W029's native recovery and storage gates](process-recovery-verification.md) and [backup export](backup-export-verification.md), [restore staging](restore-staging-verification.md), and [restore activation](restore-activation-verification.md) panel journeys. Include damaged opens, sandbox grants, external volume, cancellation, actual storage/permission failures, rollback failure and complete-generation recovery.
- [ ] Run the full repair and backup/restore journey in native UI against fresh and upgraded isolated libraries. Disconnect networking for saved photos/PDFs. Verify original export bytes and restored records.
- [ ] Measure optimized native usable-window time against 3 seconds and native warm list/search response against 300 ms using the unchanged W031 fixture. Record cache state, hardware, build mode, scrolling and task input while thumbnails decode. CLI data-layer timings are not native timing evidence.
- [ ] Profile native allocations in main and reference photo viewers during open, adjacent navigation and close. Explain W031's async worker growth to about 1.9 GiB after 20 large originals, including about 1.53 GB after warmup. Its retainer and native lifetime remain unknown. No speculative product image fix was retained. Preserve the fixture and baseline summaries; compare any demonstrated fix on the same fixture and optimized mode.
- [ ] Run on minimum macOS 27.0, or keep that gate explicitly pending. Development beta evidence cannot establish minimum-OS acceptance.

The [handover guide](../handover.md) covers build/launch, entering a repair, the sandbox library location, backups, and disposable restore testing. Its native file-panel and launch sequence remains part of the pending checklist. No App Store submission, notarization account change, updater, or cloud service is included. W032 is the last planned story. Keep issue #28 open until the acceptance evidence is complete.
