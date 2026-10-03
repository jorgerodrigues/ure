# Library backup export verification

Recorded on 3 October 2026 for W026, issue #22. W023 (#21) is closed and merged through PR #51 at `a79d4411ceb36fb79277d276a3244375aa706a25`.

## Implementation

- Settings shows a dated summary, saved item count, original file count, estimated payload size, progress, Cancel Export, and the last successful user export time. The native save panel selects a `.watchbackup` package. The application declares its package type.
- The existing W002 snapshot service provides staging, SQLite backup, copying, and fingerprints. Recovery snapshots retain their existing format. User exports contain `library.sqlite`, `manifest.json`, `backup.json`, and `originals/`.
- `backup.json` format version 1 records the export time, library identity, application version, applied migrations, all application table counts, and payload file paths, sizes, and SHA-256 hashes. It excludes its own hash. Its byte count describes the hashed payload. Settings labels the pre-export size as an estimate.
- Every persisted file asset is copied, including an asset whose metadata exists without a library item. Untracked original-store files, import staging, thumbnails, local preferences, recovery copies, and old generations are omitted. Original filenames remain metadata. Storage paths use the existing generated keys.
- The coordinator pauses mutations, imports, original cleanup, internal recovery snapshots, and close while export runs. Reads and observations remain available. The file worker runs outside the main actor. Existing synchronous transactions and imports run without a suspension once admitted.
- The database is copied with GRDB's SQLite backup API, including committed WAL state. Output is opened independently for integrity, foreign-key, identity, migration, count, and asset checks. Staged bytes are reread and compared with declared hashes and saved asset hashes before publication.
- User exports stage in Foundation's unique item-replacement directory on the destination volume. This supports save-panel sandbox access and reuses the existing original-file export pattern. Internal recovery snapshots retain hidden sibling staging. A complete export is published by an exclusive rename or atomic directory swap. Failed copy, validation, publication, or cancellation keeps the active library and any previous destination intact. Temporary-directory and previous-destination cleanup are best effort. Filesystems without the required atomic rename support fail safely.
- Cancellation reaches the background worker and releases waiting writes. Success and the persisted export time are set only after validation and publication return. The timestamp does not prove continued availability of an external copy.
- Paper's Ure file was checked live. Its pages are Brand, Logo, macOS 27, Watches · W003, and Page 1. There is no W026 page. The macOS 27 Rules JSX and computed styles were read. Settings follows the native form, system text styles, semantic colours, and standard controls.

## Checks

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Passed, unsigned Debug |
| `xcodebuild … CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO build-for-testing` | Passed; all unit and UI test sources compiled without execution |
| `plutil -lint Config/Info.plist` | Passed; the built app contains the exported package type |
| `git diff --check` | Passed |
| Independent read-only review | Required before commit; the PR records the final verdict and any P3 findings |

The first restricted build could not write Xcode's user package caches. The build ran successfully in the normal Xcode context. The compiler caught async GRDB overload selection in the gate and an async semaphore wait in a test helper. Both were corrected. The app build retains Xcode's existing AppIntents metadata-extraction notice because the app has no AppIntents dependency.

## Behavioral sources

`BackupExportTests` covers independent exported-database and hash comparison; all three ownership scopes with real HEIC and PDF fixtures; counts and metadata; omitted caches and unknown files; concurrent queued mutations and imports with reads available; cancellation and injected disk-full failures before publication and during partial copy; missing and changed originals; staged database corruption; existing destination preservation and complete replacement; WAL inclusion; and invalid export locations. `BackupStateTests` covers summary loading, duplicate-command rejection, persisted success time, failed-export retention, cancellation, and an unavailable library. Fixtures use isolated injected library roots. The shared test scheme retains `URE_TESTING=1`.

These sources are compiled without execution during story implementation. They are not runtime pass evidence.

## Independent review

The first complete round read the full diff and all 14 changed/new file snapshots. It found a P1 sandbox failure in direct sibling staging. Export now uses Foundation's destination-volume item-replacement directory, matching `PhotoFiles.exportOriginal`. Later rounds review the complete corrected state, not only the fix. The PR records the final verdict. A preliminary session was discarded after its startup tool list included unrelated connectors. It used only Read and Glob. The replacement session exposed only Read, Grep, and Glob, with no permission denials. Read receipts verify complete diff and file coverage.

A P3 design finding remains: the snapshot service uses `exportingVersion` as a mode switch for recovery snapshots and user exports. The suggested split into separate entry points is left unchanged under the review skill's P3 rule. W026 reuses the existing staging and snapshot implementation; recovery behavior remains covered by the existing sources. The PR records the final complete-round verdict.

## Pending gates

- Execute the behavioral suites during W032. Run real disk-exhaustion checks in addition to the injected failure boundaries.
- Run native Settings, summary refresh, save-panel access, cancellation, queued Save/import behavior, Finder package presentation, and replacement checks locally on the Mac during W032. Check external volumes and a destination outside the app container.
- Run light/dark, keyboard, VoiceOver, inactive-window, minimum-size, and macOS 27.0 acceptance during W032.
- Restore CI unit execution and Release builds in W032. Current CI runs lint and unsigned Debug only. No app launch, unit/native/UI test execution, or Release build was performed for W026.
- Restore validation and activation belong to W027 and W028. This story adds no restore controls, compression package, upload, schedule, or retention policy.
