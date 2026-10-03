# W018 task-part verification

Implemented on 3 October 2026 for [W018 (#16)](https://github.com/jorgerodrigues/ure/issues/16), in [PR #46](https://github.com/jorgerodrigues/ure/pull/46). W014 (#12) and W017 (#15) were verified closed. Their PRs [#42](https://github.com/jorgerodrigues/ure/pull/42) and [#45](https://github.com/jorgerodrigues/ure/pull/45) were verified merged before implementation. The clean branch started at 4de11c2ea5d087ff2bea7a7589fe8a21f5035556 on the default branch.

## Scope and behavior

- A task can link to several parts from its own job. Selection uses native checkboxes in the existing explicit Save/Cancel editor. Command-S and shared Save/Discard/Stay guards apply. Cancel keeps saved links. Failed saves keep the complete draft and saved links. Pending saves block selection changes and duplicate commands.
- JobTaskService validates part existence, same-job ownership, and the saved open job inside the LibraryCoordinator transaction. Task edits, link additions/removals, and any task status event commit together. Link or event failures roll back every write. Closed jobs retain readable links and labels. Stale closed-job edits are rejected.
- Needed and Ordered are unresolved. Arrived and Installed satisfy availability. A cancelled link takes precedence and shows Needs review. No links means no availability label. Every linked part must be available for Parts available. The label appears in task rows and saved task detail.
- A Waiting task can use an unresolved linked part instead of text. Skipped always requires text. After procurement makes every linked part available or cancels one, the task stays Waiting. Keeping its existing part-based wait does not require new text for an unrelated task edit or an unchanged save. Removing its last unresolved link requires text or another status. Removing links after arrival or cancellation also requires an explicit reason or status when no unresolved links remain.
- One database observation reads tasks, links, and saved part records in one snapshot. Committed procurement writes refresh labels. Draft part status changes and failed part saves cannot fabricate availability. Observation refreshes saved data without replacing a task draft. Failed loading suppresses labels and blocks editing instead of showing available parts.
- The v16-task-parts forward migration adds the join table, compound primary key, existence foreign keys, and reverse lookup index. It rebuilds jobTask to replace the old text-only Waiting constraint with service validation of saved links. The Skipped, title, status, position, and owner constraints remain. All existing task fields and positions are copied unchanged. Earlier migration fixtures rebuild the previous task schema and remove the new migration record before constructing older libraries.
- Procurement changes never update task status, task timestamps, job stage, watch condition, or task progress. No scheduling, general dependency graph, stock allocation, timeline, overview, or later-story UI is added.

## Design inspection

The live Paper file contains Brand, Logo, macOS 27, Watches · W003, and Page 1. No W018 feature screen exists. The macOS type/colour/menu rules were read as inline-style JSX. Computed styles for those rules and both main-window artboards were inspected. The implementation uses native grouped Forms, checkboxes, system text styles, and semantic colors. No content glass or toolbar background was added. Pomme, AccentColor, the pinned reference pane, and reference-window editing boundaries remain intact. Native visual acceptance is pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing`: all unit and native UI sources compiled without execution.
- `git diff --check`: passed.

Xcode retains its existing App Intents no-framework extraction notice. Complete concurrency checks and warnings as errors remain enabled. No app launch, test execution, Release build, capture, or result bundle ran here.

## Behavioral sources and pending gates

TaskPartServiceTests covers several links across restart, Needed/Ordered/Arrived/Installed/Cancelled labels, no automatic task/job change, no-op saves after arrival and cancellation, foreign and missing parts, unavailable part-based reasons, unchanged Skipped validation, unlink validation, explicit reason/status recovery, compound-key and foreign-key constraints, link/event rollback, closed-job guards, and forward migration preserving task order, procurement, supplier details, history, photos, cover references, and original bytes.

JobTaskStateTests covers same-job selection, label refresh after committed procurement, no refresh after a failed procurement save, draft preservation during observation, unlink failure retention, Cancel, and explicit resume. Existing tests retain pending-write, navigation, load failure/retry, and task progress coverage. TaskPartUITests adds a deferred native journey for several checkbox links, failed unlink, Cancel, arrival, cancellation, restart, and explicit resume through Command-S.

These sources compiled. Their behavior was not executed during this story.

- During W032, execute behavioral tests with isolated libraries and URE_TESTING=1. Native test sources keep the injected library ID.
- Verify runtime migration, restart, procurement observation, rollback, ownership, stale closure, unlink validation, and pending commands.
- Verify keyboard/VoiceOver selection, Command-S, draft navigation/window/quit guards, focused reference-window commands, long part values, minimum-window resizing, pinned references, light/dark and inactive windows, increased contrast, and Reduce Transparency.
- Unit execution, Release builds, runtime and native acceptance remain deferred to W032 (#28). UI/device automation stays off GitHub Actions.

## Review and delivery

Independent review completed in one fresh read-only round with "No findings cleared the bar." Every changed source file was read. No source reads were blocked and no permission denials occurred. Unrelated external connectors were unavailable and were not needed. No findings were dismissed or left as P3 suggestions. Source sharing used the standing [review approval](review-approval.md).

Lint, unsigned Debug, all unit/native UI source compilation, and diff whitespace checks passed on the reviewed source. No tests were executed. CI runs Swift formatting/lint and unsigned Debug. Both steps must pass on the final PR head before merge. Results are recorded in [PR #46 checks](https://github.com/jorgerodrigues/ure/pull/46/checks). The PR opened with no GitHub comments or review threads. Runtime and native acceptance remain deferred to W032.
