# Recoverable library verification

Recorded on 1 October 2026. W002 is implemented locally. The minimum-OS run and remote CI remain pending.

Implementation commit: `07bee8e`.

## Implementation

- GRDB 7.11.1 is the sole runtime package. The Xcode project pins the exact version. `Package.resolved` pins revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`.
- One library coordinator actor owns database access and the mutation gate. Database I/O, original-file copies, and hashing run away from the main actor. Related database changes use one transaction with foreign keys enabled.
- `active-library.json` selects a storage generation. Each generation contains a versioned library manifest, SQLite database, and managed original files. The only application table is library metadata.
- Existing libraries are checked through a read-only connection before opening a writer. Invalid pointers, missing files, corrupt databases, unsupported storage formats, and unknown migration histories produce the recovery screen. They do not create an empty replacement library.
- Internal recovery snapshots use SQLite's backup API. They copy originals under the same mutation gate, check database integrity and foreign keys, and record file sizes and SHA-256 hashes in a snapshot manifest.
- An upgrade first creates a recovery snapshot. It applies every pending migration to a new generation. It changes the active pointer atomically only after the new generation passes validation. A failed migration leaves the original database and pointer unchanged, including when an earlier migration in the same upgrade succeeded.
- Observation holds startup and recovery state. Retry rechecks the library. Settings shows the library folder.

## Verification

| Check | Result |
| --- | --- |
| `make check` | Format/lint, Debug build, and isolated unit tests passed |
| Unit cases | 26 passed |
| `make release` | Unsigned optimized Release build passed |
| Native recovery and Retry | Passed with a damaged-pointer fixture |
| Keyboard navigation and Settings | Passed |
| Light and dark window launch | Passed |
| Full `make test-ui` | Three cases passed; the existing minimum-window resize check failed |
| Resize comparison | The same width assertion failed with the same gesture against the unchanged W001 app at `daa19a4` |

The resize check leaves the native window at 1200 points wide rather than its expected maximum of 1020. The unchanged W001 app produces the same result. The W001 minimum-window gate remains pending. No test was skipped or removed to hide that failure.

On-disk cases cover first launch, repeated open, reopen, injected IDs and clock, foreign keys, transaction rollback, independently usable snapshots, unchanged originals and hashes, valid migration, several migrations with a later failure, snapshot failure, unknown migrations, damaged or missing files, unsupported format, cancellation, symbolic links, and competing mutations and snapshots. Feature-state tests cover failed startup, repeated failure, and successful retry after repairing the temporary library.

The native recovery test seeds a damaged pointer through Debug-only launch setup. The seed requires `URE_TESTING=1` and uses the injected temporary library. It checks the recovery screen and Retry without requiring the UI runner to edit the app's sandbox container. On-disk tests verify file preservation and reopening after repair. No test opens the normal user library.

## Build configuration

Adding a package exposed the existing `clang-stat-cache` stall in the package target. The optional ignored `Config/Local.xcconfig` already sets `SDK_STAT_CACHE_ENABLE = NO` on this Mac. Make now passes that file through `-xcconfig`, so it applies to both application and package targets. The workaround remains outside committed configuration and is absent from remote CI.

## Remaining limits

- A macOS 27.0 run and remote CI remain pending. The [GitHub remote](https://github.com/jorgerodrigues/ure) is configured, but no CI run has occurred.
- The existing W001 minimum-window resize gate remains pending as described above.
- Recovery snapshots and old generations are retained. No automatic retention policy or public backup/restore controls are added in W002.
- This implementation does not add watch or repair tables. W003 adds watch records.
- W031 must measure performance with its realistic library and optimized build. These small fixtures do not establish release performance.
