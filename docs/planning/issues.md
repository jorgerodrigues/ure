# Implementation roadmap

The [GitHub issues](https://github.com/jorgerodrigues/ure/issues) hold story descriptions, acceptance criteria, discussions, and current status. This roadmap maps stable planning IDs to those issues and records their dependency order. Update story scope and checklists on GitHub. Product decisions belong in [the specification](specification.md).

Read the specification and the selected GitHub issue before editing. Do not start an issue before its listed dependencies are merged. Settle any proposed product choice that affects the implementation.

## Delivery milestones

| Milestone | Issues | Useful result |
| --- | --- | --- |
| Foundation | W001 to W003 | A native app that reliably saves watches |
| Bench records | W004 to W014 | Job history, shared knowledge, files, notes, tasks, and a reference pane |
| Parts | W015 to W018 | Supplier options, procurement status, and waiting-task links |
| Overview | W019 to W023 | History, workshop view, parts overview, search, and archive |
| Recovery | W026 to W028 | User-exported backups and recoverable restore |
| Release | W029 to W032 | Verified recovery, accessibility, performance, and release journeys |

Milestones describe implementation order, not separate production releases. Do not use the app as the only copy of valuable records before Recovery and Release pass.

## Common completion rules

- Read the relevant specification sections and surrounding code before editing.
- Follow repository conventions and the user's AGENTS.md. Use Swift for this native app.
- Keep the PR within its stated boundary. Do not prebuild later features.
- Introduce forward migrations. Preserve existing data and originals.
- Implement the applicable loading, empty, failed-save, and closed-job states.
- Run the app Debug build and formatter/lint checks during rapid implementation. Keep behavioral tests current and compile affected tests when needed. CI unit execution and Release builds are deferred to W032; restore both before first-release acceptance. Native UI and device automation stays off CI.
- Include actual verification results and any untested gate in the PR.
- Do not add tool attribution or a coauthor footer.
- Ask whether the user wants review comments resolved after addressing them.
- Ask for clarification only when an unresolved choice changes the implementation.

## Story links

| ID | Story | Depends on |
| --- | --- | --- |
| W001 | ~~Create the native Mac shell and verification commands~~ ([commit](https://github.com/jorgerodrigues/ure/commit/daa19a4); [verification](setup-verification.md)). Implementation done; native UI acceptance pending. | None |
| W002 | ~~Open and migrate a recoverable SQLite library~~ ([commit](https://github.com/jorgerodrigues/ure/commit/07bee8e); [verification](library-verification.md)). Implementation done; minimum-OS and remote CI pending. | [W001](setup-verification.md) |
| W003 | ~~Create and edit watch records (#1)~~ ([PR #29](https://github.com/jorgerodrigues/ure/pull/29); [verification](watch-verification.md)). Merged; remaining native acceptance is deferred to release acceptance. | [W002](library-verification.md) |
| W004 | [Add the shared caliber library (#2)](https://github.com/jorgerodrigues/ure/issues/2) ([PR #31](https://github.com/jorgerodrigues/ure/pull/31); [verification](caliber-verification.md)). Merged. Native acceptance is deferred. | [W003](https://github.com/jorgerodrigues/ure/issues/1) |
| W005 | [Create job intake and watch repair history (#3)](https://github.com/jorgerodrigues/ure/issues/3) ([PR #32](https://github.com/jorgerodrigues/ure/pull/32); [verification](job-verification.md)). Merged. Native acceptance is deferred. | [W004](https://github.com/jorgerodrigues/ure/issues/2) |
| W006 | [Control job stages and record watch condition (#4)](https://github.com/jorgerodrigues/ure/issues/4) ([PR #33](https://github.com/jorgerodrigues/ure/pull/33); [verification](job-stage-verification.md)). Merged. Native acceptance is deferred. | [W005](https://github.com/jorgerodrigues/ure/issues/3) |
| W007 | [Save scoped research and work notes (#5)](https://github.com/jorgerodrigues/ure/issues/5) ([PR #34](https://github.com/jorgerodrigues/ure/pull/34); [verification](note-verification.md)). Merged. Native acceptance is deferred. | [W006](https://github.com/jorgerodrigues/ure/issues/4) |
| W008 | [Store technical links with source context (#6)](https://github.com/jorgerodrigues/ure/issues/6) ([PR #35](https://github.com/jorgerodrigues/ure/pull/35); [verification](reference-verification.md)). Implementation and current checks are in the PR. Native acceptance is deferred. | [W007](https://github.com/jorgerodrigues/ure/issues/5) |
| W009 | [Implement managed file import and recovery (#7)](https://github.com/jorgerodrigues/ure/issues/7) ([PR #36](https://github.com/jorgerodrigues/ure/pull/36); [verification](file-import-verification.md)). Implementation and current checks are in the PR. Runtime acceptance is deferred. | [W008](https://github.com/jorgerodrigues/ure/issues/6) |
| W010 | [Import and browse watch and job photos (#8)](https://github.com/jorgerodrigues/ure/issues/8) ([PR #37](https://github.com/jorgerodrigues/ure/pull/37); [verification](photo-verification.md)). Implementation and current checks are in the PR. Native acceptance is deferred. | [W009](https://github.com/jorgerodrigues/ure/issues/7) |
| W011 | [Import and read technical PDF files (#9)](https://github.com/jorgerodrigues/ure/issues/9) ([PR #39](https://github.com/jorgerodrigues/ure/pull/39); [verification](document-verification.md)). Implementation and current checks are in the PR. Runtime acceptance is deferred. | [W009](https://github.com/jorgerodrigues/ure/issues/7) |
| W012 | [Keep a reference visible during bench work (#10)](https://github.com/jorgerodrigues/ure/issues/10) ([PR #40](https://github.com/jorgerodrigues/ure/pull/40); [verification](bench-reference-verification.md)). Runtime and native acceptance are deferred. | [W010](https://github.com/jorgerodrigues/ure/issues/8), [W011](https://github.com/jorgerodrigues/ure/issues/9) |
| W013 | [Create and update job tasks (#11)](https://github.com/jorgerodrigues/ure/issues/11) ([PR #41](https://github.com/jorgerodrigues/ure/pull/41); [verification](task-verification.md)). Runtime and native acceptance are deferred. | [W006](https://github.com/jorgerodrigues/ure/issues/4) |
| W014 | [Order tasks and show honest progress (#12)](https://github.com/jorgerodrigues/ure/issues/12) ([PR #42](https://github.com/jorgerodrigues/ure/pull/42); [verification](task-order-verification.md)). Runtime and native acceptance are deferred. | [W013](https://github.com/jorgerodrigues/ure/issues/11) |
| W015 | [Record required parts with saved links (#13)](https://github.com/jorgerodrigues/ure/issues/13) ([PR #43](https://github.com/jorgerodrigues/ure/pull/43); [verification](part-verification.md)). Runtime and native acceptance are deferred. | [W006](https://github.com/jorgerodrigues/ure/issues/4) |
| W016 | [Compare several supplier options for a part (#14)](https://github.com/jorgerodrigues/ure/issues/14) ([verification](supplier-verification.md)). Runtime acceptance is deferred. | [W015](https://github.com/jorgerodrigues/ure/issues/13) |
| W017 | [Track ordering arrival and installation (#15)](https://github.com/jorgerodrigues/ure/issues/15) ([PR #45](https://github.com/jorgerodrigues/ure/pull/45); [verification](procurement-verification.md)). Runtime and native acceptance are deferred. | [W016](https://github.com/jorgerodrigues/ure/issues/14) |
| W018 | [Link waiting tasks to required parts (#16)](https://github.com/jorgerodrigues/ure/issues/16) ([PR #46](https://github.com/jorgerodrigues/ure/pull/46); [verification](task-part-verification.md)). Runtime and native acceptance are deferred. | [W014](https://github.com/jorgerodrigues/ure/issues/12), [W017](https://github.com/jorgerodrigues/ure/issues/15) |
| W019 | [Show the job activity timeline (#17)](https://github.com/jorgerodrigues/ure/issues/17) ([PR #47](https://github.com/jorgerodrigues/ure/pull/47); [verification](timeline-verification.md)). Runtime and native acceptance are deferred. | [W007](https://github.com/jorgerodrigues/ure/issues/5), [W013](https://github.com/jorgerodrigues/ure/issues/11), [W017](https://github.com/jorgerodrigues/ure/issues/15) |
| W020 | [Build the workshop overview (#18)](https://github.com/jorgerodrigues/ure/issues/18) ([PR #48](https://github.com/jorgerodrigues/ure/pull/48); [verification](workshop-verification.md)). Runtime and native acceptance are deferred. | [W014](https://github.com/jorgerodrigues/ure/issues/12), [W018](https://github.com/jorgerodrigues/ure/issues/16), [W019](https://github.com/jorgerodrigues/ure/issues/17), [W010](https://github.com/jorgerodrigues/ure/issues/8) |
| W021 | [Show parts across open jobs (#19)](https://github.com/jorgerodrigues/ure/issues/19) ([PR #49](https://github.com/jorgerodrigues/ure/pull/49); [verification](parts-overview-verification.md)). Runtime and native acceptance are deferred. | [W017](https://github.com/jorgerodrigues/ure/issues/15), [W020](https://github.com/jorgerodrigues/ure/issues/18) |
| W022 | [Search repair records and shared knowledge (#20)](https://github.com/jorgerodrigues/ure/issues/20) ([PR #50](https://github.com/jorgerodrigues/ure/pull/50); [verification](search-verification.md)). Runtime and native acceptance are deferred. | [W010](https://github.com/jorgerodrigues/ure/issues/8), [W011](https://github.com/jorgerodrigues/ure/issues/9), [W018](https://github.com/jorgerodrigues/ure/issues/16), [W020](https://github.com/jorgerodrigues/ure/issues/18), [W021](https://github.com/jorgerodrigues/ure/issues/19) |
| W023 | [Archive records and remove child items safely (#21)](https://github.com/jorgerodrigues/ure/issues/21) ([verification](archive-verification.md)). Runtime and native acceptance are deferred. | [W010](https://github.com/jorgerodrigues/ure/issues/8), [W011](https://github.com/jorgerodrigues/ure/issues/9), [W019](https://github.com/jorgerodrigues/ure/issues/17), [W022](https://github.com/jorgerodrigues/ure/issues/20) |
| W026 | [Export a complete library backup (#22)](https://github.com/jorgerodrigues/ure/issues/22) ([verification](backup-export-verification.md)). Runtime and native acceptance are deferred. | [W023](https://github.com/jorgerodrigues/ure/issues/21) |
| W027 | [Validate and stage library restore packages (#23)](https://github.com/jorgerodrigues/ure/issues/23) | [W026](https://github.com/jorgerodrigues/ure/issues/22) |
| W028 | [Activate a restore with recovery after interruption (#24)](https://github.com/jorgerodrigues/ure/issues/24) | [W027](https://github.com/jorgerodrigues/ure/issues/23) |
| W029 | [Verify recovery across upgrades imports and restore (#25)](https://github.com/jorgerodrigues/ure/issues/25) | [W028](https://github.com/jorgerodrigues/ure/issues/24) |
| W030 | [Verify keyboard access and native window behavior (#26)](https://github.com/jorgerodrigues/ure/issues/26) | [W023](https://github.com/jorgerodrigues/ure/issues/21), [W028](https://github.com/jorgerodrigues/ure/issues/24) |
| W031 | [Measure and fix library browsing performance (#27)](https://github.com/jorgerodrigues/ure/issues/27) | [W022](https://github.com/jorgerodrigues/ure/issues/20), [W028](https://github.com/jorgerodrigues/ure/issues/24) |
| W032 | [Run first-release acceptance and write the handover guide (#28)](https://github.com/jorgerodrigues/ure/issues/28). Restore CI unit checks and Release builds before acceptance. | [W029](https://github.com/jorgerodrigues/ure/issues/25), [W030](https://github.com/jorgerodrigues/ure/issues/26), [W031](https://github.com/jorgerodrigues/ure/issues/27) |
