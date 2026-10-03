# W014 task ordering and progress verification

Implemented on 3 October 2026 for [W014 (#12)](https://github.com/jorgerodrigues/ure/issues/12), in [PR #42](https://github.com/jorgerodrigues/ure/pull/42). Dependency W013 (#11) was verified closed and [PR #41](https://github.com/jorgerodrigues/ure/pull/41) merged before implementation. The clean branch started at cdbe7585e5ae0d9061de5c64d5b3c5e042571a25 on the default branch.

## Scope and behavior

- Each task has a persisted, non-negative position within its job. The v12-task-order forward migration seeds each job in the previous createdAt/id order. Tied timestamps use the stable task ID. Existing records, history, watch-cover references, and original files remain intact. Earlier migration fixtures remove the new migration record when constructing older schemas.
- New tasks append to the saved order. Edits read the current saved position, so an editor opened before a move cannot undo that move. Optional group labels stay visible as row subtitles. They do not regroup or sort the tasks.
- Drag a row before another row. Drop below the list to move it to the end. Row menus and the saved task detail offer Move up and Move down. The Task menu offers the same actions with Option-Command-Up Arrow and Option-Command-Down Arrow. VoiceOver named actions use the same commands. The reference window's focused-window guard disables these menu commands.
- The service reads the saved order and rechecks the saved open job and source/destination task ownership in one LibraryCoordinator transaction. It changes positions only. Status, reasons, timestamps, job stage, watch condition, and state-change events remain intact. Failed writes roll back every changed position. The visible list keeps its prior order and shows the error. The same action can be retried. Pending moves block duplicate writes and shared navigation.
- Closed-job ordering is disabled in the UI and rejected by the service, including a stale open-job view. The existing explicit Save/Cancel task editor, Command-S, drafts, and navigation/window/quit guards remain in place. Immediate row status actions remain proposed. No W007 note behavior changes.
- JobTaskProgress is the shared calculation available to future overview code. Done divided by every non-Skipped task supplies the counts, fraction, and whole percentage. The displayed percentage rounds down, so unfinished work cannot display 100 percent. Skipped count stays visible. Empty and all-skipped lists show No tasks planned. Loading and failed observation do not imply zero tasks. Adding and reopening tasks updates the result after a successful save. Closed jobs retain honest progress below 100 percent when unfinished tasks remain.
- No part links, estimates, weighted or time-based progress, subtasks, due dates, templates, automatic job transitions, workshop overview, or timeline UI are built.

## Design inspection

The live Paper file had Brand, Logo, macOS 27, Watches · W003, and Page 1. There was no W014 feature page. The macOS rules were read as JSX. The light/dark main-window artboards and rules computed styles were inspected. The new controls use the existing native Form and system menu patterns, semantic colors, and system text styles. No content glass or toolbar background was added. Pomme and AccentColor configuration are unchanged. Native visual acceptance remains pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing`: all unit and native UI sources compiled without execution.
- Independent read-only review completed in two rounds with no P0–P2 findings and no blocked code access. Both rounds reported zero permission denials. Between rounds, the implementation agent corrected the deferred UI test query and added a stable identifier to its combined progress element. Lint, Debug build, and all test-source compilation passed again.
- `git diff --check`: passed.

The first build attempt lacked sandbox access to Xcode package caches. The build passed with cache access. The first test-source compilation exposed an ambiguous Swift Testing array comparison. The fixture now gives that comparison an explicit array value. Xcode retains the existing App Intents no-framework extraction notice. Complete concurrency checks and warnings as errors remain enabled.

## Behavioral sources and pending gates

JobTaskProgressTests covers empty, all-skipped, mixed, added, reopened, and almost-complete lists. JobTaskOrderingTests covers several moves, restart persistence, group/status/reason preservation, unchanged history, ownership validation, boundary no-ops, invalid positions, partial-write rollback, retry, stale edits after reorder, closed jobs, and migration from tied timestamps in several jobs with original bytes preserved. JobTaskStateTests covers observed ordering, added/reopened progress, pending-write navigation protection, visible order after failure, retry, and stale closed-job state.

JobUITests adds the deferred keyboard/drag/progress/restart journey. All existing unit/native UI sources remain in the compilation gate. No tests are executed during story implementation. Unit execution, optimized Release checks, native drag and keyboard acceptance, VoiceOver, light/dark layout, minimum-window/reference-pane behavior, and runtime migration/failure acceptance remain W032 (#28) gates. Tests use isolated libraries. Native tests keep URE_TESTING=1 and the injected library ID. No capture or result bundle was created.

CI runs Swift formatting/lint and the unsigned Debug build. Both must pass on the final PR commit before merge. Final results are available in [PR #42 checks](https://github.com/jorgerodrigues/ure/pull/42/checks). The PR initially had no comments or review threads. Runtime and native acceptance remain deferred to W032.

## Optional review suggestions

Round one suggested removing the exact fraction as P3 because a future consumer could format it as 100 percent while tasks remain unfinished. It was left unchanged. W014 requests an exposed shared calculation, and the current header uses the centralized rounded-down percentage. The reason was handed back in round two and the reviewer did not restate or rebut it.

Round two suggested a shared move-target helper as P3. The UI and transaction currently agree for every direction. The suggestion addresses future drift rather than a present failure. It was left unchanged under the review workflow's P3 rule. UI checks use the observed list, while the service rechecks the saved job, ownership, and order inside the transaction. Both optional suggestions remain available for later review.
