# W015 part requirements verification

Implemented on 3 October 2026 for [W015 (#13)](https://github.com/jorgerodrigues/ure/issues/13), in [PR #43](https://github.com/jorgerodrigues/ure/pull/43). Dependency W006 (#4) was verified closed and [PR #33](https://github.com/jorgerodrigues/ure/pull/33) merged before implementation. The clean branch started at f92a0ec847f9c81f72889aa606aca9f79f3c50a0 on the default branch after W014 merged.

## Scope and behavior

- Parts belong to one job. Description and a positive whole-number quantity are required. Quantity defaults to 1. Manufacturer reference is optional text that preserves leading zeros and punctuation. Each requirement tracks one whole unit or lot. New requirements start Needed. The shared status type includes the specified procurement statuses, but W015 exposes no transitions.
- Compatibility is Unchecked, Confirmed, or Unsuitable. Confirmed requires an evidence note. Optional notes are retained for every assessment.
- Each part has zero or more PartLink records. A complete HTTP/HTTPS URL is the only required link field. Add link works during creation and editing. Every saved link has an explicit Open action. Saving, loading, and selection perform no network request and open no external content. Browser opening uses the injected native service action. Removing a saved link requires confirmation and commits with Save. Cancel keeps the saved links.
- Part and link writes use one LibraryCoordinator transaction. Ownership, validation, and the current open job are rechecked there. A link failure rolls back the part edit, removals, and other link writes. Pending saves block duplicates and navigation. Failed saves preserve the whole draft. Save, Cancel, Command-S, navigation, window closure, and quit use the existing editing guard. Closed jobs remain readable with explicit Open actions; operational writes are disabled and stale editors are rejected by the service.
- Job closure now includes the saved parts summary required by specification section 6. Needed or Ordered parts require a separate unresolved-parts explanation. The service rechecks saved requirements during closure. Closure keeps part and task statuses and saves the explanation in the same transaction as the job transition and history. Reopening clears the current parts explanation and retains history. The existing task explanation is unchanged. The shared closure Save gate requires both summaries for the button, Command-S, and navigation Save.
- The v13-part-requirements migration adds partRequirement, partLink, their owner indexes, and the job's optional parts explanation. It changes no existing records, cover references, or originals. Earlier migration fixtures remove this schema when constructing old libraries. Historical job events decode without the new optional explanation.
- No supplier metadata, pricing, comparison, receipt tracking, procurement actions, task-part links, stock, recommendations, accounting, estimates, overview, or timeline UI is added. W007 note behavior and proposed immediate task status actions are unchanged. Pomme, AccentColor, the pinned reference pane, and the restricted reference window are unchanged.

## Design inspection

The live Paper file has Brand, Logo, macOS 27, Watches · W003, and Page 1. No W015 feature page exists. The macOS rules were read as JSX. The light/dark main-window artboards and rules computed styles were inspected. Parts follow the existing native Form, system text styles, controls, and semantic colors. No content glass or toolbar background is added. Native visual acceptance is pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing`: all unit and native UI test sources compiled without execution.
- `git diff --check`: passed.

The first build needed access to Xcode package caches. Initial test-source compilation found the new XCTest class's default actor isolation and a mutable browser closure capture. The test class now follows the existing nonisolated XCTest pattern. The browser spy follows the existing main-actor test pattern. Xcode retains the existing App Intents no-framework extraction notice. Complete concurrency checks and warnings as errors remain enabled.

## Behavioral sources and pending gates

PartServiceTests covers compatibility values, positive whole quantity validation, exact references, unknown references, zero and several URL-only links across restart, invalid URL schemes, database constraints, job and link ownership, duplicate link IDs, partial-write rollback and retry, stale closed-job writes, both closure stages, unresolved explanations and history rollback, reopening, and forward migration with old records and original bytes preserved.

PartStateTests covers empty and failed loading, retry, field errors, whole-draft retention on failure, Save/Stay/Discard navigation, pending duplicate saves, scope selection, observation without replacing a draft, link-removal confirmation, stale closed-job drafts, and explicit browser opening only after user action. Existing editing fixtures now inject parts. The closure gate regression requires both task and parts summaries. PartUITests defines a deferred native journey for quantity and URL errors, unknown references, compatibility evidence, multiple links, Command-S, Stay, restart, closure explanations, and read access on closed jobs.

These sources are compiled during story implementation. Their behavior is not executed here.

- W032 executes behavioral tests with isolated libraries and URE_TESTING=1.
- Verify save failures, duplicate clicks, removal confirmation, stale closure, ownership, and migration rollback at runtime.
- Verify Save/Discard/Stay on navigation, window closure, and quit. Verify Command-S and reference-window focus with a part draft.
- Verify links remain stored after restart and open only from Open. Check default-browser failure and all saved URLs.
- Verify long descriptions/references/URLs, minimum-window resizing, pinned references, keyboard focus, VoiceOver, light/dark and inactive windows, increased contrast, and Reduce Transparency.
- Unit execution, Release builds, runtime and native UI acceptance remain deferred to W032. No app tests, Release build, or captures run here. Xcode automatically created a diagnostic bundle during the first sandbox cache failure. It was moved to the W015 test-assets folder for cleanup after merge. UI/device automation stays off GitHub Actions.

## Independent review and CI

The standing [read-only source review approval](review-approval.md) was verified against the direct human reply in W011 chat 01a0fcc4-1481-7661-b6a6-f81ea2d06414. Round one returned no findings and no blocked source reads, with two permission denials. Unavailable unrelated connectors were not needed.

After round one, the implementation agent checked the installed GRDB UUID conversion and found that `fetchOne(key: UUID)` binds binary UUID data while the library records encode IDs as uppercase text. The link lookup now passes `uuidString`. This preserves existing link timestamps and rejects links owned by another requirement. The existing timestamp-retention and foreign-link ownership regression sources cover the case. All local checks are rerun before a fresh full review of the corrected source.

Round two returned "No findings cleared the bar." It completed without permission denials or blocked source reads. Independent review is clear after two rounds. Lint, the unsigned Debug build, and all unit/native UI source compilation passed again on the corrected source. No reviewer findings were declined and no P3 suggestions remained.

CI runs Swift lint and an unsigned Debug build. Both gates must pass on the final PR commit. Final results are available in [PR #43 checks](https://github.com/jorgerodrigues/ure/pull/43/checks). Runtime and native acceptance remain deferred to W032.
