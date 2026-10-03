# W030 keyboard and native window audit

Recorded on 3 October 2026 for W030, issue #26. Dependencies W023 (#21) and W028 (#24) were checked live as closed. PR #51 merged at `a79d4411ceb36fb79277d276a3244375aa706a25`. PR #54 merged at `2d65359d838bda580f848cac19cabe33ae114c60`. The clean branch started at `95aae42dda0813f1cb4fe5bd2e77f1f40759a75e` on the live default branch.

## Verified source gaps and fixes

- Several saved-detail toolbar actions had no native menu counterpart. The Record menu now offers editing, removal, back to owner, stage and condition changes, and reopening. File offers original export. Focused scene values carry the current visible detail's existing commands. Editors, archived owners, closed jobs, and pending operations disable the applicable actions. Removal retains the existing confirmation. Back uses the existing draft guard. Option-Command-E edits and Command-[ returns to the owner. Close Search also has a menu action.
- Cancel existed only in editor toolbars. File now offers Cancel Editing with Command-period. The shared command uses the current draft's existing cancel method. It rejects pending operations and pending navigation. The command therefore cannot discard a draft while Save/Discard/Stay is pending. Plain Escape keeps native search-field and dialog handling. Photo editor actions now use the same native confirmation toolbar placement as the other editors.
- Pin Reference existed only in the toolbar. View now includes the same menu and saved choices. The existing read-only-window permission guard disables all record writes, cancellation, task moves, and pin changes in that window. It still permits reading and the window's explicit original-export button.
- Photo panning required dragging. The AppKit scroll view can now receive keyboard focus. Native key bindings dispatch arrow keys to bounded panning at the current zoom. The instructions and accessibility help identify that path. Panning leaves the zoom unchanged and stops at image edges.
- Photo and PDF page navigation used window shortcuts with unmodified left/right arrows. They now use Option-Command-Left/Right Arrow. Plain arrows remain available to focused text, lists, PDFKit, and the photo viewport. The embedded bench reader still has its window shortcuts disabled to avoid competing with the main detail reader.
- The pinned reference layout had an unbounded title and filename above fixed viewer and metadata areas. A single native vertical scroll view now contains the reference content. The viewer gets 60% of the available height with a 360-point minimum, including photo controls. Long titles, filenames, captions, source text, errors, and export/browser actions remain in that scroll view. Both the pane and read-only window use this layout. The main photo and PDF details also scroll their metadata around bounded viewer areas. Long captions and original names cannot push the remaining detail out of reach.
- Task progress now has an explicit accessibility label and a spoken count, percentage, and skipped count. Empty and all-skipped progress says No tasks planned and reports skipped tasks. Workshop rows now repeat their stage as text rather than relying on the section heading.

No persistence, schema, original file, repair-state, or proposed product-model choice changed. The explicit Save/Cancel model and the existing draft guard remain in place.

## Screen audit

This table records source inspection. It does not claim runtime acceptance.

| Area | Source evidence | Native acceptance still needed |
| --- | --- | --- |
| Main window, Workshop, Watches, Calibers, Parts, Archive, global search | Native split view, stable UUID list tags, native search and filters, exact-record commands, error/Retry states, section shortcuts | Keyboard focus and exact selection in both appearances and window sizes |
| Watch, caliber, job intake, stage and condition editors | Native grouped forms and labelled controls; existing initial text-field focus; Save/Cancel and pending-save disabling | Long names, large system text, menu/toolbar routing, unclipped actions at minimum size |
| Tasks, parts, supplier options | Native forms and labelled statuses; Move up/down menu and accessibility actions; waiting availability and progress use words | Keyboard task completion and reorder, part/supplier journeys, VoiceOver progress |
| Notes, links, photos, PDFs, activity | Labelled text editors, selectable saved text, native buttons, file errors, exact child IDs, preserved removal confirmation | Keyboard create/edit/import/export, PDF controls, photo focus/pan, failure/retry |
| Bench pane and read-only reference window | Restricted reader, focused-scene write guard, shared scrollable content, native zoom/page controls | Minimum/large size, long metadata, inactive-window contrast, focus returning to main editor |
| Settings, backup, restore, library recovery | Grouped scrollable Settings form; native open/save panels and destructive restore confirmation; draft rejection, progress words, error text, Retry and Finder reveal | Keyboard export/cancel, restore review/confirmation/cancel, panel access, recovery outcomes |
| Draft protection | Existing shared navigation chain, main window delegate and app termination delegate; failed-save drafts retained | Save/Discard/Stay on navigation, window close, and quit for every editor; failed-save recovery |
| Appearance and motion | System text styles, semantic label/background colours, native selection; status words; no custom animation found | Light/dark, increased contrast, Reduce Motion, Reduce Transparency, both glass-opacity settings |

