# Restore activation verification

Recorded on 3 October 2026 for W028, issue #24. Its only dependency, W027 (#23), is closed and merged through PR #53 at `4e181eb94363687634af6c3836f4a7a19f12d468`.

## Implementation

- Settings uses the native open panel to select a `.watchbackup` package. W027 validates and stages it. The review shows the export date, app version, migrated table counts, original count, source payload size, and whether migrations ran. Replacement consequences appear before a separate destructive confirmation. The command consumes a private pending candidate, independent of alert presentation state. Cancel clears that pending confirmation and keeps the reviewed copy available. Cancelling removes only the registered candidate. A failed activation before the switch returns that same registered candidate for retry or cancellation. Repeated failures do not stage more copies. Normal quit cancels staging and discards a reviewed candidate before termination. A failed discard keeps the candidate available and stops termination. There is no record merge.
- Restore rejects unsaved drafts, pending saves or imports, pending navigation, and active backup exports. The same guard runs when confirmation is accepted. Existing reads and editing remain available during staging. The app blocks normal termination during activation.
- `LibraryCoordinator.activateRestore` waits for an active export and serializes against existing database and file operations. It permanently retires the old coordinator before activation can suspend. It removes that coordinator's database and library handles. Old services, queued commands, imports, reads, and attempts to reopen cannot reach either active generation through that retired boundary. A fresh coordinator serves the reopened library.
- Activation accepts only a candidate registered by that coordinator. It checks the candidate's schema, integrity, foreign keys, identity, table counts, asset paths, and original hashes again. Recovery sizing, snapshots, hashing, pointer writes, database closure, and validation run on the library actor rather than the main actor.
- Before switching, the current database is copied with GRDB's backup API and all originals are copied into a separate recovery directory. A free-space precheck and actual copy failures prevent the switch. The recovery database, identity, schema, required originals, and original hashes are checked before proceeding. The existing internal `snapshot.json` format stays separate from public backups.
- Readers and the writer close before the atomic active-pointer write. The new coordinator opens the complete staged generation. The old complete generation and recovery copy remain saved after success. A failure before switching keeps the current pointer. A failed first open restores the retained pointer and opens the current generation. Failed rollback or reopen produces a recovery result without an empty replacement. Retry operates through the normal library recovery screen.
- A `WorkshopSession` holds the existing feature state as one lifetime. Activation clears saved bench selections, stops its observation, removes the old main content, and resets reference-window content. Every feature state, reader, command binding, and backup state is recreated for the returned coordinator. Session IDs also reset view-local search, timeline, viewer, and selection state. A failed attempt that reopens the current generation reloads the screens too.
- Settings shows the outcome and recovery directory. **Show Recovery Copy in Finder** reveals a saved recovery copy. An unsuccessful attempt that could not save a complete recovery copy reports failure and leaves the current pointer unchanged.
- Paper's current file has no W028 page or restore artboard. The macOS 27 Rules JSX and computed styles were read. The UI uses the existing grouped Settings form, native buttons and alert, system text styles, and semantic colours. It adds no toolbar background or glass content.

## Checks

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Passed, unsigned Debug |
| `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO build-for-testing` | Passed; all unit and UI sources compiled without execution |
| `git diff --check` | Passed |
| Independent read-only review | The PR records the final verdict and any findings. Full diff and changed/new file-read receipts are retained under the ignored `.build/w028-review/` directory. |

The restricted build context could not write Xcode package caches. The build was rerun in the normal local build context. The first test compilation caught an asynchronous-context semaphore wait in a test helper. The wait now runs in a synchronous helper on a detached task. Xcode retains its existing AppIntents metadata-extraction notice because the app has no AppIntents dependency. No app launch, unit/native/UI test execution, or Release build was performed.

## Behavioral sources

`RestoreActivationTests` uses isolated injected libraries and real original bytes. Sources cover replacement versus newer current data, a complete recovery database and original store, retained generation bytes, an existing observation, retired reads/writes/imports/reopen attempts, restart, failure before recovery and pointer switch, failure after switch and first open, corrupted first open, rollback failure, initial insufficient space, snapshot write failure, missing current originals, and a queued stale write. Interruption sources save the pointer at each boundary and reopen from that exact persisted pointer after connections close. They compare the selected generation's records and original bytes. Compilation is not runtime pass evidence.

`RestoreStateTests` covers cancellation after review, explicit confirmation, repeated confirmation, draft rejection both before selection and after review, preservation of draft text, reset of open reference state, fresh state for every feature, reset navigation and search, refreshed backup counts, a useful outcome with a recovery location, repeated low-space failures without extra copies, and candidate cleanup before termination, confirmation after presentation clears, and rejection of cancelled or replayed confirmation.

## Pending gates

- Execute the behavioral suites during W032. W029 can extend interruption and rollback coverage before that runtime gate.
- Perform real process termination at the pointer and first-open boundaries. The compiled sources simulate persisted interruption state; no process was killed during implementation.
- Exercise the native open panel and security-scoped package access. Verify Save/Cancel draft guidance, confirmation cancellation, all main screens, open photo/PDF/reference windows, Finder reveal, and recovery Retry on the Mac.
- Check real disk exhaustion, a damaged current original, rollback filesystem permission failures, and external-volume packages during acceptance.
- Restore CI unit execution and Release builds in W032. Current CI runs lint and unsigned Debug only. Native UI and device automation remains off CI.
- Check macOS 27.0, light/dark appearances, keyboard use, and accessibility at release acceptance.
