# W021 parts overview verification

Implemented on 3 October 2026 for [W021 (#19)](https://github.com/jorgerodrigues/ure/issues/19), in [PR #49](https://github.com/jorgerodrigues/ure/pull/49). Dependencies W017 (#15) and W020 (#18) were verified closed. Their PRs #45 and #48 were verified merged before implementation. The clean branch `w021-parts-overview` started at `fc78d6886447710df1faf02d0844e59800c98df1` on the default branch after W020 merged.

## Scope and behavior

- One LibraryCoordinator observation reads parts from open jobs, their jobs, and watches in one database snapshot. Three batched queries avoid supplier-link duplication and per-row queries. SQL and record assembly run away from the main actor. No migration or write path is added.
- The native Parts list uses part UUIDs. Each row shows description, optional manufacturer reference, current watch name and cover thumbnail, job title and stage, procurement status, and whole quantity. Parts sort by their saved updated date descending, then UUID ascending. Closed-job parts are excluded. Cancelled parts in open jobs remain visible.
- Exact Needed, Ordered, Arrived, Installed, and Cancelled filters combine with text search. Search matches descriptions, manufacturer references, watch identity, and job title. Whitespace-only search applies no text filter. Clear Filters resets both. Empty libraries and no matching records have separate states. Failed loading shows an error and Retry. Retry replaces the observation through its revision task ID.
- Selecting a row uses WorkshopEditing's Save/Discard/Stay and pending-write guards. It validates the saved loaded part, open job, watch, and ownership, clears other child selections, and opens the exact part in its job. Selection performs no supplier opening or network request. Existing explicit Open buttons remain the only supplier browser actions.
- Procurement uses the existing PartService and explicit Save/Cancel editor. Successful commits refresh the global list and job parts. Failed writes retain drafts and saved values. Filters keep an excluded selected detail readable and show a message. Closing removes the job's rows while its parts remain readable in watch history. Reopening returns the rows.
- Parts routes the existing watch/job detail, Command-S, task-order commands, activity navigation, and bench reference tools. Opening a part also leaves an active job timeline, including when that job stays selected. The pinned pane stays outside editor routing. Focused reference-window editing restrictions remain in place.
- No purchasing dashboard, bulk orders, stock quantities, customer totals, immediate row status actions, or later-story UI is added. No unresolved product choice affects this implementation. Pomme, AccentColor, historical records, original files, and existing service boundaries remain intact.

## Design inspection

The live Paper file contains Brand, Logo, macOS 27, Watches · W003, and Page 1. No W021 feature page exists. The macOS main-window artboard was read as inline-style JSX, and computed styles for light/dark windows and the body were inspected. Parts follows the established native 320-point list, 10-point row gap, and 36-point cover thumbnail. It uses system text styles, native selection/search/status controls, and semantic colors. No content glass or toolbar background is added. Runtime visual acceptance remains pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing`: all unit and native UI test sources compiled without execution.
- `git diff --check`: passed.

Xcode retains its existing App Intents no-framework extraction notice. Complete concurrency checks and warnings as errors remain enabled. No app launch, test execution, Release build, capture, or result bundle ran here.

## Behavioral sources and pending gates

PartsOverviewTests covers several watches with identical Unicode part descriptions, every job stage and procurement status, exact saved ownership, whole-lot quantities, multiple links without duplicate rows, stable UUID ties, latest-update ordering, and restart. Closed-job parts remain persisted.

PartsOverviewStateTests covers initial loading failure/retry, empty results, committed procurement and context refresh, rollback across the overview and job list, closure/reopen, exact status and combined text filters, retained selected-detail messages, exact watch/job/part navigation, highlight clearing after Back to Watch or unrelated-job navigation, supplier browser isolation, Stay and Save, failed-save draft retention, cleared child selections, and unavailable/closed navigation.

PartsOverviewUITests adds a deferred native journey with similar descriptions on two watches, exact references and job navigation, Command-S procurement, both lists, filter exclusion and empty results, Stay/Cancel, timeline-to-part routing, closure, and watch history. Existing native empty-section expectations remain valid. Tests use isolated libraries and fixed clocks where dates affect behavior. Native sources retain URE_TESTING=1 and their injected library ID.

These sources compiled. Their behavior was not executed during this story.

- During W032 (#28), execute behavioral tests and the focused native journey.
- Verify observation timing, rollback, malformed-record failure, ownership, status/text filters, thumbnails, closure/reopen, and restart at runtime.
- Verify Save/Discard/Stay, failed Save, pending commands, timeline source navigation, task ordering, bench references, window/quit guards, and focused reference-window commands from Parts.
- Verify long descriptions/references/watch/job labels, keyboard/VoiceOver access, minimum-window/pinned-pane layout, light/dark and inactive windows, increased contrast, and Reduce Transparency.
- Unit execution, Release builds, runtime and native acceptance remain deferred to W032. UI/device automation stays off GitHub Actions.

## Review and delivery

Source sharing uses the standing [read-only review approval](review-approval.md), verified against the direct W011 human reply. The original W006 human message authorizing implementation, review, PR, CI, merge, and the next chat was read. CI runs Swift formatting/lint and unsigned Debug. Both steps must pass on the exact final PR head before merge. Runtime and native acceptance remain deferred to W032.

Round one read the exact diff and every changed/added source, test, and documentation file in full. No reads were blocked and no permission denials occurred. It found a P2 selection bug: retained PartState selection could highlight a part after Back to Watch or navigation to another job. The highlight now requires the currently displayed watch/job/part relationship. Filter messages also require matching part/job ownership. Unit and native regression sources cover reopening the same row and unrelated-job navigation.

One P3 design suggestion remains unchanged under the review workflow's P3 rule: centralize closing child editors in WorkshopEditing instead of repeating those calls in Parts, Workshop, and timeline source navigation. Current paths close every existing child type. This remains an optional cleanup for the user. Lint, unsigned Debug, all unit/native UI test-source compilation, and diff whitespace checks passed after the selection fix. No tests were executed.

Round two read the updated exact diff, new-file list, and every changed/added file in full. The read trace confirmed successful full coverage with no blocked reads, tool errors, or permission denials. It confirmed the P2 fix and ended with "No findings cleared the bar." The P3 suggestion was carried into this round and was not restated. No finding was dismissed or dropped. Independent review cleared P0-P2 after two fresh read-only rounds. Both exposed only Read, Grep, and Glob, with no shell or edit tools. Diff artifacts stayed inside the ignored `.build/w021-review/` folder.

Final CI results are available in [PR #49 checks](https://github.com/jorgerodrigues/ure/pull/49/checks). No GitHub comments or review threads existed when the PR opened. No captures or result bundles were created, and no W021 test-assets folder exists. Both CI steps are checked on the final head before merge.
