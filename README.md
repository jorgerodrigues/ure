# Ure

A native Mac app for watch repair and restoration. The current implementation includes the native shell, recoverable library, watch records, shared caliber records, job intake with repair history, scoped notes, technical reference links, and local photos. Further repair features follow in the [planning backlog](docs/planning/issues.md).

## Requirements

- An Apple silicon Mac running macOS 27 or later.
- Xcode 27 or later, with the macOS 27 SDK and Swift 6.4 compiler.
- Xcode selected as the active developer directory. Check with `xcode-select -p`.

Xcode resolves the sole runtime package, [GRDB 7.11.1](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1), through Swift Package Manager. The exact version and resolved revision are committed. Xcode includes the formatter and test frameworks.

## Build and run

Open `Ure.xcodeproj`, select the shared **Ure** scheme, and run. Or use:

```sh
make run
```

Local runs use ad-hoc signing. No Apple developer account is required. App Sandbox is enabled. Hardened Runtime is configured for distribution; Xcode disables it for local ad-hoc builds. The current bundle identifier is `local.ure.app`; settle an owner-controlled identifier before distribution and before storing valuable data.

The main window contains Workshop, Watches, Calibers, Parts, and Archive. Use **Option-Command-1** through **Option-Command-5** to select a section. **Command-comma** opens Settings. Startup creates or reopens the local library. Workshop shows open jobs. Watches and Calibers have saved-record lists and editors. Parts shows requirements from open jobs. Archive shows archived watches and calibers, plus closed jobs.

## Workshop overview

Workshop groups open jobs under Planned, In progress, Waiting, and Ready. Each row shows the saved watch name and cover thumbnail, job title, task counts and rounded-down percentage, skipped count, waiting reason, and number of Needed or Ordered part requirements. Each requirement counts once, regardless of its quantity or task links. Empty and all-skipped task lists show **No tasks planned**.

Rows within each group put the latest saved job, task, or part change first. Watch identity and cover edits refresh the labels and thumbnail. Text search matches watch identity, job title, and waiting reason. The stage filter works together with text search. **Clear Filters** restores all open jobs.

Select a row to open that exact watch and job in Workshop. The existing editors, Command-S, draft protection, activity navigation, and pinned reference tools work there. Filters retain the selected detail and show a message when its row is excluded. Closing removes the job from the open list and keeps its readable detail and watch history. Reopening returns it to the applicable group. Loading failures show an error and Retry.

## Search

Use **Search Library** in the toolbar or **Shift-Command-F** for global search. Results group watches, calibers, jobs, notes, parts, links, photos, and PDFs. Each result names its watch, job, or shared caliber. Selecting it opens the exact saved record through the existing draft guard. Closed jobs remain searchable. **Include Archived** also searches archived watches, jobs, calibers, and their owned records. Use Archive to read archived owners and closed jobs.

Search matches saved watch identity, caliber designation, job titles, note titles and bodies, part descriptions, manufacturer references, supplier stock codes, and library item titles and captions. It preserves leading zeros and punctuation. Unicode case matching uses the same rule in every local filter. SQL characters such as `%`, `_`, and quotes are literal search text. PDF contents and text within images are not indexed.

The normal Watches, Calibers, Workshop, and Parts lists have local search. Job history, notes, parts, links, photos, and PDFs also have local text filters. Photo text combines with the stage filter. Part text includes supplier options and the saved order-time stock code. Filtering keeps an already open detail readable.

## Archive and removal

Use **Archive Watch** or **Archive Caliber** in its saved detail or the Record menu. A watch cannot archive while it has an open job. **Unarchive** restores normal list visibility. Existing watch links to archived calibers stay readable. Archived owners reject changes until restored. Closed jobs require Reopen, and their watch must first be unarchived.

Tasks, notes, photos, PDFs, and external references have a **Remove** action in saved detail. Removal requires confirmation. Task confirmation lists its part links. Parts and historical activity summaries stay saved. Supplier removal stays in the part editor and commits with **Save**. Part requirements use **Cancelled** rather than deletion.

Removing a photo clears its cover reference and any pin. Removed file items close their viewers. The database commits before unreferenced originals are removed. Failed file cleanup retries at startup. Originals still used by another item stay saved. There is no permanent watch or job deletion.

## Parts overview

