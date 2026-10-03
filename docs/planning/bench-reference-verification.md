# W012 bench reference verification

Implemented on 3 October 2026 for [W012 (#10)](https://github.com/jorgerodrigues/ure/issues/10), in [PR #40](https://github.com/jorgerodrigues/ure/pull/40). W010 (#8) and W011 (#9) were verified closed. [PR #37](https://github.com/jorgerodrigues/ure/pull/37) and [PR #39](https://github.com/jorgerodrigues/ure/pull/39) were verified merged before implementation.

## Scope and behavior

- One saved LibraryItem can be pinned from the selected job, its watch, or the watch's current caliber. Photos and PDFs use managed originals. Links retain the external-reference label and explicit browser action. Selection and loading never fetch external content.
- The pane sits outside the main detail/editor route. Existing note, photo, PDF, reference, intake, and stage/condition navigation retains the pin. The shared Save/Cancel and unsaved navigation/window/quit guards remain in place. No W007 return-to-note choice was changed.
- A job pin clears on another job. A watch pin remains only for the same watch. A caliber pin remains only while the new job's watch links to that caliber. Changes to the current watch/caliber relation and item removal refresh from one consistent observed database snapshot.
- Job ID, pin ID, and requested pane visibility are saved in library-scoped UserDefaults. They are preferences, not repair history. Restoration validates the saved job and item. It does not override user selection or an active draft during startup.
- The pane requires 540 points for the editor plus a 340-point reference area and separator. At the established 1000 × 650 main-window minimum it collapses. The pin and requested visibility remain saved. A message offers the reference window when the pane is collapsed for width.
- The single reference window follows the pin. It receives a restricted reader and no mutable feature environments. Main editing commands check focused-scene permission. The window can read, zoom, open a saved HTTP/HTTPS URL explicitly, or export an original outside the library. It cannot create or save records. Closing it does not discard a main-window draft.
- PDF widgets remain read-only and markup mode remains off. Image decoding and PDF loading retain concurrent work. Database, original validation, and export run through LibraryCoordinator away from the main actor. Originals and cover references are unchanged. No schema migration is needed.
- Missing records or an unavailable original clear the pin and its saved preference. Original availability is checked on pinning, observed updates, viewer failures, and app activation. Corrupt readable originals retain the viewer's retry and export path.
- No canvas, annotations, second editing window, task/parts placeholders, or automatic downloads were added.

## Design inspection

The live Paper file still had Brand, Logo, macOS 27, Watches · W003, and Page 1. No W012 feature page existed. The main-window JSX, rule text, and computed styles were read. The reference pane follows the existing native window/sidebar rules and uses system text styles, native controls, and semantic colors. The reference toggle has high toolbar visibility priority. No content glass or toolbar background was added. Runtime visual acceptance remains pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -resultBundlePath ~/Developer/test-assets/w012-bench-reference/compile-3.xcresult CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO build-for-testing`: all unit and native UI test sources compiled without execution.
- `git diff --check`: passed.

Initial compilation exposed missing framework imports, an ambiguous framework type name, and an invalid modifier on a toolbar group. These were corrected. Xcode retains its existing App Intents no-framework extraction notice. Complete concurrency checks and warnings as errors remain enabled.

## Behavioral sources and pending gates

BenchReferenceTests covers job/watch/shared-caliber eligibility, unrelated jobs, pane visibility, restart validation, library preference isolation, observed deletion and caliber unlink, missing originals, unchanged unsaved-note guards, closed-job reading, unchanged-byte export, and the minimum-width rule. JobUITests now expects last-job restoration and adds a reference-window/main-draft acceptance case. Existing reader source tests remain current with the restricted reader.

These sources compiled. Their behavior was not executed in this story.

- During W032, execute behavioral tests with isolated libraries and `URE_TESTING=1`.
- Locally verify section/editor switching, different watches, shared calibers, restart restoration, unavailable originals, and removal. Verify Save, Discard, Stay, failed Save, window closure, and quit with drafts.
- Verify resizing at 1000 × 650 and wider sizes, toolbar overflow, long titles and captions, photo pan/zoom, PDF pages and read-only widgets, focus, keyboard command routing, and reference-window closure.
- Verify light/dark, inactive windows, increased contrast, Reduce Transparency, and VoiceOver. Native UI/device automation stays off GitHub Actions.
- Unit execution, Release builds, and native UI acceptance remain deferred to W032. No app tests or Release build ran here.

## Independent review and CI

The full independent read-only review completed in one round with: No findings cleared the bar. No blocked code access was reported. One Bash read was denied; the available read tools completed the review. Source transfer used the standing [review approval](review-approval.md), verified against the direct human reply in the source chat.

PR CI runs formatting/lint and an unsigned Debug build. The current results are in [PR #40 checks](https://github.com/jorgerodrigues/ure/pull/40/checks). Both must pass before merge. Runtime and native acceptance remain deferred to W032.