## Design source

The live Paper file Ure had Brand, Logo, macOS 27, Watches · W003, and Page 1. No W030 feature page existed. The macOS 27 Rules JSX and Rules/light/dark computed styles were read before UI changes. They specify a 1000 × 650 main-window minimum, 1200 × 800 default, native controls, system text styles, semantic colours, text statuses, and menu counterparts for toolbar commands. This story retains those rules. It adds no toolbar background, content glass, custom design system, or decorative animation.

## Checks

All four local checks passed. The Debug build was unsigned. All unit and native UI sources compiled without execution. The PR records the independent review verdict and actual CI result. Commands run:

- `make lint`
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO build-for-testing`
- `git diff --check`

Build-for-testing compiles all unit and native UI sources without executing them. The initial Debug builds found Swift inference failures for optional callbacks embedded in view expressions. Explicit callback types and ordinary conditional assignment corrected them. Xcode retains its existing AppIntents metadata-extraction notice because the app has no AppIntents dependency. Complete concurrency checking and warnings as errors remain enabled.

`WorkshopEditingTests` adds cancellation coverage for a pristine draft, pending navigation, and saved-record preservation. `JobTaskProgressTests` covers spoken mixed and empty/all-skipped progress. `PhotoViewportTests` covers focus eligibility, bidirectional panning, zoom preservation, and edge bounds. `WatchUITests` adds a pointer-free create/edit/cancel/Stay journey with a long Unicode name. It also verifies that Escape in global search preserves the open draft before explicit Command-period cancellation. These sources remain subject to the W032 execution gate.

## Pending W032 acceptance

The repository's current phase rules defer app launch, unit/native/UI execution, and Release builds to W032. No keyboard journey, VoiceOver pass, runtime visual inspection, or screenshot was performed in W030. No capture or result bundle was created. Source and compilation evidence do not complete W030's native acceptance criteria.

During W032, run the existing and added behavioral sources in isolated libraries with `URE_TESTING=1` and the injected library location. Run focused macOS UI tests locally. Restore CI unit execution and Release builds before first-release acceptance. Native UI and device automation must remain off GitHub Actions.

Complete a keyboard-only journey for watch/caliber creation, job intake, stage and condition changes, tasks, parts/suppliers, notes, links, photo/PDF import and navigation, pinning, backup export/cancellation, and restore review/cancellation/confirmation. Verify the menu targets the displayed record after search, archive navigation, child selection, and reference-window focus. Confirm the reference window cannot create, edit, save, cancel, remove, archive, or move records. Confirm closing it leaves a main-window draft unchanged.

Check every status, selection, task-progress summary, file error, loading state, and confirmation with VoiceOver. Verify all save actions at 1000 × 650 and at a large window size. Include long Unicode names, long filenames/source URLs/captions, larger system text, both appearances, inactive windows, increased contrast, Reduce Motion, Reduce Transparency, and both glass-opacity settings. Verify photo Tab focus and arrow panning, PDF focus and page shortcuts, and scrolling to all reference actions.

Repeat Save/Discard/Stay for navigation, main-window close, and quit. Inject a save failure and confirm the draft text and exact selection survive. Check Escape returns Stay from the alert rather than cancelling the editor underneath. Backup/restore panel security-scoped access and actual native outcomes remain in the existing recovery acceptance reports.
