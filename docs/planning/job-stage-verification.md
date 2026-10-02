# Job stage and watch condition verification

Recorded on 2 October 2026. W006 implements [issue #4](https://github.com/jorgerodrigues/ure/issues/4) on `w006-job-stages` in [PR #33](https://github.com/jorgerodrigues/ure/pull/33). W005 was merged in [PR #32](https://github.com/jorgerodrigues/ure/pull/32) at `560d092440e2a5a33ba9e812b98253b54534b887` before this work started.

## Implementation

- The forward `v5-job-stages` migration adds watch condition and its optional note, job reasons, outcome, recommendations, milestone dates, and job-owned ActivityEvent records. Existing watches start at Unknown. Existing jobs and originals are retained. The migration does not invent past events or missing milestone dates.
- An open job can move among Planned, In progress, Waiting, and Ready, or close as Completed or Cancelled. Waiting needs a reason. Completed needs an outcome. Cancelled needs a reason. Whitespace-only values fail validation. Ready remains a user decision.
- Starting In progress records the first start date. Closure records the applicable date. Reopening clears current closure dates and the cancellation reason. It retains the first start date and prior outcome and recommendations. Previous reasons, outcomes, and dates remain in transition events. Reopening can select any open stage and enforces the existing service and database rule of at most one open job per watch.
- Condition changes through an open job update the watch and its optional note. They do not change the job stage or intake snapshot. Workflow writes update only their own columns and preserve unknown keys in unsupported intake snapshots. Watch identity edits preserve condition. Intake edits preserve job workflow fields. Closed jobs reject intake, stage, and condition changes through the shared open-job service guard.
- Each stage or condition change writes its typed prior and next values and event in the same coordinator transaction. UUIDs identify events. A unique increasing local ordering value resolves equal timestamps. An unchanged save creates no event. An event write failure rolls back the state change.
- Job detail has native Change Stage, Change Condition, and Reopen Job controls. Forms use Save, Cancel, Command-S, required-field errors, and the existing Save, Discard, or Stay navigation, close, and quit guard. Pending saves block repeated commands. Failed saves retain drafts. Closed jobs show their saved outcome and disable operational actions. Reopen conflicts offer Open Existing Job.

No task, part, or timeline UI is added. Task and part completion summaries and unresolved-work explanations belong to the dependent task and part stories.

## Verification

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Unsigned Debug build passed |
| `xcodebuild ... CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO build-for-testing` | Unit and native UI test sources compiled without execution |
| Unit execution and Release builds | Deferred to W032 by the user agreement |
| Native UI and device acceptance | Deferred to release acceptance; no app tests launched during this story |
| Remote CI | [Formatting/lint and unsigned Debug build](https://github.com/jorgerodrigues/ure/actions/runs/36988318852) passed in 1 minute 18 seconds |
| Independent code review | Cleared P0-P2 after four rounds; one P3 design note remains |

The checks used macOS 27.2 beta, Xcode 27.0, and Apple silicon. The local SDK file-cache workaround remains a command flag. Swift 6 complete concurrency checking and warnings as errors remain enabled. Xcode emitted its existing App Intents metadata notice because the app and tests do not depend on AppIntents. The restricted build attempt failed to access Swift package caches. The build passed with cache access.

Behavioral test sources cover every open-stage pair and closure, each required field, all physical conditions, note-only changes and clearing, unchanged saves, preserved intake and workflow values, on-disk restart, closure locks, every reopen destination, conflicts with another open job, the database uniqueness constraint, transactional event failure for both mutation kinds, migration with intact originals, draft validation and navigation, failed saves, and repeated pending transition, condition, and reopen commands. Tests use isolated temporary libraries. Compilation does not establish runtime success.

Review fixes normalize top-level Unix dates, preserve unsupported intake JSON during workflow writes, and store nested event dates as exact Unix seconds. Regression sources cover these cases. A standalone Foundation check reproduced 3 date mismatches in 128 values with millisecond JSON encoding and 0 with seconds encoding. This check did not launch the app or run app tests.

The final independent review found no correctness defects in the changed Swift code. It left a P3 note that default record fields can hide missed carry-overs when later fields are added. Current identity and intake writes preserve the added values. The reviewer read this report and the job-stage specification. Some general documentation diffs were not reviewed because a shell read was denied.

Native UI test sources cover independent condition and stage changes, Waiting validation, Command-S, completion locks, and reopening. Run them during release acceptance. Never run native UI or device automation on GitHub Actions. Minimum-window behavior, keyboard and VoiceOver acceptance, and macOS 27.0 remain pending alongside the earlier gates.