Parts shows requirements from open jobs in every procurement status. Each row names its watch, job, stage, manufacturer reference, quantity, and status. The most recently saved parts appear first. Filter by Needed, Ordered, Arrived, Installed, or Cancelled. Text search matches the part description, manufacturer reference, watch identity, or job title. Text and status filters combine.

Select a row to open that exact part in its job. Supplier links open only through their explicit **Open** buttons. **Edit Part**, **Save**, **Cancel**, and **Command-S** use the existing procurement service and draft protection. Committed changes refresh both the overview and job list. Filters retain the selected detail and show a message when excluded. Closing removes the job's parts from the overview and keeps them readable in watch history. **Clear Filters** resets text and status. Loading failures show an error and Retry. Bench references and job activity remain available in Parts.

## Watch records

Use **Add Watch** in Watches or **Command-N** to create a record. Only a name is required. Optional identity and specification fields remain unknown until entered. Serial numbers and case references preserve leading zeros and punctuation. Case diameter and lug width use millimetres and must be finite positive numbers.

Use **Save** or **Command-S** to commit the draft. **Cancel** discards it. Changing records or sections, closing the main window, and quitting with unsaved changes offer Save, Discard, or Stay. A failed save keeps the draft and reports the error. Saved changes refresh the list and detail. The list search filters watch identity fields. Change physical condition through an open job.

## Shared caliber records

Use **Add Caliber** in Calibers or **Command-N** while that section is selected. Only the exact designation is required. Variant and manufacturer remain separate fields. Unknown numeric specifications stay empty. Beat rate and lift angle must be finite and positive. Jewel count and nominal power reserve may also be zero. Add a source note for technical claims. The library starts without seeded caliber facts.

Select a caliber in the watch editor, or choose **Unknown** to clear its link. Several watches can share one caliber. Its saved specifications appear in each linked watch's detail. The caliber detail lists linked watches and opens their records. Clearing one link preserves the caliber and all other watch links. Caliber editing uses the same Save, Cancel, Command-S, and draft protection as watch editing. Shared notes are available in the caliber detail. Technical reference links are available in the caliber detail. Technical files follow in their own issues.

## Job intake and repair history

Use **Start Job** in a watch's repair history. Only a job title is required. Reported problem, agreed scope, intake condition, and owner contact details are optional. Email and phone accept free text. Save creates a Planned job and copies the saved watch identity and exact caliber designation and variant into a versioned intake snapshot. Later watch or caliber edits leave this snapshot unchanged.

Use **Edit Intake** to correct an open job's intake, including its identity snapshot. Those corrections apply to that job only. Job editing uses Save, Cancel, Command-S, and the existing draft protection. A failed write preserves the draft. Cancelling a new intake creates no history entry.

A watch can have several repair jobs, with at most one open job. **Open Job** returns to that existing job. The database also enforces the rule when save requests compete. The watch's history opens earlier jobs for reading. **Back to Watch** returns to its identity and history. Job notes, tasks, and parts are available in the job detail.

Use **Change Stage** for Planned, In progress, Waiting, Ready, Completed, or Cancelled. Waiting requires a reason. Completed requires an outcome and accepts optional recommendations. Cancelled requires a reason. Ready means ready for final review. Closing locks operational edits. **Reopen Job** selects an open stage and checks that no other job is open for this watch.

Use **Change Condition** to record Unknown, Running, Running poorly, Stopped, or Disassembled with an optional note. Condition and job stage remain independent. Both forms use Save, Cancel, Command-S, and draft protection. Successful changes retain prior and next values in history. Use **Show Activity** to read the saved changes.

## Job activity

Use **Show Activity** in a job to read saved changes and job notes together, newest first. Notes use their occurred dates. Editing a note updates its one entry. Equal dates keep a stable order.

Expand **Previous and new values** to read saved reasons, outcomes, milestones, and supplier details. **Open Job**, **Open Watch**, **Open Task**, **Open Part**, and **Open Note** show surviving sources. Removed tasks or parts keep their historical summaries. Closed sources remain readable. This is a repair history, not a complete audit log.

## Job tasks

Use **Add Task** in a job detail. Enter a title and optional detail and group label. Choose To do, Doing, Waiting, Done, or Skipped. Waiting requires a reason or a linked Needed or Ordered part. Skipped always requires a reason. Several tasks can be Doing at once.

