# W013 job task verification

Implemented on 3 October 2026 for [W013 (#11)](https://github.com/jorgerodrigues/ure/issues/11), in [PR #41](https://github.com/jorgerodrigues/ure/pull/41). Dependency W006 (#4) was verified closed and [PR #33](https://github.com/jorgerodrigues/ure/pull/33) merged before implementation. The clean branch started from the default branch after W012 [PR #40](https://github.com/jorgerodrigues/ure/pull/40) merged.

## Scope and behavior

- Tasks belong to one job. A title is required. Detail and group label are optional. Status is To do, Doing, Waiting, Done, or Skipped. Several tasks can be Doing. Waiting and Skipped require their own reasons. Saving another status clears the current reason. No part links are built.
- Task changes follow the existing explicit Save/Cancel editor pattern. Immediate task-row actions remain proposed. Command-S routes to the active task editor. Task drafts use the existing Save, Discard, or Stay navigation, main-window, and quit guards. Pending writes disable controls and block duplicate saves. Failed writes retain the draft and the prior saved state.
- Closed-job tasks remain readable. Add, Edit, editor fields, and Save are disabled for closed jobs. The service checks the current job inside the transaction and rejects stale editors. Cancel and draft discard remain available.
- Saved status and reason changes commit an ActivityEvent with task ID, title, prior and next statuses and reasons. Completing a new task directly also records an event. Completing and reopening a task do not change the job stage or watch condition. Repeated saves of the same values add no record or event. Task or event write failures roll back the whole transaction.
- Completing or cancelling a job presents status counts and the current unfinished task list. To do, Doing, and Waiting are unfinished. Done and Skipped are not. Closure requires a separate explanation when any unfinished task remains. The service checks the saved tasks again during closure. Every task keeps its status. The explanation is saved on the job and in its transition history. Reopening clears the current explanation while retaining past events.
- The v11-job-tasks forward migration adds jobTask and the closure explanation. It expands the ActivityEvent kind constraint while copying existing event rows unchanged. Existing intake, notes, links, documents, photos, watch-cover foreign keys, and originals are preserved. Earlier job event JSON can still decode without the new optional field.
- The reference pane stays outside task detail/editor routing. Its restricted reference window still receives no mutable feature state. The focused-window editing guard remains in place. W007 note behavior and its separate proposed choices are unchanged.
- No task ordering controls, progress percentages, part links, subtasks, due dates, estimates, templates, or timeline UI are built. W014 adds explicit order and progress.

## Design inspection

The live Paper file had Brand, Logo, macOS 27, Watches · W003, and Page 1. There was no W013 feature page. The macOS screen rules were read as JSX and the main light/dark artboard and rules computed styles were inspected. Task views follow the existing native Form/editor pattern, system text styles, native controls, and semantic colors. No content glass or toolbar background was added. Native visual acceptance remains pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing`: all unit and native UI test sources compiled without execution.
- `git diff --check`: passed.

Initial compilation exposed a missing GRDB import in task observation. It was corrected. Xcode retains its existing App Intents no-framework extraction notice. Complete concurrency checks and warnings as errors remain enabled.

## Behavioral sources and pending gates

JobTaskServiceTests covers all saved statuses and optional fields across restart, all status transitions, reason validation, database constraints, missing/mismatched jobs, idempotent saves, completion/reopening event rollback, new-Done rollback, both closure stages, unfinished explanations, closed-job writes, reopening, and forward migration with old history, notes, links, photo covers, and unchanged original bytes. Older migration fixtures now remove W013 schema when constructing prior library versions.

JobTaskStateTests covers draft cancellation, field errors, scope filtering, observed changes without draft replacement, shared navigation Stay/Save/Discard, failed saves, pending duplicate commands, stale closed-job editors, read access after closure, and loading failure/retry. It also verifies that job closure requires a loaded task summary through the shared command and navigation Save paths. JobUITests adds task reason validation, Command-S, draft navigation, closure summary, unfinished status retention, restart, and reopening. Existing editing-guard tests now inject task state.

These sources compiled. Their behavior was not executed in this story.

- During W032, execute behavioral tests with isolated libraries and URE_TESTING=1.
- Locally verify all task statuses, reason entry, failures, pending clicks, closure and reopen, and saved-event rollback boundaries.
- Verify task drafts under Save, Discard, Stay, window closure, and quit. Check Command-S and reference-window focus while a task draft is open.
- Verify long titles/details/group labels, keyboard focus, minimum-window resizing, the pinned pane, light/dark and inactive windows, increased contrast, Reduce Transparency, and VoiceOver.
- Unit execution, Release builds, and native UI acceptance remain deferred to W032. No app tests or Release builds ran here. Native UI/device automation stays off GitHub Actions.

## Independent review and CI

The first independent review found a shortcut mismatch: the stage editor disabled closure while its task summary was unavailable, but Command-S could bypass that check. WorkshopEditing now owns a shared closure Save gate used by the editor, Command-S, and draft-navigation Save. The regression source covers failed observation, rejected writes, retry, and unrelated condition editing. Lint, Debug build, and compilation of all unit/native UI test sources passed again after the fix.

The second full independent review returned: No findings cleared the bar. The review completed after two rounds with the shortcut finding fixed. Each round had one denied Bash read, but no blocked code access was reported. Unavailable unrelated connectors were not needed for this review. Source transfer used the standing [read-only review approval](review-approval.md), verified against the direct human reply in the source chat.

PR CI runs formatting/lint and an unsigned Debug build. Current results are in [PR #41 checks](https://github.com/jorgerodrigues/ure/pull/41/checks). Both must pass before merge. Runtime and native acceptance remain deferred to W032.
