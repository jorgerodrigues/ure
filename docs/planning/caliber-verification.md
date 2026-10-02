# Shared caliber verification

Recorded on 2 October 2026. W004 is implemented on `w004-shared-calibers` in [PR #31](https://github.com/jorgerodrigues/ure/pull/31). The story is [#2](https://github.com/jorgerodrigues/ure/issues/2). W003 was merged through [PR #29](https://github.com/jorgerodrigues/ure/pull/29) before this work started. The user approved the shared caliber design and deferred native UI and device checks to release acceptance.

## Implementation

- The forward `v3-calibers` migration creates caliber records and adds an optional, indexed foreign key on each watch. W002's recovery snapshot and generation switch preserve existing watch records and original files.
- Calibers store exact designation, separate variant and manufacturer, movement type, optional numeric specifications, specification notes, and a source note. Unknown values stay absent. The library contains no seeded technical claims.
- Services validate required designation, finite numeric values, and watch links. Beat rate and lift angle must be positive. Jewel count and nominal power reserve may be zero. SQL constraints reject invalid relationships and deletion of a linked caliber.
- GRDB observation refreshes committed caliber records and linked watch lists. Each watch displays the current shared specifications. A caliber edit does not copy values into watches. Clearing one watch link preserves the caliber and other watch links.
- Native lists, designation search, detail views, and editors use the existing Save/Cancel pattern. Cmd-N creates a caliber in Calibers. Cmd-S saves the active editor. A shared workshop adapter routes section navigation, window close, and quit to the correct editor's draft guard.
- Failed loads support Retry. Failed saves preserve the draft and field errors. Pending writes reject repeated commands. No job, archive, note library, technical file import, identification, or compatibility engine is added.

## Verification

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| Local unsigned Debug build | Passed with `SDK_STAT_CACHE_ENABLE=NO` |
| Test compilation without execution | Passed with Swift 6 concurrency checks and warnings as errors |
| `make release` | Local unsigned optimized build and remote CI passed |
| Remote `make check` | Passed: strict format/lint, Debug build, and 68 isolated unit cases |
| Native UI and device acceptance | Deferred to release acceptance by user agreement |

Unit coverage includes minimal and complete on-disk round trips, separate designation and variant, unknown values, localized numbers, numeric boundaries, duplicate designations, missing records, shared links, clearing one link, foreign key enforcement, timestamps, committed observation, failed writes, Cancel, draft protection, load retry, repeated pending commands, and migration from W003 with unchanged originals. Tests use isolated temporary libraries.

[CI run 36972586574](https://github.com/jorgerodrigues/ure/actions/runs/36972586574) passed all configured checks. Its 68 unit cases include the existing 46 cases, 12 caliber service cases, seven caliber state cases, and three shared draft-guard cases. There were no failures or skipped cases. The optional SDK file-cache workaround was used for local compilation only.

The native test source adds shared editing across two watches, clearing one link, restart persistence, invalid-field draft preservation, and dirty section navigation. These cases are compiled now and run during release acceptance. The existing watch window-close/quit, minimum-window, and minimum-OS acceptance gates also remain pending. No app test runs on the user's active desktop during story implementation.

Run native acceptance later with `make test-ui`. Result bundles and captures must use `~/Developer/test-assets/<branch>/` and remain only while that branch is active.
