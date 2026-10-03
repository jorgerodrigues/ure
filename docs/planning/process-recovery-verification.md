# Process recovery verification

Recorded on 3 October 2026 for W029, issue #25. Its dependency W028 (#24) is closed and merged through PR #54 at `2d65359d838bda580f848cac19cabe33ae114c60`. Its final head `4fa349a159cf54f573bab930e56c1cc816da51ce` passed the actual `verify` CI job.

## Implementation

The `UreRecoveryHarness` Debug command-line target uses the app's existing sources, pinned GRDB product, Swift 6 settings, complete concurrency checks, and warnings as errors. Its separate entry point never starts the app or native UI. A small Python standard-library driver creates isolated libraries and invokes worker processes with explicit injected locations and `URE_TESTING=1`.

At a selected checkpoint, the worker writes a marker and sends itself `SIGKILL`. No Swift error, cancellation, close, catch, or defer runs at that interruption. The parent requires both the exact marker and the actual signal exit. A missing checkpoint is a failure. Every worker has a 60-second timeout. Each recovery uses a fresh process and the normal coordinator, followed by another fresh open to check replay safety.

Frozen v10 PDF and v15 procurement schema dumps retain saved records, UUIDs, original PNG/PDF bytes, cover ownership, Unicode notes, leading-zero codes, and an exact supplier price. They load directly into on-disk SQLite libraries. Supported migrations run through the production migrator. A custom final migration deletes a note inside its transaction before the forced kill. This also checks an interrupted transaction after the real earlier migrations committed in the unpublished candidate. The old active generation stays unchanged. New upgrade checkpoints expose recovery, migration, and pointer publication boundaries. A checkpoint failure after publication keeps the published generation rather than removing it.

Recovery assertions check integrity and foreign keys, all table counts, stable IDs and existing column values, original size and SHA-256, exact original/PDF bytes, backup manifest inventories and hashes, retained generations and complete recovery copies. Import sources are removed before recovery. PDF imports and export copies include more than two 1 MiB chunks. Repeated opens keep the same pointer, data, and generation inventory.

## Reproduced failure and fix

The first run passed all 12 import cases, then a backup retry failed. Foundation returned an item-replacement directory under `/var` but enumerated its originals under `/private/var`. The snapshot fingerprint sliced the longer file path using the shorter staging-root length. It declared `hbackup/originals/<key>` and failed validation of a complete original.

A separate Foundation check reproduced both path spellings and the wrong relative path. Snapshot copying and fingerprints now derive relative paths from consistently resolved roots and check containment. The existing export behavioral sources already verify independent payload paths, sizes, and hashes. The new process matrix exercises this failure during export retries and normal exports.

## Interruption matrix

Run `make recovery XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`.

| Scenarios | Boundaries | Required recovery |
| --- | --- | --- |
| 12 photo/PDF imports | First copied chunk, before rename, after rename, before commit, after commit, before failed-import cleanup | Uncommitted rows roll back; partial and unreferenced originals clear; committed item and complete original survive source removal |
| 8 exports | Copied database, first original chunk, before validation, before publication; both new and existing destinations | No new successful package before publication; previous destination bytes unchanged; retry publishes a valid complete package |
| 12 earlier-schema upgrades | After recovery, before migration, inside a destructive transaction, after migration, before switch, after switch; v10 and v15 | Retained generation bytes unchanged; successful retry preserves existing counts, IDs, values and originals; complete pre-upgrade copies remain |
| 14 restore activations | Before recovery, after recovery, before switch, after switch, before first open, after first open, before rollback; current and retained v10 packages | Either complete current or complete restored generation opens; old generation and complete pre-restore copy remain; package bytes unchanged |
| 3 restore staging interruptions | First copied chunk, before migration, before publishing candidate | Current generation stays complete; retry can stage and activate |
| 2 pre-restore recovery interruptions | Copied recovery database, before publishing recovery copy | No pointer switch; complete current generation opens; retry can restore |
| 7 damaged/failed opens | Malformed or missing pointer, truncated or missing database, malformed manifest, future migration, blocked recovery directory | Two fresh failed opens preserve all existing library bytes and never create an empty replacement |

## Checks

| Check | Result |
| --- | --- |
| Standalone process matrix | Passed all 58 scenarios in the normal local context; final run evidence is under ignored `.build/recovery-runs/f826ee8c-0ccb-49e6-a81a-51b4e664bdb2/` |
| `make lint` | Passed |
| `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Passed, unsigned Debug |
| `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO build-for-testing` | Passed; unit and UI sources compiled without execution |
| `git diff --check`, Python syntax, Xcode project plist | Passed |
| Independent read-only review | Required before publication; the PR records the final verdict. Complete diff and changed/new snapshot read receipts are retained under ignored `.build/w029-review/` |

The final matrix used the same Debug worker built by `make recovery`. Its direct rerun added independent backup-manifest assertions and large-PDF export copies. Xcode retained the existing AppIntents metadata-extraction notice. No Swift compiler warnings or errors remained. A restricted runner changed Foundation's item-replacement behavior and created a zero-byte destination placeholder. That run failed its unpublished-export assertion. The normal local run passed. Native app-sandbox save-panel behavior remains a separate W032 gate.

## Pending acceptance gates

App unit execution, native UI journeys, sandbox file-panel access, minimum macOS 27.0, and Release builds remain deferred to W032. Current CI runs formatting and an unsigned Debug build. No app test or native UI automation ran for this story. The process harness runs locally and does not change CI policy.

These checks prove process interruption at instrumented boundaries. They do not simulate a power failure, filesystem journal loss, or every instruction during a system rename. Real disk exhaustion, filesystem permission failures during rollback, external-volume behavior, and physical UI acceptance remain W032 gates. Interrupted unpublished staging directories and old complete generations are retained; the matrix checks safe repeated opens and import cleanup, not a new generation-retention policy.