Choose **Required parts** in the task editor to link several parts from the same job. Save commits the selection. Cancel keeps the previous links. Needed and Ordered show **Waiting for parts**. Arrived and Installed satisfy availability. Any cancelled link shows **Needs review**. Once every linked part is available, the label becomes **Parts available**. The task stays Waiting until you change it. Removing the last unresolved link requires a waiting reason or another task status. Procurement saves refresh labels from saved data.

Use **Edit Task**, **Save**, **Cancel**, or **Command-S**. Status changes use the editor. Failed saves keep the draft. Pending saves block duplicate commands. Task drafts use the shared Save, Discard, or Stay guard for record and section changes, window closure, and quitting. Closed-job tasks remain readable. Reopen the job before adding or changing a task. The service also rejects stale saves after closure.

Task completion and reopening save history in the same transaction as the task change. They do not change the job stage or watch condition. Completing or cancelling a job shows its task summary. If To do, Doing, or Waiting tasks remain, enter a separate explanation. Closing keeps every task's status. The explanation stays with the closed job and its transition history. Reopening clears the current explanation and retains that history.

Tasks keep their saved bench order. New tasks go at the end. Drag a row before another row, or drop below the list to move it to the end. The row menu and task detail offer **Move up** and **Move down**. In a saved task detail, **Option-Command-Up Arrow** and **Option-Command-Down Arrow** run the same actions from the Task menu. Optional group labels stay visible without changing the saved order. Failed moves keep the previous order. Closed jobs disable ordering, and the service rejects stale moves after closure.

The job header shows Done divided by all non-Skipped tasks, with both counts and a whole percentage. The percentage rounds down, so unfinished work cannot display 100 percent. Skipped tasks have a separate count. Empty and all-skipped lists show **No tasks planned**. Adding or reopening a task updates progress after Save succeeds. Closing a job keeps the saved task statuses and can leave progress below 100 percent. Part links follow in W018.

## Required parts

Use **Add Part** in a job detail. Enter a description and a positive whole-number quantity, default 1. Track each separate unit or lot with its own requirement. Manufacturer reference is optional text and keeps leading zeros and punctuation. Compatibility is Unchecked, Confirmed, or Unsuitable. Confirmed requires an evidence note. New parts start Needed or Arrived if the complete lot is already on hand.

Use **Add link** during creation or editing. A complete HTTP or HTTPS URL is enough. A part can have no links or several links. Each saved link has an explicit **Open** action. Saving, loading, and selecting parts do not fetch external content or open the browser. Removing a saved link requires confirmation and takes effect after Save.

Each saved link can also hold a supplier name, listing title, supplier stock code, price and currency, and notes. Adding those details edits the same link. Supplier stock codes stay separate from the manufacturer's reference and retain leading zeros and punctuation. Use **Selected supplier option** in the part editor to choose one option or clear the choice. Keep the other options for comparison. Removing the selected link clears the choice when you save. Cancel keeps the saved links and choice.

Price is optional. Use a non-negative decimal with a point, such as `12.3400`, and a valid currency code, such as `DKK` or `EUR`. The entered digits are stored exactly. A price requires a currency. Lowercase currency input is accepted and saved in uppercase. No totals or conversion are calculated.

Part editing uses **Save**, **Cancel**, **Command-S**, and the shared draft guard. A failed save keeps all draft fields and links. Pending saves block duplicate writes. Closed-job parts remain readable. Reopen the job before adding or editing a part. The service rejects stale saves after closure. Closing a job shows its parts summary and requires a separate explanation for Needed or Ordered parts. Closing preserves their statuses and saves the explanation in history.

Use **Edit Part** to choose Needed, Ordered, Arrived, Installed, or Cancelled. Save records current milestone dates and the transition history together. Arrived means the whole lot is on hand. Installed means fitted. Installing from Needed, Ordered, or Cancelled requires confirmation that the whole lot is on hand. Save records arrival and installation together. There is no partial-delivery counter.

Ordering saves a copy of the selected supplier option and an optional order reference. No supplier selection is required. Later supplier edits, selection changes, and link removal leave that copy intact. Correcting Arrived, Installed, or Cancelled back to Ordered retains an existing order snapshot. Moving back to Needed clears the current order details. Previous values remain in history.

