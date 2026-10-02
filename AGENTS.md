# Ure

## Workflow

- Read `README.md`, `docs/planning/specification.md`, and the surrounding code before editing.
- Read the selected GitHub issue and its dependencies with `gh issue view`. `docs/planning/issues.md` maps planning IDs to issues. Start only after dependencies are merged.
- Settle proposed product choices before affected implementation. Keep changes within the assigned scope. Do not prebuild later features.
- After verification, commit, push, and open a PR. Include actual check results and any untested acceptance gates.
- Ask whether addressed review comments should be resolved. Never add tool attribution or coauthor footers.

## Development

- Target macOS 27 and Apple silicon with Xcode 27 or later and Swift 6. No older-OS fallbacks.
- Use SwiftUI, Observation, and native controls. Use AppKit or PDFKit where needed. GRDB is the sole approved runtime package.
- Views render state and forward commands. Feature state owns loading and drafts. Services own validation and effects. Persistence owns SQL and migrations.
- Route library access through `LibraryCoordinator`. Preserve existing data and original files. Use forward migrations. Never replace a failed library with an empty one.
- Keep complete concurrency checks and warnings as errors. Move database, file, hashing, and image work off the main actor. `async` alone does not do this.
- Do not use force unwraps, force casts, force tries, or unchecked `Sendable`.
- Use stable list IDs and thumbnails. Load originals only for viewing. Profile Release builds with realistic data before adding caches or extra layers.

## Verification

- During rapid implementation, run `make lint` and `make build` for app changes. Keep behavioral tests current and compile affected tests when needed. Build commands and local setup are in `README.md`.
- CI runs formatting/lint and an unsigned Debug build only until W032. Restore unit test execution and the Release build in CI as part of W032 before first-release acceptance. Release builds are not a required per-story gate during this phase.
- Never run macOS or iOS UI tests on GitHub Actions. Skip all tests that need UI or device automation on CI.
- Run focused macOS UI tests locally on the Mac during W032 release acceptance. Do not run them during story implementation or routine edit cycles. Use simulator devices for local iOS UI automation.
- Test behavior and failure boundaries. Tests must use isolated libraries. Keep `URE_TESTING=1` and the injected library location.
- Save captures and result bundles under `~/Developer/test-assets/<branch>/`. Follow the `test-assets` skill. Remove the folder when the branch is done.
- Keep machine-specific settings in ignored `Config/Local.xcconfig`. Record verification evidence and pending gates in `docs/planning/`.
