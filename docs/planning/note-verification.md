# Scoped note verification

Recorded on 2 October 2026. W007 implements [issue #5](https://github.com/jorgerodrigues/ure/issues/5) on `w007-scoped-notes` in [PR #34](https://github.com/jorgerodrigues/ure/pull/34). W006 was merged in [PR #33](https://github.com/jorgerodrigues/ure/pull/33) at `8681dcd28f773180565329c7a20b4e77c23b7399` before this work started. Issue #4 is closed.

## Implementation

- The forward `v6-notes` migration adds notes with three nullable owner foreign keys. A database CHECK requires exactly one watch, job, or caliber owner. The service takes a typed single owner, checks its existence, and rejects moving an existing note to another owner.
- Notes contain a title, plain-text body, Observation, Research, Work log, or Measurement kind, and occurred date. The body keeps its exact Unicode text, spacing, and line breaks. Measurement has no structured instrument fields. Titles must contain text. An empty body is allowed.
- Created and updated times come from the injected coordinator clock. The occurred date comes from the draft. Editing text retains the saved occurred date. All dates use explicit Unix-second storage with subsecond precision.
- Job-note saves use `JobService.requireOpenJob` inside the coordinator transaction. Closed-job notes remain readable. Their Add Note and Edit Note controls are disabled until reopening. A stale editor receives a save error and retains its draft.
- Native scoped lists use stable note IDs and show kind and occurred date. Note detail shows the full selectable plain text and all three dates. The editor uses TextEditor, a kind picker, and a date picker. Save, Cancel, Command-S, and Save, Discard, or Stay protect note drafts during navigation, window closure, and quitting. Pending saves reject duplicate commands and navigation.
- Observation refreshes committed note lists and detail without overwriting an open draft. Caliber list navigation now uses the shared editing guard so it also protects a caliber note draft.

No note deletion, technical-link records, shared-reference pane, rich text, OCR, automatic summaries, timeline UI, or later-feature placeholders are added. Child removal remains W023. Clickable links within plain text remain a proposed product choice. This issue requires plain-text editing.

## Verification

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Unsigned Debug build passed |
| `xcodebuild ... CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO build-for-testing` | Unit and native UI test sources compiled; no execution |
| Independent review | Two complete independent rounds found no P0-P2 defects; P3 choices recorded below |
| Remote CI | `verify` passed: lint and unsigned Debug build in [run 36991583364](https://github.com/jorgerodrigues/ure/actions/runs/36991583364) on source revision `0fd3af5`; the PR holds the final check and merge state |
| Unit execution and Release builds | Deferred to W032 by user agreement |
| Native UI and device acceptance | Deferred to release acceptance; no app tests launched |

The Debug build has no Swift source warnings. Xcode reports its existing App Intents metadata message because the app has no AppIntents dependency. The SDK file-cache workaround is a local command flag only.

The first independent review left two P3 notes. The unused raw-owner initializer and its isolated test were removed under AGENTS.md. Database tests now cover zero and every multiple-owner combination. The retained note selection after record navigation remains a P3 user preference. The final review also suggested removing finite-date validation because the current DatePicker supplies finite dates. That P3 cleanup remains unchanged; the service still rejects invalid programmatic dates. Lint, Debug build, and test-source compilation passed after cleanup. The final review read the complete current diff and reported no correctness defects. No review round was blocked from reading source files.

Behavioral test sources cover all owners and kinds, zero and multiple owner rejection, missing references, cross-scope edits, occurred-date retention and correction, creation and update times, long Unicode text across restart, closed-job create and update rejection, reopen, failed writes, draft cancellation, shared navigation, observation, retry, and pending command suppression. The forward-migration fixture retains watches, calibers, jobs, events, originals, and a recovery snapshot. Existing job migration fixtures remove the newer notes migration before simulating their earlier schema.

These sources are compiled but not executed during story implementation. Note editor keyboard behavior, minimum-window layout, light and dark appearances, VoiceOver, closed-job controls, restart acceptance, and macOS 27.0 remain release gates. Native UI or device automation must never run on GitHub Actions.
