# Ure

Read `README.md`, `docs/planning/specification.md`, the selected issue, and its dependencies before editing. The user approved the current-platform direction. Other product choices marked proposed still need to be settled before affected implementation.

GitHub issues hold story descriptions, acceptance criteria, and current status. Use `gh issue view` to read the selected issue and its dependencies. `docs/planning/issues.md` maps the stable planning IDs to GitHub issues.

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

- Run `make check` and `make release` for changed app code. Run build and unit checks for each story. The user agreed on 2 October 2026 to defer native UI and device checks to release acceptance. Keep those tests and record their pending gates. Do not launch app tests on the user's active desktop during story implementation.
- Test behavior and failure boundaries. No test may open the normal user library. Keep the shared scheme's test marker and injected library location.
- Save test captures and result bundles under `~/Developer/test-assets/<branch>/`. Follow the `test-assets` skill and remove that folder when the branch is done.
- Record actual results. The minimum-window resize check, a macOS 27.0 run, and remote CI are pending in `docs/planning/setup-verification.md`.
- `Config/Local.xcconfig` is ignored and optional. It holds the verified SDK file-cache workaround on the development Mac. Keep machine-specific settings out of committed configuration.

Ask whether the user wants addressed review comments resolved. Do not add tool attribution or coauthor footers to commits, issues, or pull requests.
