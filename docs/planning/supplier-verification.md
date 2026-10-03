# W016 supplier comparison verification

Implemented on 3 October 2026 for [W016 (#14)](https://github.com/jorgerodrigues/ure/issues/14), in [PR #44](https://github.com/jorgerodrigues/ure/pull/44). W015 (#13) was verified closed and [PR #43](https://github.com/jorgerodrigues/ure/pull/43) merged before implementation. The clean branch started from default-branch commit 9edd2b69e7b7c1e5adc18bfa3b5b19f31c6c8301.

## Product decision

On 3 October 2026, the user approved optional exact supplier price and validated currency in this W016 chat. Specification section 1 now records that approval. Other proposed product defaults remain unchanged.

## Scope and behavior

- The existing PartLink records gain optional supplier name, listing title, supplier stock code, price, currency, and notes. Adding supplier details preserves the link's ID, URL, created time, and saved order. URL-only identification or product references remain valid. Manufacturer references and supplier stock codes remain separate text fields.
- Prices use non-negative ASCII decimal text with an optional point and digits on both sides. Leading zeros and all trailing decimal digits remain intact. No floating-point conversion, rounding, totals, or currency conversion occurs. A price requires a currency. Currency input is normalized to uppercase and checked against Foundation's local [common ISO currency codes](https://developer.apple.com/documentation/foundation/locale/commonisocurrencycodes). Invalid currency codes are rejected even when price is empty. A valid currency can be recorded while price remains unknown. SQL constraints also protect decimal syntax, currency shape, and the required currency when a price is present.
- A part can have one selected link or no selection. Selection is stored on the existing link. A partial unique database index allows at most one selected link for each part. This avoids a separate selection reference that could point to another part. The service validates selected IDs and existing link ownership in the same LibraryCoordinator transaction as all writes.
- The part editor uses the existing explicit Save, Cancel, Command-S, and draft-protection paths. A failed save retains all fields and selection. Pending saves block selection, metadata changes, removals, duplicates, and navigation. Observation updates saved records without replacing the draft.
- Saved-link removal requires confirmation. Removal clears that draft's choice and commits with Save. Cancel retains the saved choice, link, and details. Database failures roll back the part edit, choice change, removals, and other link writes together.
- Closed-job supplier records remain readable. The editor and Save are disabled. The service rechecks the saved open job and rejects stale metadata, selection, and removal writes. Explicit browser opening remains available for reading. Save, loading, and supplier selection never fetch or open external content.
- The v14-supplier-options forward migration adds nullable metadata and an unselected default to the existing links. It preserves their IDs, owners, URLs, positions, and timestamps. Earlier part/task migration fixtures remove the added migration record when reconstructing older schemas. Existing jobs, tasks, history, watch covers, photos, and original bytes remain unchanged.
- Procurement transitions, receipts, purchasing, scraping, conversion, stock, recommendations, task-part links, accounting, estimates, overview, and timeline remain outside this issue. Existing job/part/task status rules, bench references, navigation boundaries, Pomme, and AccentColor remain unchanged.

## Design inspection

The live Paper file contains Brand, Logo, macOS 27, Watches · W003, and Page 1. There is no W016 feature page. The macOS Rules artboard was read as JSX. Computed styles for the rules and both main-window artboards were inspected. Supplier fields use the existing native grouped Form, native checkboxes, system text styles, and semantic colors. No content glass or toolbar background was added. Native visual acceptance remains pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing`: all unit and native UI test sources compiled without execution.
- `git diff --check`: passed.

Xcode retains the existing App Intents no-framework extraction notice. Complete concurrency checks and warnings as errors remain enabled. No app launch, test execution, Release build, capture, or result bundle was requested or run.

## Behavioral sources and pending gates

PartSupplierServiceTests covers metadata added to existing URL-only links, several options, exact stock/manufacturer text, arbitrary decimal precision across restart, leading/trailing zeros, zero price, missing and invalid currencies, malformed prices, currency-only records, clearing price/currency, database price constraints, switching and clearing selection, restart persistence, no-op timestamp retention, foreign selected IDs, foreign links, database uniqueness, selected-link removal, partial-write rollback and retry, stale closed-job writes for both closure stages, and migration with parts, links, jobs, tasks, history, photo/cover references, and original bytes preserved.

PartStateTests covers whole-draft retention, price/currency field errors, selection ownership, removal confirmation, clearing a draft selection, Cancel/Discard retaining saved links, pending-save command protection, observation without draft replacement, stale closed-job editors, and browser opening only after explicit Open. PartUITests adds a deferred native journey for supplier details, exact codes and prices, missing and invalid currency errors, choosing between several options, restart, selected-link removal, Cancel, Command-S, and retained alternative links.

These test sources were compiled. Their behavior was not executed.

- W032 executes behavioral tests with isolated libraries and URE_TESTING=1.
- Verify metadata, selection, removal, cancellation, failed saves, rollback, migration, and stale closure at runtime.
- Verify keyboard and VoiceOver labels, long supplier/title/code/notes/URLs, minimum-window resizing, pinned references, main/reference-window focus, both appearances, inactive windows, increased contrast, and Reduce Transparency.
- Unit execution, native UI acceptance, runtime acceptance, and Release builds remain deferred to W032. UI/device automation remains off GitHub Actions.

## Review and delivery

The standing read-only source-sharing approval was verified against the original direct human reply in W011 chat 01a0fcc4-1481-7661-b6a6-f81ea2d06414. Independent review of the current supplier metadata and selection work completed in one fresh round with "No findings cleared the bar." No source reads were blocked. One denied Bash command attempted to read GitHub issue #14. The repository and implementation scope were available to the reviewer. No findings were dismissed and no P3 suggestions remained.

After price/currency approval, a fresh full-scope review returned "No findings cleared the bar." It completed with no permission denials or blocked source reads. Both reviews found no actionable issues, and no findings were dismissed or left as P3 suggestions. Lint, the unsigned Debug build, all unit/native UI source compilation, and diff whitespace checks passed on the full implementation. No tests were executed.

CI runs formatting/lint and an unsigned Debug build. Both must pass on the final PR commit before merge. Final results are available in [PR #44 checks](https://github.com/jorgerodrigues/ure/pull/44/checks). There were no GitHub comments or review threads when the PR opened. Runtime and native acceptance remain deferred to W032.
