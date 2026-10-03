# W020 workshop overview verification

Implemented on 3 October 2026 for [W020 (#18)](https://github.com/jorgerodrigues/ure/issues/18), in [PR #48](https://github.com/jorgerodrigues/ure/pull/48). Dependencies W014 (#12), W018 (#16), W019 (#17), and W010 (#8) were verified closed. Their PRs #42, #46, #47, and #37 were verified merged before implementation. The clean branch `w020-workshop-overview` started at `f384d533f64e34d0a50af4402044b6e17af3ab84` on the default branch after W019 merged.

## Scope and behavior

- One LibraryCoordinator observation reads open jobs, their watches, tasks, and parts in a consistent database snapshot. Four batched queries avoid per-job reads and task/part join multiplication. Query work and aggregation run away from the main actor. No schema change or writes are needed.
- Native List sections group Planned, In progress, Waiting, and Ready. Rows use job UUIDs. Each shows current watch identity and its existing cover thumbnail, saved job title, shared JobTaskProgress counts and rounded-down percentage, skipped count, waiting reason, and Needed/Ordered part count. Each complete requirement or lot counts once. Cancelled parts do not count as Needed/Ordered. Empty and all-skipped task lists show No tasks planned.
- Rows within each group use the latest saved job/task/part updated time descending, then job UUID ascending. Task and part saves can move their job within its group without changing the job timestamp. Watch identity and cover changes refresh displayed data. Originals remain behind the existing thumbnail/viewer boundary.
- Text filters current watch name, brand, model, case reference, serial, job title, and waiting reason. Text and stage filters combine. Whitespace-only text means no text filter. A selected job stays open when excluded, with an explicit message and Clear Filters. Empty libraries, no open jobs, and no matching results have clear states. Failed loading shows an error and Retry. Retry replaces the prior observation through the view task's revision ID.
- Opening a row uses WorkshopEditing's Save/Discard/Stay and pending-write guards. It validates loaded saved watch/job records and the current open stage, clears child selections, and selects the exact watch and job. Native editors, Command-S, task-order commands, timeline source navigation, pinned references, and the restricted reference window keep their existing boundaries in Workshop.
- Closing removes a job from the open rows. Its detail stays readable with a watch-history message. Back to Watch retains its history. Reopening returns it to an open group. Task and part statuses, intake snapshots, history, and original files are untouched by the overview.
- Explicit Save/Cancel remains in place. No proposed immediate task actions, charts, revenue metrics, deadline scheduling, drag-based job transitions, or later-story UI are added. No affected unresolved product choice was needed.

## Design inspection

The live Paper file contains Brand, Logo, macOS 27, Watches · W003, and Page 1. No W020 feature page exists. The macOS main-window list was read as inline-style JSX and computed styles. Its list is 320 points wide, rows have 10-point gaps, and thumbnails are 36 by 36 points. The implementation follows those values within the existing native split-view widths. System text styles, native section selection and controls, and semantic colors supply light/dark behavior. Pomme and AccentColor remain intact. No content glass or toolbar background was added. Native visual acceptance remains pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing`: all unit and native UI test sources compiled without execution.
- `git diff --check`: passed.

Initial test-source compilation found two fixture type errors: quantity input must be text, and task editing requires the job state. Both were fixed before the passing compilation. Xcode retains its existing App Intents no-framework extraction notice. Complete concurrency checks and warnings as errors remain enabled. No app launch, test execution, Release build, capture, or result bundle ran here.

## Behavioral sources and pending gates

WorkshopOverviewTests covers all six job stages, several task and part statuses per job, no duplicate jobs or counts, complete-lot counts, waiting reasons, empty and all-skipped progress, child/job date ordering, UUID ties, and restart. Closed jobs remain persisted.

WorkshopOverviewStateTests covers loading failure and retry, empty results, committed task addition/reopening, committed procurement refresh, rolled-back procurement, job stage/reason changes, watch identity refresh, closure/reopen, combined stage/text filters, selected-detail messages, exact watch/job navigation, Stay and Save protection for a task draft, cleared child selection, and unavailable/closed navigation. WorkshopUITests adds a deferred journey for selecting a job, combined filter empty states, retained detail, Command-S from Workshop, closure, and watch history. Existing initial-window expectations now use Select a job.

These sources compiled. Their behavior was not executed during this story. Tests use isolated libraries and fixed clocks for date-dependent behavior. The new native journey retains URE_TESTING=1 and its injected library ID.

- During W032 (#28), execute behavioral tests and the focused native journey.
- Verify runtime observation, rollback, cover thumbnails and failed-thumbnail placeholders, zero/all-skipped progress, part counts, grouping and ordering, filters, closure/reopen, and restart.
- Verify Save/Discard/Stay, failed Save, pending commands, timeline navigation, task move shortcuts, pinned references, window/quit guards, and focused reference-window commands from Workshop.
- Verify long watch/job/reason text, keyboard/VoiceOver access, minimum-window and pinned-pane layout, light/dark and inactive windows, increased contrast, and Reduce Transparency.
- Unit execution, Release builds, runtime and native acceptance remain deferred to W032. UI/device automation stays off GitHub Actions.

## Review and delivery

Source sharing uses the standing [read-only review approval](review-approval.md). The original W006 human message authorizing implementation, review, PR, CI, merge, and the next chat was read. CI runs Swift formatting/lint and unsigned Debug. Both steps must pass on the exact final PR head before merge. Runtime and native acceptance remain deferred to W032.

Independent review cleared in one fresh read-only round with "No findings cleared the bar." The reviewer read the exact diff, all seven tracked changed files, and all six added files in full. The read trace confirmed complete coverage with no blocked reads, tool errors, or permission denials. No findings were fixed, dismissed, dropped, or left as P3 suggestions. The configuration exposed only Read, Grep, and Glob, with no shell or edit tools. Diff artifacts stayed in the ignored `.build/w020-review/` folder. The source-sharing approval was verified against the direct W011 human reply.

Lint, unsigned Debug, all unit/native UI source compilation, and diff whitespace checks passed on the reviewed source. No tests were executed. No captures or result bundles were created.

Final CI results are available in [PR #48 checks](https://github.com/jorgerodrigues/ure/pull/48/checks). No GitHub comments or review threads existed when the PR opened. The final CI head and both formatting/lint and unsigned Debug steps are checked before merge.
