# Restore package staging verification

Recorded on 3 October 2026 for W027, issue #23. Its only dependency, W026 (#22), is closed and merged through PR #52 at `0465e4935ddfd25dd5cbf2e867aa089c135dc766`.

## Implementation

- `LibraryCoordinator.stageRestore` returns a `StagedRestore` with an independent generation identity and an activation summary. A detached worker owns package reads, copying, hashing, SQLite checks, and migrations. Cancellation reaches that worker. The active database connection and pointer are not changed. Existing reads and mutations remain available.
- Restore accepts W026's version 1 `.watchbackup` package. `backup.json` retains Codable's existing default Date encoding. Paths accept only `library.sqlite`, `manifest.json`, and the existing generated UUID keys under `originals/`. Duplicate paths, negative or zero sizes, size overflow, invalid hashes, unsupported versions, and malformed manifests fail before payload copying. Each manifest has a 16 MiB limit.
- Package directories and files open without following symlinks. Original and payload files open relative to retained directory handles. Input filenames never become destination paths. Copies use exclusive file creation inside a new `.restore-UUID` directory under the library's generations folder. Missing or extra payload entries reject the package. Regular Finder `.DS_Store` and AppleDouble `._*` metadata files are ignored and never copied. Symlinks, including ignored metadata entries, are rejected.
- Free capacity is checked against the total payload before staging and against each chunk before writing. Copies require the declared size at open and enforce it again during reads. Supported migrations also require free space for the database copy before they begin. Actual disk-full failures remain failures. Partial staging is removed on rejection or cancellation; existing generations are preserved.
- SHA-256 checks cover incoming bytes and a reread of the complete staged payload. All persisted file assets must match the exact original inventory, sizes, and hashes. Metadata-only assets are retained. Original bytes are reread again after migration. Source packages are never migrated or modified.
- Before migration, SQLite checks integrity, foreign keys, the library identity, applied migration order, table counts, and the schema produced by the supported migration prefix. Every schema row with SQL is compared, including names that start with `sqlite`. This prevents removed constraints or extra schema objects from bypassing validation. Relationship checks also cover task/part job ownership, watch cover ownership, and photo/PDF asset kinds. SQLite temporary storage is kept in memory.
- Supported forward migrations run only against the staged database. Integrity, schema, relationships, identity, and original references are checked again afterward. A complete generation moves to its new UUID location only after validation and database closure. Failed migrations do not change the active library.
- The summary includes export date, source app version, migrated table counts, original count, source payload byte count, and newly applied migrations. The payload byte count does not describe database growth during migration. Errors name the package item or `library.sqlite` and do not forward raw filesystem paths or SQL errors.
- W027 adds no screen, active-library switch, recovery snapshot, merge import, or visible Restore action. Activation and its confirmation flow remain W028.

## Checks

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Passed, unsigned Debug |
| `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO build-for-testing` | Passed; all unit and UI test sources compiled without execution |
| `git diff --check` | Passed |
| Independent read-only review | The PR records the final verdict and any remaining P3 findings. Complete diff and file-read receipts are retained in the ignored `.build/w027-review/` directory. |

The first test compilation caught a fixture using `PhotoRecord.fileAssetID` instead of its asset value. The fixture was corrected. The build retains Xcode's existing AppIntents metadata-extraction notice because the app has no AppIntents dependency. No app launch, unit/native/UI test execution, or Release build was performed.

## Behavioral sources

`RestoreStagingTests` uses isolated injected libraries and real HEIC, PNG, and PDF fixtures. Its sources cover a valid package with all three ownership scopes and an unreferenced persisted asset; a supported v2 database upgraded in staging; a deliberately failing forward migration; unsupported backup and schema versions; reordered migrations; corrupt and truncated SQLite files; malformed and oversized manifests; missing and extra assets; wrong hashes, identity, counts, and asset metadata; missing database constraints; invalid foreign keys; cross-job task/part links; file-kind mismatches; traversal and symlinks; duplicate paths; negative and overflowing sizes; initial low space, falling free capacity, disk-full writes, growing input, staged-original corruption, cancellation, and failed publication.

Rejection sources compare the active database, pointer, manifests, originals, and generation inventory before and after failure. The migration failure source also compares the source package. Another source preserves a previously validated generation after a later rejection. Successful staging checks independent database values and exact original bytes. The shared scheme retains `URE_TESTING=1`. Compilation is not runtime pass evidence.

## Independent review

The first complete round found two P2 defects. A wildcard in the schema filter could hide an extra `sqlitex_*` trigger. The filter was removed so all SQL schema objects are compared. Strict inventory validation also rejected intact packages with AppleDouble metadata from a filesystem copy. Regular `._*` files now receive the same treatment as `.DS_Store`, with symlinks still rejected. Regression sources include an extra trigger and real AppleDouble files generated with the native `copyfile` packing API. The PR records the final complete-round verdict.

## Pending gates

- Execute the restore staging suite during W032. Include real disk exhaustion and external-volume source packages alongside the injected failure boundaries.
- Exercise native source-panel sandbox access during W028/W032. This infrastructure story has no panel or app action.
- Test activation, pre-switch recovery, reader closure, interruption, rollback, UI reload, and explicit loss-of-newer-changes confirmation in W028 and W029.
- Restore CI unit execution and Release builds during W032. Current CI runs lint and unsigned Debug only. Native UI and device automation remains off CI.
- Profile large packages and check minimum macOS 27.0 behavior during release acceptance.