Backward corrections, cancellation, and restoring a cancelled part require a reason. Save clears milestone dates that no longer apply. Cancellation keeps the supplier snapshot and order reference for reading. Cancel in the editor discards the draft. A status changed by another saved action requires cancelling and reopening the stale editor. Procurement never changes task status, job stage, or watch condition. Use **Show Activity** to read the saved changes.

## Scoped notes

Use **Add Note** in a watch, job, or caliber detail. Each note belongs to that scope only. Select a saved note to read its full text and dates. A caliber note is shared knowledge in that caliber. It is never copied into a watch or job.

Enter a title, plain text, a kind, and an occurred date. Kinds are Observation, Research, Work log, and Measurement. Measurement uses the same plain-text editor. Text preserves Unicode, line breaks, and spacing. No rich text, HTML rendering, or structured instrument fields are added.

Use **Save**, **Cancel**, or **Command-S**. Editing text keeps the occurred date unless you change it. Created and updated times are separate. Failed saves keep the draft. Switching notes, records, or sections, closing the window, and quitting use the existing Save, Discard, or Stay guard. Closed-job notes remain readable. **Add Note** and **Edit Note** are disabled until the job is reopened. The service also rejects closed-job saves, including an editor opened before closure.

## Technical reference links

Use **Add Link** in a watch, job, or caliber reference section. Each link belongs to that scope only. Enter a title and a complete HTTP or HTTPS URL. Add optional source description and plain-text notes to keep the evidence in context. Several links can coexist in each scope.

Use **Save**, **Cancel**, or **Command-S**. Invalid URLs and failed writes keep the draft. Reference drafts use the existing Save, Discard, or Stay guard for navigation, window closure, and quitting. Closed-job references remain readable. Reopen the job before adding or editing its links.

Select a saved link to read its details. **Open in Browser** opens its saved URL in the default browser. Links are labelled **External reference**. Their linked content is not saved offline. Loading, selecting, and saving do not open a browser or fetch the page.

## Local photos

Use **Import Photos** in a watch, job, or caliber detail. The system file picker accepts several files. You can also drop local files onto the photo section. Imports accept JPEG, PNG, and HEIC by detected content. The approved limits are 100 MB per original and 200 files per batch. Each file has its own result. Successful imports remain saved when another file fails or the batch is cancelled. Moving or deleting the source does not affect the managed original.

Photos start as **Unclassified**. Open a photo and choose **Edit Photo** to change its title, caption, and stage. Stages are Unclassified, Before, During, and After. The stage filter shows only photos in the current owner scope. Editing uses Save, Cancel, Command-S, and the shared unsaved-draft guard. Closed-job photos remain readable and exportable. Reopen the job to import or edit its photos. The service rejects stale saves after closure.

Select a photo to view its original. Use **Fit**, **Zoom In**, and **Zoom Out**, or pinch to zoom. Drag or scroll to pan. Left and right arrows select the previous and next photos in the filtered scope. **Export Original** uses a save panel and preserves the imported bytes. A failed thumbnail shows a placeholder. It does not remove the photo or prevent original viewing. A failed viewer load offers Retry, and Export Original remains available.

Use **Choose Cover** in the watch detail to select a photo from that watch or one of its jobs. **Remove Cover** clears the reference. Watch rows use the cover thumbnail. Caliber photos stay in their shared caliber scope and cannot become a watch cover.

## Technical PDF documents

Use **Import PDFs** in a watch, job, or caliber reference section. Choose several local files or drop them onto the PDF area. Content detection accepts PDFs regardless of extension. The limits are 100 MB per original and 200 files per batch. Each file has its own result. Successful imports remain saved when another file fails or the batch is cancelled. Protected PDFs, including owner-restricted copies that open without a password, are unsupported.

Document rows show **PDF · Offline**. Select one to read its managed original with PDFKit. Use **Previous Page**, **Next Page**, keyboard arrows, **Fit**, **Zoom In**, and **Zoom Out**. PDF loading runs off the main actor. A failed load offers Retry. **Export Original** preserves the imported bytes and stays available after a reader failure when the original remains accessible.

Use **Edit Document** to change its title, optional HTTP/HTTPS source URL, source description, and notes. Save, Cancel, Command-S, and the shared draft guard apply. **Open Source** opens the saved URL only after that action. It does not download the document. Closed-job documents remain readable and exportable. Reopen the job before importing or editing documents. The service also rejects stale saves after closure.

## Bench references

