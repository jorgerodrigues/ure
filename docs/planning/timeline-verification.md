# W019 job activity timeline verification

Implemented on 3 October 2026 for [W019 (#17)](https://github.com/jorgerodrigues/ure/issues/17), in [PR #47](https://github.com/jorgerodrigues/ure/pull/47). W007 (#5), W013 (#11), and W017 (#15) were verified closed. Their PRs #34, #41, and #45 were verified merged before implementation. The clean branch started at `681e68c63989c737e8939b192fdc97a083929fb5` on the default branch after W018 merged.

## Scope and behavior

- Show Activity opens a native job timeline. Saved activity events and saved job notes appear together, newest first. Notes use their occurred dates. No note copies or revisions are added to activityEvent. Note edits refresh the same entry and can move it when the occurred date is corrected.
- Equal dates put events before notes. Events use their decreasing saved ordering value, then event ID. Notes use their stable note ID. Namespaced event and note IDs avoid collisions. The same saved records have the same order across restart.
- One LibraryCoordinator database observation reads job events, job notes, and surviving task and part records in a consistent snapshot. Queries, decoding, and timeline assembly run away from the main actor. The view owns its observation lifetime. Retry cancels the old observation before starting another. Failed reads show an error and Retry. They do not present an empty or partial history as success.
- Each event appears once. The row shows the event kind, historical task title or part description when applicable, and a plain-language transition. Previous and new values expand to the retained reasons, outcomes, closure explanations, milestones, quantities, supplier details, exact price/currency, and order reference. Full text wraps and is selectable. Dates use the system locale.
- Job, condition, task, part, and note sources have explicit Open actions. Missing task or part sources show retained event text without a link. Source navigation uses WorkshopEditing's Save/Discard/Stay and pending-save guards. It rechecks feature loading and same-job ownership. Successful navigation clears prior child selections and opens the exact saved record. Closed sources stay readable with their existing editing guards.
- No database migration or historical payload rewrite is needed. Existing service transactions and event writes are unchanged. This is a repair history, not a complete audit log. No child-removal UI, global audit system, immutable note revisions, sync event stream, overview, or later-story placeholder is added.
- The explicit Save/Cancel editor pattern, Pomme, AccentColor, pinned reference pane, and restricted reference window remain in place.

## Design inspection

The live Paper file contains Brand, Logo, macOS 27, Watches · W003, and Page 1. No W019 feature screen exists. The macOS Rules artboard was read as inline-style JSX. Computed styles for Rules and the light/dark main-window artboards were inspected. The timeline uses a native grouped Form, DisclosureGroup, buttons, system text styles, and semantic colors. No content glass or toolbar background was added. Native visual acceptance is pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing`: all unit and native UI sources compiled without execution.
- `git diff --check`: passed.

The first Debug build found a missing GRDB import in the new observation state. It was fixed before the passing checks. Xcode retains its existing App Intents no-framework extraction notice. Complete concurrency checks and warnings as errors remain enabled. No app launch, test execution, Release build, capture, or result bundle ran here.

## Behavioral sources and pending gates

JobTimelineTests covers all four committed event kinds, repeated unchanged saves, job-only note scope, fixed-clock/subsecond dates, equal-date ordering, restart, occurred-date corrections, note edits without duplicate events, long Unicode note and event text, removed task and part sources, preserved supplier snapshots and exact prices, and rolled-back task/job/condition/procurement changes.

JobTimelineStateTests covers empty/loading/failure/retry states, malformed event failure, observed note edits, committed event refresh, rollback, removed-source refresh, exact source navigation, Save/Stay draft protection, cleared child selections, and reading closed sources. JobUITests adds a deferred native journey for empty history, task completion, edited notes, source navigation, closure, and restart. Tests use isolated libraries. Native sources retain URE_TESTING=1 and the injected library ID.

These sources compiled. Their behavior was not executed during this story.

- During W032 (#28), execute behavioral tests and the focused native journey.
- Verify runtime ordering, note edits/date corrections, rollback, removed sources, malformed-event failure, source navigation, and failed feature loading.
- Verify long expanded values and note bodies, keyboard/VoiceOver access, text selection, minimum-window and pinned-pane layout, light/dark and inactive windows, increased contrast, and Reduce Transparency.
- Verify Save/Discard/Stay, pending commands, window/quit guards, closed-job access, and focused reference-window commands.
- Unit execution, Release builds, runtime and native acceptance remain deferred to W032. UI/device automation stays off GitHub Actions.

## Review and delivery

Independent review cleared after two fresh read-only rounds. Both returned "No findings cleared the bar." Round one read every changed source but could not read the exact diff and new-file list outside the repository. It reported three permission denials. That round was treated as incomplete. Round two read the exact diff, the new-file list, and every changed source and documentation file in full. It completed with no blocked reads or permission denials. No findings were fixed, dismissed, dropped, or left as P3 suggestions.

The standing [source review approval](review-approval.md) was verified against the direct W011 human reply. The original W006 human message authorizing review, PR, CI, merge, and next-chat delivery was also read. Automatic approval review rejected exposing Bash with dontAsk in two launch attempts. Neither attempt ran. The accepted safer configuration used `--permission-mode dontAsk --tools 'Read,Grep,Glob'`, with Bash removed. The exact diff and new-file list were captured inside the ignored `.build/w019-review/` folder so the reviewer could read them within its project boundary. No edit tools, shell allowlisting, or permission bypass were used.

Lint, unsigned Debug, all unit/native UI source compilation, and diff whitespace checks passed on the reviewed source. No tests were executed. CI runs Swift formatting/lint and unsigned Debug. Both steps must pass on the final PR head before merge. Runtime and native acceptance remain deferred to W032.

Final CI results are available in [PR #47 checks](https://github.com/jorgerodrigues/ure/pull/47/checks). No GitHub comments or review threads existed when the PR opened. No captures or result bundles were created, and no W019 test-assets folder existed.
