# Job intake verification

Recorded on 2 October 2026. W005 is implemented on `w005-job-intake`. The story is [#3](https://github.com/jorgerodrigues/ure/issues/3). Its dependency, W004, was merged through [PR #31](https://github.com/jorgerodrigues/ure/pull/31) before this work started. The user approved several repair jobs per watch, with at most one open job.

## Implementation

- The forward `v4-jobs` migration adds watch-owned jobs and a partial unique index for Planned, In progress, Waiting, and Ready jobs. Completed and Cancelled jobs do not occupy the open-job slot. Foreign keys prevent missing watch references. The existing recovery snapshot and generation switch preserve saved watches, calibers, and originals.
- The save service validates a required title, optional intake and owner contact fields, watch ownership, and open-job availability. New jobs start at Planned. Watch and exact caliber identity are read and copied in the same transaction that creates the job. The typed JSON snapshot has an explicit version.
- Watch and caliber edits leave earlier intake snapshots unchanged. Open-job intake corrections affect only that job. Closed jobs are readable and reject intake edits. Unsupported snapshot versions cannot be overwritten.
- Watch detail shows repair history and Start Job or Open Job. Job detail provides intake, optional owner contacts, the saved identity snapshot, Edit Intake, and Back to Watch. Save, Cancel, Command-S, record and section navigation, window close, and quit share draft protection. Failed writes preserve drafts. Pending saves reject repeated commands.
- A stale create attempt keeps its draft and offers the existing open job. Opening it uses the draft guard. No job stage controls, watch condition changes, tasks, notes, parts, files, or report features are added.

## Verification

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| Local unsigned Debug build | Passed with `SDK_STAT_CACHE_ENABLE=NO` |
| `xcodebuild build-for-testing` | Unit and native UI test sources compiled without execution |
| `make release XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Local optimized build passed |
| Remote formatting/lint and Debug build | Pending the updated implementation PR's CI run |
| Unit test execution and CI Release build | Deferred to W032 by user agreement on 2 October 2026 |
| Native UI and device acceptance | Deferred to release acceptance by the existing user agreement |

Behavioral unit tests cover on-disk restart, optional contacts, text identifiers, versioned JSON, snapshot preservation and explicit corrections, validation, concurrent creation, each open stage's database constraint, retained closed history, closed edits, foreign keys, wrong-watch edits, future snapshot protection, committed observation, failed writes, migration from the caliber library with unchanged originals, Cancel, Start versus Open, load retry, pending commands, stale creation, and shared navigation guards. Every test uses an isolated temporary library.

The local checks use macOS 27.2 beta and Xcode 27.0 on Apple silicon. The optional SDK file-cache workaround is supplied as a local build flag. Complete Swift concurrency checking and compiler warnings as errors remain enabled.

The original [CI run](https://github.com/jorgerodrigues/ure/actions/runs/36980840821) was cancelled when the user reduced CI to formatting/lint and an unsigned Debug build. Its unit results are unverified. Test sources are retained. W032 restores `make check` and `make release` in CI before first-release acceptance. The local Release build recorded above ran before this workflow change; it is no longer a per-story requirement during this phase.

Native test sources cover intake creation without contacts, opening the existing job, identity preservation after watch edits, restart, cancelled intake, title validation, Back to Watch, and dirty section navigation. Run these with `make test-ui` during release acceptance. Result bundles and captures must use `~/Developer/test-assets/<branch>/` and remain only while that branch is active. No app test runs on the user's active desktop during this story. The existing window-close/quit, minimum-window, and minimum-OS acceptance gates remain pending.