Open a saved job and use **Pin Reference** to choose one saved photo, PDF, or external link from that job, its watch, or its current caliber. The pin stays in place while you open notes, photos, references, or intake editors. Switching jobs clears unrelated pins. A watch reference stays for another job on that watch. A caliber reference stays for a job whose watch uses the same caliber.

Use **Toggle Reference Pane** or **Shift-Command-R** to collapse or show the pane. It appears beside the editor when there is room. At narrower widths, widen the window or use **Open Reference Window** with **Option-Command-R**. The reference window has reading, zoom, explicit browser opening, and original export controls. New, Save, and section-changing commands are disabled while that window is active. Closing it leaves the main editor's draft in place.

The app restores the last selected saved job and its valid pin. Pane visibility is a preference. Missing records, changed scope, or unavailable originals clear the pin without removing saved content. References remain readable for closed jobs. External content opens only after **Open in Browser**.

## Managed original import infrastructure

W009 ([PR #36](https://github.com/jorgerodrigues/ure/pull/36)) adds the internal `FileImportService` API for JPEG, PNG, HEIC, and PDF originals. The approved limits are 100 MB (100,000,000 bytes) per original and 200 files per batch. It detects content rather than trusting extensions, keeps unchanged original bytes, and stores file size, SHA-256, dimensions, and orientation. Each import uses a generated storage key. Source filenames stay metadata only. Cancellation and per-file failures preserve committed assets. Startup recovery removes unreferenced interrupted imports through the coordinator's mutation gate. Photo import controls are available in W010. PDF import controls are available in W011.

## Local library and recovery

The app resolves its Library folder inside sandboxed Application Support. Settings shows its location. `active-library.json` selects one directory under `generations/`. Each generation holds `library.sqlite`, `manifest.json`, and `originals/`. Original files and SQLite writes share one coordinator. Database access, file copies, and hashing run away from the main actor.

Startup validates the active pointer, manifest, database integrity, foreign keys, and migration history before opening a writer. Existing data is never replaced with an empty database after a failed open. The recovery screen shows the failure and library location. Retry rechecks the saved library.

Before upgrading, the coordinator creates a recovery snapshot under `recovery/`. It uses SQLite's backup API, copies originals, and records file sizes and SHA-256 hashes. It applies migrations to a new generation copied from that snapshot. The active pointer changes atomically only after validation passes. Failed migrations keep the original generation active. Old generations and recovery snapshots are retained.

Recovery copies are local protection against app failures. User-exported backups and restore controls belong to later issues. Do not keep valuable records only in this app before the Recovery and Release milestones pass.

## Verification

```sh
make lint       # Formatting and unsafe Swift constructs
make build      # Unsigned Debug build, including compiler type and concurrency checks
make release    # Unsigned optimized Release build
make test       # Swift Testing unit tests
make test-ui    # XCUITest keyboard navigation, Settings, and light/dark window launch
make test-all   # All tests
make check      # Full lint, Debug build, and unit tests; deferred CI gate at W032
```

On this development Mac, macOS 27.2 beta with Xcode 27 stalls in `clang-stat-cache`. The ignored `Config/Local.xcconfig` sets `SDK_STAT_CACHE_ENABLE = NO`. Make commands pass this optional config to app and package targets. This affects build-time file caching only. A fresh checkout on the same machine can use `make run XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`, or create the same local config. CI retains Xcode's default cache setting. Direct `xcodebuild` commands can pass `-xcconfig Config/Local.xcconfig` when the file exists.

For a focused test:

```sh
xcodebuild -project Ure.xcodeproj -scheme Ure \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -only-testing:UreTests/AppConfigurationTests \
  -resultBundlePath "$HOME/Developer/test-assets/$(git branch --show-current | tr / -)/ure-focused-$(date +%Y%m%d-%H%M%S).xcresult" \
  test
```

Test launches receive a unique temporary library location. The shared scheme sets `URE_TESTING=1`, and native test-host markers also force isolation. UI tests set the marker on each app launch. A valid UUID in `URE_TEST_LIBRARY_ID` lets a marked restart test reuse its own temporary library. It cannot select an arbitrary path or affect an unmarked launch. A Debug-only damaged-pointer seed requires the explicit test marker. No test opens the normal user library.

Derived data stays in the ignored `.build/` directory. Test result bundles and captures go in `~/Developer/test-assets/<branch>/`. Native UI tests require a logged-in graphical session and [Accessibility permission for Xcode Helper](https://developer.apple.com/documentation/xcuiautomation/recording-ui-automation-for-testing). Keep captures while the branch is active, then remove that branch's folder when work is complete.

## Architecture and performance

SwiftUI views render state and forward actions. Observation owns feature state. The app uses Swift 6 language mode, complete concurrency checks, approachable concurrency, and main-actor isolation by default. Immutable values explicitly opt out of actor isolation. The library coordinator is a dedicated actor. Image processing must also use dedicated actors or `@concurrent` work; an `async` function alone does not move expensive work off the main actor.

Use standard navigation, controls, and window APIs for the current macOS appearance and accessibility behavior. Keep observation close to the views that need it. Lists must use stable record IDs. Load originals only for viewers and decode thumbnails off the main actor. Add caching or extra layers only after profiling shows a need.

The Release configuration enables optimization and whole-module compilation. The shared scheme's Profile action uses Release. Use **Product > Profile** with Instruments' SwiftUI and Time Profiler tools to find expensive updates and main-thread work. The realistic library benchmarks remain W031; this empty shell does not establish their performance.

## Project context

- [Specification](docs/planning/specification.md)
- [Implementation roadmap](docs/planning/issues.md)
- [GitHub issues](https://github.com/jorgerodrigues/ure/issues)
- [W001 foundation verification and pending gates](docs/planning/setup-verification.md)
- [W002 library verification](docs/planning/library-verification.md)
- [W003 watch verification and pending native UI acceptance](docs/planning/watch-verification.md)
- [W004 caliber verification](docs/planning/caliber-verification.md)
- [W005 job intake verification](docs/planning/job-verification.md)
- [W006 job stages and watch condition verification](docs/planning/job-stage-verification.md)
- [W007 scoped notes verification](docs/planning/note-verification.md)
- [W008 technical references verification](docs/planning/reference-verification.md)
- [W009 managed file import verification](docs/planning/file-import-verification.md)
- [W010 local photo verification](docs/planning/photo-verification.md)
- [W011 technical PDF verification](docs/planning/document-verification.md)
- [W013 job task verification](docs/planning/task-verification.md)
- [W014 task ordering and progress verification](docs/planning/task-order-verification.md)
- [W015 part requirements verification](docs/planning/part-verification.md)
- [W016 supplier comparison verification](docs/planning/supplier-verification.md)
- [W019 job activity timeline verification](docs/planning/timeline-verification.md)
- [W020 workshop overview verification](docs/planning/workshop-verification.md)
- [W021 parts overview verification](docs/planning/parts-overview-verification.md)
- [W023 archive and removal verification](docs/planning/archive-verification.md)
- [Design: brand, app icon, and macOS 27 screen rules](docs/design/README.md)

The user approved the current-platform direction and W002's SQLite/GRDB storage design on 1 October 2026. Shared caliber records and the repair history rule were approved on 2 October 2026. Watch, caliber, intake, stage, and condition forms use explicit Save and Cancel editing. W003, W004, and W005 are merged through [PR #29](https://github.com/jorgerodrigues/ure/pull/29), [PR #31](https://github.com/jorgerodrigues/ure/pull/31), and [PR #32](https://github.com/jorgerodrigues/ure/pull/32). W006 is merged in [PR #33](https://github.com/jorgerodrigues/ure/pull/33). W007 is merged in [PR #34](https://github.com/jorgerodrigues/ure/pull/34). W008 is implemented in [PR #35](https://github.com/jorgerodrigues/ure/pull/35). Native UI and device checks are deferred to release acceptance by agreement. GitHub holds story descriptions, acceptance criteria, and current status. The repository holds the specification and verification evidence.

The GitHub Actions workflow uses the [macOS 27 arm64 runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) and Xcode 27. During rapid implementation, it runs `make lint` and `make build` only. Unit test execution and the Release build return to CI in [W032 (#28)](https://github.com/jorgerodrigues/ure/issues/28) before first-release acceptance. Release builds are not required for each story during this phase. Keep behavioral tests current and compile affected tests when needed. The [GitHub remote](https://github.com/jorgerodrigues/ure) is configured. Native UI and device checks run locally during release acceptance and never on CI.

Current platform references: [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements/), [Observation](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro), [Swift concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html), and [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).
