# W023 archive and child removal verification

Implemented on 3 October 2026 for [W023 (#21)](https://github.com/jorgerodrigues/ure/issues/21). Dependencies W010 (#8), W011 (#9), W019 (#17), and W022 (#20) were verified closed. Their PRs #37, #39, #47, and #50 were verified merged. The clean branch `w023-archive-removal` started at `69643e20de6688ed5ae01c8aeeeccf7983d16645`.

## Scope and behavior

- Watch and caliber archive dates use W022's existing nullable columns. No migration is needed. Archive commands run through LibraryCoordinator and check saved records inside the write transaction. A watch with an open job cannot archive. Repeated archive commands keep the original archive date. Unarchive restores normal visibility without updating repair history or content dates.
- Normal Watches and Calibers lists hide archived owners. Their observations retain all saved owners for exact search, history, and existing caliber links. The caliber picker retains an existing archived link but excludes archived calibers from new choices. The service enforces that same rule. Archived caliber knowledge remains readable through linked watches. Intake snapshots are unchanged.
- Archive lists archived watches, archived calibers, and closed jobs. It uses native selection, a local Unicode text filter, saved owner context, stable IDs, failure/Retry, and the shared Save/Discard/Stay guard. Selecting a record clears prior child selections and opens the exact owner or closed job. Filter exclusion and unarchive retain readable detail. Global Include Archived continues to use W022's ancestor-aware query.
- Archived owners reject identity changes, new jobs, job reopening, scoped note/link/photo/PDF writes and imports, cover changes, and child removal. Closed-job operational guards remain in place. Native write controls and Command-S use saved owner guards. Restore an archived watch before reopening a closed job. Save and Cancel remain explicit. Immediate task-row actions remain proposed.
- Saved tasks, notes, links, photos, and PDFs have confirmed Remove actions. Task confirmation lists its current linked parts. A changed link set rejects a stale confirmation. Removal deletes task links and compacts surviving task positions in the same transaction. Part requirements, procurement snapshots, and historical activity summaries remain saved. Supplier options retain the existing confirmed draft removal and Save transaction. Part requirements use Cancelled.
- File-item deletion and removal of an asset row with no surviving item reference commit together. Watch cover foreign keys clear on photo removal. Observed selections and pinned preferences clear when their records disappear. The reference window follows the cleared pin. Unreferenced generated originals are removed only after commit. Failed file deletion is nonfatal and leaves the generated file as durable retry work. Startup checks committed storage keys before retrying. Referenced originals and unknown filenames remain untouched.
- Database and file work stay on LibraryCoordinator or existing concurrent reader functions. Existing recoverable generations, native reference boundaries, Pomme, AccentColor, search keys, original bytes, and historical payloads remain intact. No watch/job deletion, expiry trash, retention policy, or sync tombstones are added. No affected unresolved product choice is needed.

## Design inspection

Live Paper contains Brand, Logo, macOS 27, Watches · W003, and Page 1. No W023 feature page exists. The macOS main-window inline-style JSX and computed styles for light/dark windows and rules were inspected. Archive follows the existing native split-view list width, system text styles, semantic colors, and native confirmation controls. No content glass or toolbar background is added. Runtime visual acceptance remains pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug passed on the complete source.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing`: all unit and native UI sources compiled without execution.
- `git diff --check`: passed.

Initial compilation found an immutable task-position assignment, async assertion syntax, a private fixture reference, and a mutable draft captured by a Sendable query. These were fixed. Task removal returns the saved ordered records. Xcode retains its existing App Intents no-framework extraction notice. Complete concurrency checks and warnings as errors remain enabled. No app launch, test execution, Release build, capture, or result bundle ran here.

## Behavioral sources and pending gates

ArchiveServiceTests covers open-job restrictions, idempotence, archive rollback, search inclusion, existing caliber links, rejected new links and archived writes, unchanged intake/history/content dates, unarchive, and restart. ChildRemovalTests covers task-part links, changed confirmations, scope mismatch, compacted order, retained parts/activity, note/link search removal, closed/archived guards, cover removal, file rollback, shared originals, failed cleanup, restart retry, and PDF removal. ArchiveStateTests covers loaded archived owners, normal list visibility, exact archive routes, owner write guards, Save/Stay, unarchive, removal failure, cleared selection/pin/preferences, restart, and task confirmation. ArchiveUITests adds a deferred native archive/unarchive and confirmed-note-removal journey with URE_TESTING=1 and an injected library ID. Existing supplier removal and procurement snapshot sources remain current.

These sources compile without execution. Libraries and preferences are isolated. Fixed clocks are used where saved dates matter.

During W032 (#28):

- Execute behavioral tests and focused native archive/removal journeys.
- Verify archive/unarchive, Include Archived result navigation, existing caliber references, closed-job guards, failed commands, rollback, task order/progress, supplier selection/snapshot retention, cover/pin/viewer cleanup, shared asset bytes, cleanup failure and restart at runtime.
- Verify Save/Discard/Stay, pending commands, Command-S and Record menu focus, job activity routes, bench/reference windows, window closure and quit protection.
- Verify long values, duplicate labels, keyboard/VoiceOver, minimum-window/pinned-pane layouts, light/dark/inactive appearances, increased contrast, and Reduce Transparency.

Unit execution, runtime/native acceptance, and Release remain deferred to W032. UI/device automation stays off GitHub Actions.

## Review and delivery

The standing [source-sharing approval](review-approval.md) was verified against the direct W011 human reply. The original W006 instruction authorizing review, PR, CI, merge, and next-chat delivery was read. Independent review uses fresh sessions with only Read, Grep, and Glob. Exact diff and file lists remain in ignored `.build/w023-review/`; every changed/new file must be read in full. CI formatting/lint and unsigned Debug must pass on the exact final head before merge.

One fresh review round completed against the full current change. Successful full-file reads covered all 56 changed/new files. Both diff chunks covered all 1,794 lines. An attempted read used the wrong path for an unchanged import service; that did not block the required scope. The reviewer reported no P0–P2 findings. No finding was dismissed, and no source changed after review.

The review workflow explicitly leaves P3 findings for the user to decide. These five findings remain:

- In Archive with no displayed target, the Record menu can act on a watch retained from another section. The bench pane can also follow that retained selection. `WorkshopCommands.canArchive` and `WorkshopView.hasActiveJob` do not check `ArchiveState.displayedTarget`.
- Command-S does not save a watch, caliber, or job editor opened from Archive. Toolbar Save works. Task move shortcuts also omit Archive after reopening a job there.
- An archived caliber linked to a saved watch remains in its initial draft picker. Selecting a different caliber removes the archived choice from that draft. Cancel restores the original link but discards the other edits.
- Note, reference, photo, and document services retain separate owner checks rather than all using `RecordAccess.requireOwner`. The checks duplicate owner reads and use service-specific unavailable-owner errors.
- Earlier state-level write helpers and eight child-view JobState environment properties remain unused by app code. Photo/document `canSave` also retains its closed-job check, so callers combine it with `WorkshopEditing.canWrite` for the archive rule.

These are review findings confirmed by code inspection. Runtime reproduction remains deferred with the other W032 gates. Task-specific review snapshots are removed after merge.
