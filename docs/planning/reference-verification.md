# W008 technical reference verification

Issue: [#6](https://github.com/jorgerodrigues/ure/issues/6). PR: [#35](https://github.com/jorgerodrigues/ure/pull/35). Branch: `w008-technical-links`. Checked on 2 October 2026 with Xcode 27 on Apple silicon.

## Delivered behavior

- The forward `v7-library-links` migration adds `LibraryItem` with Link kind. Foreign keys and a CHECK constraint require exactly one watch, job, or caliber owner. Existing rows and original files use the coordinator's recovery snapshot and generation upgrade.
- Watch, job, and caliber details have separate reference sections. Several links can belong to each scope. Each link has a required title and HTTP or HTTPS URL, optional source description, and plain-text notes. Source description and notes preserve spacing, line breaks, and Unicode.
- Save, Cancel, Command-S, and the shared Save/Discard/Stay guard cover reference drafts. Validation errors and failed writes retain the draft. Pending saves block duplicate actions and navigation. Browser opening is a synchronous main-actor command.
- Links are labelled External reference. Saved detail explains that linked content is not saved offline. Only Open in Browser calls the injected browser opener. Loading, selection, editing, and saving do not open or fetch a URL. The open command revalidates the selected saved record before opening the default browser.
- Job writes call `JobService.requireOpenJob` inside the coordinator's database transaction. Completed and Cancelled jobs remain readable and their links can be opened. Add Link and Edit Link stay disabled until reopening. A stale editor retains its draft when the service rejects a closed-job write.
- No scraping, downloads, previews, embedded browser, file import, photos, PDFs, or reference pane are added. W007 note selection and plain-text behavior are unchanged.

## Actual checks

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Unsigned Debug build passed |
| `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug SDK_STAT_CACHE_ENABLE=NO build-for-testing` | Unit and native UI test sources compiled without execution |
| `git diff --check` | Passed |
| Independent review | Two full rounds completed; no P0-P2 findings remain |
| GitHub CI | [Run 36994813189](https://github.com/jorgerodrigues/ure/actions/runs/36994813189) passed formatting and unsigned Debug build |

The local cache workaround was passed as a command flag. No machine-specific settings were committed. Xcode emitted its existing App Intents metadata message because these targets do not use AppIntents. Swift compiler warnings remain errors.

## Behavioral test sources and pending gates

`ReferenceServiceTests` covers HTTP and HTTPS parsing, forbidden schemes, relative and malformed URLs, multiple links per scope, restart persistence, source-context preservation, immutable owner and creation time, owner constraints and missing references, closed-job writes and reopening, safe opening of saved URLs, browser failure, and migration preservation of watches, calibers, jobs, notes, events, and original bytes.

`ReferenceStateTests` covers validation and cancellation, scope filtering, observed refresh without draft replacement, Save/Discard/Stay, failed-write draft retention, duplicate-save protection and blocking browser opening during a pending save, closed-job stale drafts, loading failure and retry, and a browser test double showing no opening during loading, saving, selection, or draft editing.

These tests were compiled, not executed. By agreement, no app tests ran on the user's active desktop. Unit execution and Release builds return to CI in W032 (#28). Native UI acceptance, Command-S, window-close and quit prompts, minimum window size, VoiceOver, system appearances, actual default-browser opening, and the minimum-OS run remain release-acceptance gates. Native UI and device automation must never run on GitHub Actions. The shared scheme's `URE_TESTING=1` marker and isolated library locations are retained.

## Independent review

The first round raised one P2 design finding about an unnecessary database reread before browser opening. The final implementation uses the selected saved record and a synchronous main-actor command. The added browser-opening busy state and task were removed. The pending-operation test now verifies that an actual pending save blocks browser opening and navigation. The revised branch passed lint, unsigned Debug build, and compilation of all test sources.

The second full round found no P0-P2 issue. One P3 suggestion remains: notes and library items could use one shared owner type. The separate feature types remain for this story. A stale browser error is cleared when starting another reference or editor. The existing migration fixture chain also removes the new migration before reconstructing an earlier schema.

The PR had no GitHub review comments or threads when checked after the first CI run. The documentation update will receive a separate CI run before merge.
