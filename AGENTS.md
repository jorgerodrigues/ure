# Ure

Read `README.md`, `docs/planning/specification.md`, the selected issue, and its dependencies before editing. The user approved the current-platform direction. Other product choices marked proposed still need to be settled before affected implementation.

## Platform and design

- Target macOS 27 and Apple silicon. Use Xcode 27 or later and Swift 6 language mode. Do not add older-OS fallbacks.
- Use SwiftUI and Observation for UI and feature state. Use AppKit or PDFKit only where needed.
- Use native navigation, controls, menus, focus, and window behavior. Let the system supply appearance and accessibility adaptations.
- Keep views small. Views render state and forward commands. Feature state owns loading and drafts. Services own validation, mutations, and effects. Persistence owns SQL and migrations.
- Build only the selected issue. Do not add later-feature placeholders, speculative caches, or a protocol for every type.

## Concurrency and performance

- Keep Swift 6 complete concurrency checking and warnings as errors enabled.
- UI code defaults to the main actor. Immutable values can explicitly be nonisolated and Sendable.
- Move database I/O, file I/O, hashing, and image decoding off the main actor. Use dedicated actors or `@concurrent` work where appropriate. `async` alone does not move work off the main actor.
- Keep Observation reads close to the views that need them. Use stable record IDs in lists.
- Decode thumbnails for lists. Load full originals only for viewing. Preserve original bytes.
- Profile optimized Release builds with realistic data before adding a performance abstraction. Report measured results and remaining limits.
- Do not use force unwraps, force casts, force tries, or unchecked Sendable to silence errors.

## Verification

- Run `make check` and `make release` for changed app code. Run focused native UI tests for changed interactions.
- Test behavior and failure boundaries. No test may open the normal user library. Keep the shared scheme's test marker and injected library location.
- Save test captures and result bundles under `~/Developer/test-assets/<branch>/`. Follow the `test-assets` skill and remove that folder when the branch is done.
- Record actual results. UI automation authorization, a macOS 27.0 run, and remote CI are pending in `docs/planning/setup-verification.md`.
- `Config/Local.xcconfig` is ignored and optional. It holds the verified SDK file-cache workaround on the development Mac. Keep machine-specific settings out of committed configuration.

Ask whether the user wants addressed review comments resolved. Do not add tool attribution or coauthor footers to commits, issues, or pull requests.

