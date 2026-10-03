# W022 search verification

Implemented on 3 October 2026 for [W022 (#20)](https://github.com/jorgerodrigues/ure/issues/20), in [PR #50](https://github.com/jorgerodrigues/ure/pull/50). Dependencies W010 (#8), W011 (#9), W018 (#16), W020 (#18), and W021 (#19) were verified closed. Their PRs #37, #39, #46, #48, and #49 were verified merged. The clean branch `w022-search` started at `8a3d32e094ee9c5fe026b481e85ccf3e4244c504`.

## Scope and behavior

- Forward migration `v17-search` adds normalized keys to watches, calibers, jobs, notes, library items, part requirements, and supplier links. It backfills existing saved fields in Swift. It adds nullable archive dates to watches, jobs, and calibers for archive-aware search queries. No archive commands or removal UI are added.
- Normalization uses Foundation case folding with the fixed `en_US_POSIX` locale and canonical Unicode composition. It preserves accents, punctuation, and leading zeros. The same helper serves local filters. No SQLite NOCASE dependency, fuzzy matching, OCR, PDF text extraction, online search, or new search engine is introduced.
- Persistence query helpers refresh keys after source writes in the same coordinator transaction. PartService refreshes requirement and supplier keys after supplier writes. Order-time snapshot stock codes remain searchable after an option changes or is removed. Search selects current source rows, so removal immediately removes results. Failed transactions roll back source and keys together.
- One LibraryCoordinator observation queries grouped result sources and their context in one committed database snapshot. Bound arguments and `instr` make SQL characters literal. Aggregated supplier keys avoid duplicate part results. Stable kind-plus-UUID IDs distinguish duplicate labels. Database and migration work stay outside the main actor.
- Global search replaces the middle list while retaining the current detail and editor. Search Library has a toolbar action and Shift-Command-F. Loading, failure/Retry, blank-query, no-match, and navigation-error states remain separate. Include Archived is explicit. Ancestor watch/job/caliber archive state propagates to owned notes, parts, and library items. Job closure is separate from archive.
- Result navigation validates loaded saved owners and exact source records. It uses WorkshopEditing's Save/Discard/Stay and pending-command guards. It clears child selections, selects the exact watch/job or caliber, and opens the exact note, part, link, photo, or PDF. It leaves same-job activity mode through a navigation revision. Links and supplier sites still require their explicit Open actions. Closed jobs remain readable and keep existing write guards. Bench references and restricted reference-window commands retain their boundaries.
- Existing section filters share normalization. Scoped job history, notes, parts, links, photos, and PDFs have local text filters. Photo stage and text combine. Filters preserve open details. Existing Save/Cancel editors, data, originals, cover references, intake snapshots, procurement events, and progress semantics are retained.

## Design inspection

Live Paper contains Brand, Logo, macOS 27, Watches · W003, and Page 1. No W022 feature page exists. The macOS main-window inline-style JSX and computed styles for light/dark windows and rules were inspected. Search uses the existing native 320-point middle list, native controls, system text styles, and semantic colors. Pomme and AccentColor are retained. No content glass or toolbar background is added. Native visual acceptance is pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO build-for-testing`: all unit and native UI test sources compiled without execution.
- `git diff --check`: passed.

The initial restricted build failed on Xcode/Swift package cache writes. Its automatic diagnostic bundle was moved to `~/Developer/test-assets/w022-search/`. The normal-cache build found a missing GRDB import and an onAppear argument label. Both were fixed before passing checks. Xcode retains the existing App Intents no-framework notice. Complete concurrency checks and warnings as errors remain enabled. No app launch, test execution, Release build, or screen capture ran.

## Behavioral sources and pending gates

SearchQueriesTests covers every specified field, non-Latin Unicode case matching, composed/decomposed accents, leading zeros, punctuation, quotes, percent/underscore/brackets/backslash, SQL-looking text, duplicates, no matches, migration backfill, restart, preserved originals and records, edited keys, rollback, removal, archive ancestry, and retained supplier snapshot stock codes.

SearchStateTests covers failure/retry and blank queries, observed supplier edits/removal, rollback across global/local lists, exact child navigation in every supported scope, top-level navigation, clearing child selections, closed-job reads, Stay/Save/Discard, failed-save draft retention, and removed results. SearchUITests adds a deferred native journey for duplicate notes, Unicode references, the keyboard command, draft protection, same-job timeline routing, and no matches. The earlier migration fixture chain now removes v17 before constructing older schemas.

These sources compiled. Their behavior has not been executed. Libraries are isolated. Fixed clocks are used where saved dates affect behavior. Native sources retain URE_TESTING=1 and the injected library ID.

During W032 (#28):

- Execute behavioral tests and the focused native search journey.
- Verify live observation, key refresh, rollback, migration/recovery, archived ancestry, removal, exact navigation, unavailable/loading source errors, and retained detail with local filters.
- Verify Save/Discard/Stay, failed Save, pending commands, same-job activity navigation, bench panes, focused reference-window commands, and window/quit guards.
- Verify long titles and contexts, keyboard activation and focus, VoiceOver, minimum-window and pinned-pane layouts, light/dark/inactive appearances, increased contrast, and Reduce Transparency.
- Profile an optimized build with a realistic library before changing query machinery. Contains matching may scan normalized fields; no performance acceptance is claimed here.

Unit execution, runtime/native acceptance, and Release remain deferred to W032. UI/device automation stays off GitHub Actions.

## Review and delivery

Source sharing uses the standing [read-only review approval](review-approval.md), verified against the direct W011 human reply. The original W006 human instruction for review, PR, CI, merge, and next-chat delivery was read. Independent review uses only Read, Grep, and Glob. Exact diff and file-list snapshots remain inside ignored `.build/w022-review/`; each changed/new file must be read in full. CI formatting/lint and unsigned Debug must pass on the exact final head before merge.

Round one identified a P2 context-label defect: calibers with the same designation and different variants looked identical in search. The query now uses the saved designation-plus-variant label for caliber rows and all caliber-owned result context. A regression source covers duplicate designations, notes, and links. The order-snapshot test fixture was also corrected to save Needed before transitioning to Ordered.

Three P3 suggestions remain under the review skill's P3 rule: retain local filter text in feature state (including viewer navigation), remove search-key indexes that contains queries cannot use, and aggregate supplier option codes into the requirement key to remove duplicate query joins. These are optional follow-up decisions. No finding was dismissed or dropped.

Round two confirmed the caliber variant fix and every affected write path. It ended with "No findings cleared the bar." The read trace verified the exact diff and all 40 changed/added files in full, with no blocked reads, tool errors, or permission denials. Both rounds used fresh read-only sessions with no shell or edit tools. No finding was dismissed or dropped. Lint, unsigned Debug, all unit/native UI source compilation, and whitespace checks passed after the fix. No tests were executed.

CI results are available in [PR #50 checks](https://github.com/jorgerodrigues/ure/pull/50/checks). Both formatting/lint and unsigned Debug steps are checked on the final head before merge. No GitHub comments or review threads existed when the PR opened. Runtime and native acceptance remain deferred. The automatic diagnostic bundle is removed after merge.
