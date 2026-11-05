# Ure

A native Mac app for watch repair and restoration. The current implementation includes the native shell, recoverable library, watch records, shared caliber records, jobs you write on with three states and repair history, one notes text per record, and photos, PDFs and links as material on each record. Further repair features follow in the [planning backlog](docs/planning/issues.md).

Start with the [local handover guide](docs/handover.md). The [release acceptance report](docs/planning/release-acceptance.md) records executed checks and remaining native and minimum-OS gates. First-release acceptance is still pending.

## Requirements

- An Apple silicon Mac running macOS 27 or later.
- Xcode 27 or later, with the macOS 27 SDK and Swift 6.4 compiler.
- Xcode selected as the active developer directory. Check with `xcode-select -p`.

Xcode resolves the sole runtime package, [GRDB 7.11.1](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1), through Swift Package Manager. The exact version and resolved revision are committed. Xcode includes the formatter and test frameworks.

## Process recovery verification

Run `make recovery XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` to build the Debug `UreRecoveryHarness` command-line target and run W029's isolated interruption matrix. It requires Python 3 and uses only its standard library. The target compiles the app's shared sources with a separate entry point. It does not start SwiftUI, the app, or UI automation.

Each scenario gets a new library under `.build/recovery-runs/<run-id>/`. The driver injects that location and `URE_TESTING=1`. A worker records the reached checkpoint, then kills its own process with `SIGKILL`. The driver requires that signal and checkpoint before recovery. New worker processes reopen through `LibraryCoordinator`. They compare record counts, stable IDs, saved values, original SHA-256, and exact technical PDF bytes. The retained v10 and v15 SQL fixtures are never regenerated during a run.

The matrix covers imports, new and replacement exports, upgrades, restore staging, pre-restore recovery copies, activation, rollback, and damaged opens. Logs and a passing `summary.json` stay under the run directory for inspection. These are disposable test libraries. Remove the run directory after inspecting a run. This command is separate from the app tests and native acceptance deferred to W032. See the [W029 verification report](docs/planning/process-recovery-verification.md) for the matrix and its limits.

## Library performance measurements

Run `make performance XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` to build the optimized `UrePerformanceHarness` command-line target and measure W031's synthetic library. Python 3 uses only its standard library. This command does not start the app or UI automation.

The fixture has 500 watches, 1,000 jobs, 10,000 checklist steps, and 5,000 photo items with separate managed originals. It also has job notes, part links, archived records, and Unicode and punctuation identifiers. Three deterministic JPEG templates cover 640 × 480, 2400 × 1600, and 6000 × 4000 images. The logical original size is about 4.6 GB. Each fresh measurement process opens through `LibraryCoordinator` with `URE_TESTING=1` and an injected library location.

The driver retains raw samples and `summary.json` under `.build/performance-runs/<run-id>/`. It checks exact result IDs, step and part counts, database integrity, and every original's size and SHA-256. It reports warm queries, thumbnail decoding, coordinator open time, and resident memory during 20 large-image open/release cycles. A successful command means the measurements and data checks completed. It does not mean all performance acceptance passed. Native usable-window, scrolling, typing, and viewer memory acceptance remain W032 gates. See the [W031 verification report](docs/planning/performance-verification.md).

To compare an optimization against the same library, rebuild the Release harness and run:

```sh
python3 PerformanceHarness/run.py .build/DerivedData/Build/Products/Release/UrePerformanceHarness \
  --fixture .build/performance-runs/<run-id>
```

Copy the earlier summary before rerunning because measurement files are replaced. Keep the fixture for W032's native checks. Remove only that disposable run directory when acceptance no longer needs it. W029's frozen fixtures and recovery driver are separate.

## Build and run

Open `Ure.xcodeproj`, select the shared **Ure** scheme, and run. Or use:

```sh
make run
```

To install an optimized build for daily use, quit any running copy of Ure and run:

```sh
make install XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO
```

This builds a locally signed Release with Hardened Runtime, verifies its signature, installs it in `~/Applications/Ure.app`, and opens it. Use `INSTALL_DIR=/Applications` to choose the shared Applications folder. Installation replaces only the app bundle. The library remains in Application Support. Local signing needs no developer account. This build is for this Mac; it is not notarized for distribution.

Local runs use ad-hoc signing. No Apple developer account is required. App Sandbox is enabled. Xcode disables Hardened Runtime for ordinary ad-hoc builds; `make install` explicitly enables it and omits debug entitlements. The current bundle identifier is `local.ure.app`; settle an owner-controlled identifier before distribution and before storing valuable data.

The main window contains Workshop, Watches, Calibers, and Parts. Use **Option-Command-1** through **Option-Command-4** to select a section. **Command-comma** opens Settings. Startup creates or reopens the local library. Workshop shows open jobs. Watches and Calibers each have a list and a page you write on, with archived records folded away at the end of the list. Parts shows requirements from open jobs.

Use **Option-Command-E** to edit the displayed part, **Command-S** to save, and **Command-period** to cancel editing. **Command-[** returns to the owner through the draft guard. The Record menu also has removal and archive actions. These commands follow the displayed record and its permissions. Editing commands are disabled in the read-only reference window. **Pin Reference** is also in the View menu.

Focus a photo and use the arrow keys to pan. Fit and Zoom controls remain available by keyboard. Use **Option-Command-Left Arrow** and **Option-Command-Right Arrow** for the previous or next photo or PDF page. Plain arrows remain available for text, lists, and photo panning. Reference content scrolls so long titles, filenames, and notes do not hide its actions.

## Workshop overview

Workshop groups open jobs under In progress and Waiting. Each row shows the saved watch name and cover thumbnail, job title, how many checklist steps are done, what a waiting job waits for, and number of Needed or Ordered part requirements. Each requirement counts once, regardless of its quantity. A checklist without steps shows **No steps yet**.

Rows within each group put the latest saved job, step, or part change first. Watch identity and cover edits refresh the labels and thumbnail. Text search matches watch identity, job title, and what a waiting job waits for. The stage filter works together with text search. **Clear Filters** restores all open jobs.

Select a row to open that exact watch and job in Workshop. The job page, draft protection for parts, and pinned reference tools work there. Filters retain the selected detail and show a message when its row is excluded. Setting a job to Done removes it from the open list and keeps it on its watch's page. Setting it back returns it to its group. Loading failures show an error and Retry.

## Search

Use **Search Library** in the toolbar or **Shift-Command-F** for global search. Results group watches, calibers, jobs, parts, links, photos, and PDFs. A photo or PDF opens in its viewer, and a link opens its record. A word in a record's notes finds that watch, caliber, or job. Each result names its watch, job, or shared caliber. Selecting it opens the exact saved record through the existing draft guard. Done jobs remain searchable. Search always includes archived watches and calibers and their owned records, and marks them as archived.

Search matches saved watch identity, the watch's owner and contact, caliber designation, job titles, the notes of watches, calibers, and jobs, part descriptions, manufacturer references, and material titles. It preserves leading zeros and punctuation. Unicode case matching uses the same rule in every local filter. SQL characters such as `%`, `_`, and quotes are literal search text. PDF contents and text within images are not indexed.

The normal Watches, Calibers, Workshop, and Parts lists have local search. Job history and parts also have local text filters. Part text covers descriptions and manufacturer references. Filtering keeps an already open detail readable.

## Archive and removal

Use **Archive Watch** or **Archive Caliber** in the Record menu, or right-click the record in its list. Any watch can be archived, even one with an open job, and that job stays in Workshop and can still change. **Command-Z** undoes an archive or an unarchive. Archived watches and calibers fold away in the **Archived** section at the end of their list, and their page offers **Unarchive** in the toolbar. They stay in search. Existing watch links to archived calibers stay readable. Archived records reject changes until restored.

A checklist step goes with **Backspace** on a step without text or with **Delete Step**, and **Command-Z** brings it back. Part link removal stays in the part editor and commits with **Save**. Part requirements use **Cancelled** rather than deletion.

Material is removed at once, and **Command-Z** brings it back. See [Material](#material). There is no permanent watch or job deletion.

## Parts overview

Parts shows requirements from open jobs in every procurement status. Each row names its watch, job, stage, manufacturer reference, quantity, and status. The most recently saved parts appear first. Filter by Needed, Ordered, Arrived, Installed, or Cancelled. Text search matches the part description, manufacturer reference, watch identity, or job title. Text and status filters combine.

Select a row to open that exact part in its job. Part links open only through their explicit **Open** buttons. **Edit Part**, **Save**, **Cancel**, and **Command-S** use the existing procurement service and draft protection. Committed changes refresh both the overview and job list. Filters retain the selected detail and show a message when excluded. Setting a job to Done removes its parts from the overview and keeps them on the job's page. **Clear Filters** resets text and status. Loading failures show an error and Retry. Bench references remain available in Parts.

## Watch records

Use **Add Watch** in Watches or **Command-N** to make a watch named "New Watch" with the cursor in its name, which is the page's title. Type the name, then use **Tab** or **Return** to move through the brand, model, reference, serial, year, case, diameter, lug width, owner, and contact. Each fact saves as you type, with no Save button, and **Command-Z** undoes it after it saved. As you type a brand, the brands already in the library show under the field. Serial numbers and references preserve leading zeros and punctuation. Diameter and lug width take millimetres, such as "35mm" or "35,0 mm", in the Mac's region format. The owner and contact are free text. Unknown facts stay empty. Click the cover to choose a photo from the watch or its jobs.

The page also lists the watch's jobs, its material and its notes. The list search filters watch identity, owner, and contact.

Libraries from before W036 kept a condition, a condition note, a stated water resistance and specification notes on each watch, and the owner's name, email and phone on each job. The upgrade gives each watch the owner from its most recent job that names one, with the email and phone joined into its contact. The removed watch values, and owners that other jobs name differently, go into the watch's notes under "From the old record".

## Shared caliber records

Use **Add Caliber** in Calibers or **Command-N** while that section is selected. It makes a caliber named "New Caliber" and puts the cursor in its name, which is the page's title. Type the name, then use **Tab** or **Return** to move through the maker, beat rate, jewels, power reserve, and lift angle. Each fact saves as you type, with no Save button, and **Command-Z** undoes it after it saved. Choose Manual, Automatic, or Quartz from the winding pop-up. As you type a maker, the makers already in the library show under the field, and **Tab** takes the first. Numbers take what you would write on paper, such as "28 800 vph" or "52,5°", in the Mac's region format. Unknown facts stay empty. A number the fact does not take stays on screen as not valid yet, and the caliber keeps its last good value. Write sources for technical claims in the caliber's notes. The library starts without seeded caliber facts.

Choose a caliber from the watch's caliber pop-up, or choose **None** to clear its link. The arrow after it opens the caliber's page. Several watches can share one caliber. The caliber page lists the watches that use it and opens their records. Clearing one link preserves the caliber and all other watch links. The caliber's notes are shared knowledge in the caliber detail. Technical reference links are available in the caliber detail. Technical files follow in their own issues.

## Jobs

A job is one repair of one watch, and its page is a page you write on, laid out as the "2 Job" artboard. Use **Start Job** under a watch's jobs. It opens a job named "New Job", In progress, and puts the cursor in its title with the title selected, so typing replaces it. There is no Save button. The title, the problem and what a waiting job waits for save as you type, and **Command-Z** undoes each after it saved.

The header shows the watch's cover, or the job's first photo when the watch has none. Beside it are the state, the date the job opened and how long ago, such as "Opened 12 October · 23 days", the title, and a line that links the watch and its caliber and names the owner and contact from the watch. The problem follows in the job's own words. Then come the parts, the checklist, the material and the notes.

A job is In progress, Waiting or Done. Choose the state from the pop-up. The change saves at once, and **Command-Z** puts back the state before, with its dates and waiting text. Choosing Waiting puts the cursor in **Waiting for**, such as "a mainspring". Leaving Waiting clears it. Done records the day the job was done, such as "Opened 12 October · Done 2 November", and leaving Done clears that date. A Done job stays editable, with its checklist, parts, material and notes.

A watch can have several jobs, with at most one that is not Done. The database also enforces the rule when requests compete. A Done job can move back to In progress or Waiting only while its watch has no other open job. Starting a job needs a watch that is not archived. A job of an archived watch can still change, also its state.

Libraries from before W037 had six stages, an intake snapshot, an agreed scope, an intake condition, an outcome, recommendations, a cancellation reason, two explanations for unfinished work, and an activity history. The upgrade makes Planned, In progress and Ready jobs In progress, keeps Waiting jobs Waiting with their reason as what they wait for, and makes Completed and Cancelled jobs Done on the day they closed. It writes the removed values into the job's notes under "From the old record", one line each, such as "Outcome: Serviced, +3 s/d" or "Cancelled: Owner declined the quote". Intake values that the watch no longer holds are written too, such as "Serial at intake: 0012". Reasons typed into the history that no record holds any more follow under "History", each with its date. Then the history goes.

## Job checklist

A job's checklist is a list of steps you type like a note, laid out as on the "2 Job" artboard. A step is text with a tick, or a heading such as "Cleaning". A checklist starts empty, and nothing creates or ticks steps for you. The Checklist heading says how many steps are done, such as "6 of 10 done", over a thin bar. Headings do not count, and a checklist without steps says **No steps yet**.

Type in **Add a step** to make a step there. **Return** starts the next step, and **Return** on a step without text moves on, like **Tab**. **Backspace** on a step without text removes it and puts the cursor at the end of the step before. A line that starts with "#" and a space becomes a heading. The **Up Arrow** and **Down Arrow** move between the lines. **Shift-Command-U** ticks or unticks the step, and **Control-Command-Up Arrow** and **Control-Command-Down Arrow** move it. A click on a tick box ticks it too. While you type, the keys show under the checklist.

Each change saves without a button: a step's text half a second after you stop typing and when you leave it, and a tick, a heading, a move or a removal at once. **Command-Z** undoes each change, also after it saved. Each step's right-click menu and the Checklist menu offer **Tick Step**, **Make Heading**, **Move Step Up**, **Move Step Down** and **Delete Step**. VoiceOver reads each step's text and whether it is ticked. A Done job's checklist still changes. Steps and parts are independent, so a fitted part never ticks a step, and no step changes the job's state.

Libraries from before W039 had tasks with five statuses, details, waiting and skipped reasons, and links to the job's parts. The upgrade makes each task a step in the same order, ticks the Done and Skipped ones, and adds a heading where the group label changes. It writes each task's detail and reasons into the job's notes under "From the old record", after a line such as "Step · Let down the mainspring". The links between tasks and parts go, and the parts stay.

## Required parts

Use **Add Part** in a job detail. Enter a description and a positive whole-number quantity, default 1. Track each separate unit or lot with its own requirement. Manufacturer reference is optional text and keeps leading zeros and punctuation. Compatibility is Unchecked, Confirmed, or Unsuitable. Confirmed requires an evidence note. New parts start Needed or Arrived if the complete lot is already on hand.

Use **Add link** during creation or editing. Each link holds only a complete HTTP or HTTPS URL. A part can have no links or several links. Each saved link has an explicit **Open** action. Saving, loading, and selecting parts do not fetch external content or open the browser. Removing a saved link requires confirmation and takes effect after Save.

Part editing uses **Save**, **Cancel**, **Command-S**, and the shared draft guard. A failed save keeps all draft fields and links. Pending saves block duplicate writes. A Done job's parts still change. Setting a job to Done keeps every part's status.

Use **Edit Part** to choose Needed, Ordered, Arrived, Installed, or Cancelled. Save records the current milestone dates. Arrived means the whole lot is on hand. Installed means fitted. Installing from Needed, Ordered, or Cancelled requires confirmation that the whole lot is on hand. Save records arrival and installation together. There is no partial-delivery counter.

Ordering saves an optional order reference. Correcting Arrived, Installed, or Cancelled back to Ordered keeps the order reference. Moving back to Needed clears the current order details.

Backward corrections, cancellation, and restoring a cancelled part require a reason. Save clears milestone dates that no longer apply. Cancellation keeps the order reference for reading. Cancel in the editor discards the draft. A status changed by another saved action requires cancelling and reopening the stale editor. Procurement never changes a checklist step or the job's state.

## Notes

Every watch, caliber, and job has one plain-text **Notes** section. Type in it. There is no Save button. A change saves half a second after you stop typing, again when you leave the notes, and before the app quits or the window closes. A caliber's notes are shared knowledge in that caliber. They are never copied into a watch or job.

**Command-Z** undoes a notes change, even after it saved, and **Shift-Command-Z** redoes it. **Esc** puts back the notes as they were when you started typing in them. **Command-D** types today's date. Text preserves Unicode, line breaks, and spacing. No rich text or Markdown rendering is added.

A failed save keeps the text on screen, says that it did not save, and offers **Try Again**. Quitting with notes that did not save asks before it quits. A Done job's notes still change. Archived notes stay readable but cannot change until the record is unarchived.

Libraries from before W033 had separate note records. The upgrade joins each record's notes into its notes text, oldest first. Each old note starts with its date, kind, and title.

## Material

Every watch, caliber, and job has one **Material** section. It shows the record's photos, PDFs, and links as tiles, in the order they were added. Each tile has a title and a line such as "Photo · 12 Oct". Material from another year also shows the year.

Drop photos or PDFs on the strip under the tiles, or click the strip to choose them in the file picker. Content detection accepts JPEG, PNG, HEIC, and PDF regardless of extension. The limits are 100 MB per original and 200 files per batch. Each file has its own result, and successful files stay when another file fails or the batch is cancelled. Protected PDFs, including owner-restricted copies that open without a password, are unsupported. Moving or deleting the source does not affect the managed original. A new file is titled by its filename.

Click the strip and press **Command-V** to paste a link. Dropping a web link from a browser also adds it. Only a complete HTTP or HTTPS address becomes a link. Other text shows a short explanation and adds nothing. A new link is titled by its host, such as "example.org". The strip's shortcut menu also has **Paste Link**.

Click a tile's title to rename it. The title saves as you type, like notes, and **Command-Z** undoes a rename. **Esc** puts back the title from when you started typing. A blank title puts back the old one when you leave it.

Click a photo or PDF tile to open it in the photo viewer or PDF reader. Use **Fit**, **Zoom In**, and **Zoom Out**, or pinch to zoom. Focus a photo and use arrow keys, drag, or scroll to pan. **Option-Command-Left Arrow** and **Option-Command-Right Arrow** move between the record's photos, or between a PDF's pages. **Export Original** preserves the imported bytes. A failed thumbnail shows a placeholder, and a failed load offers Retry. Click a link tile to open it in the default browser. Ure never fetches a link's page on its own.

Choose **Remove** from a tile's shortcut menu, or **Remove** in the viewer, to remove material at once. **Command-Z** brings it back, with its cover if it was one, and **Shift-Command-Z** removes it again. Its original file stays until Undo can no longer bring it back, which is the next time Ure opens the library. Originals still used by other material stay saved.

A watch or job page also shows its caliber's material as chips, such as "From Omega 552:". They open the same way. The material stays on the caliber and is never copied. Remove or rename it on the caliber page.

Use **Choose Cover** in the watch detail to select a photo from that watch or one of its jobs. **Remove Cover** clears it. Watch rows use the cover thumbnail. Caliber photos stay in the caliber and cannot become a watch cover.

A Done job's material still changes. Archived material stays readable and exportable. Unarchive the record to add, rename, or remove its material.

Libraries from before W034 kept a photo stage, a caption, a PDF's source URL, a source description, and notes on each item. The upgrade writes those values into the owner's notes under "From the old record", each item starting with its kind and title. An Unclassified stage was the default, so it is not written. No original file moves or changes.

## Bench references

Open a saved job and use **Pin Reference** to choose one saved photo, PDF, or link from that job, its watch, or its current caliber. The pin stays in place while you open notes, material, the checklist or parts. Switching jobs clears unrelated pins. A watch reference stays for another job on that watch. A caliber reference stays for a job whose watch uses the same caliber.

Use **Toggle Reference Pane** or **Shift-Command-R** to collapse or show the pane. It appears beside the editor when there is room. At narrower widths, widen the window or use **Open Reference Window** with **Option-Command-R**. The reference window has reading, zoom, explicit browser opening, and original export controls. New, Save, and section-changing commands are disabled while that window is active. Closing it leaves the main editor's draft in place.

The app restores the last selected saved job and its valid pin. Pane visibility is a preference. Missing records, changed scope, or unavailable originals clear the pin without removing saved content. References remain readable for Done jobs. External content opens only after **Open in Browser**.

## Managed original import infrastructure

W009 ([PR #36](https://github.com/jorgerodrigues/ure/pull/36)) adds the internal `FileImportService` API for JPEG, PNG, HEIC, and PDF originals. The approved limits are 100 MB (100,000,000 bytes) per original and 200 files per batch. It detects content rather than trusting extensions, keeps unchanged original bytes, and stores file size, SHA-256, dimensions, and orientation. Each import uses a generated storage key. Source filenames stay metadata only. Cancellation and per-file failures preserve committed assets. Startup recovery removes unreferenced interrupted imports through the coordinator's mutation gate. The Material section adds photos and PDFs through it.

## Local library and recovery

The app resolves its Library folder inside sandboxed Application Support. Settings shows its location. `active-library.json` selects one directory under `generations/`. Each generation holds `library.sqlite`, `manifest.json`, and `originals/`. Original files and SQLite writes share one coordinator. Database access, file copies, and hashing run away from the main actor.

Startup validates the active pointer, manifest, database integrity, foreign keys, and migration history before opening a writer. Existing data is never replaced with an empty database after a failed open. The recovery screen shows the failure and library location. Retry rechecks the saved library.

Before upgrading, the coordinator creates a recovery snapshot under `recovery/`. It uses SQLite's backup API, copies originals, and records file sizes and SHA-256 hashes. It applies migrations to a new generation copied from that snapshot. The active pointer changes atomically only after validation passes. Failed migrations keep the original generation active. Old generations and recovery snapshots are retained.

Use **Export Library Backup** in Settings to save a `.watchbackup` package. The summary shows the date, saved item count, original file count, and estimated size. **Refresh Summary** updates it. Choose a destination in the native save panel. Export shows progress and supports cancellation before publication. Saves and imports wait during export. Saved records remain readable.

The package contains an independent SQLite snapshot, `manifest.json` for the library identity, unchanged originals, and a versioned `backup.json` with the export time, app version, migration history, table counts, byte counts, and SHA-256 hashes. SQLite backup includes committed WAL data. Caches, abandoned files, local preferences, and recovery generations are omitted. The app checks the whole staged package before publishing it. A failed or cancelled export keeps an existing destination intact. Successful replacement uses an atomic directory swap. Filesystems that reject atomic publication report an error and keep the previous backup.

Use **Restore Library Backup** in Settings to choose a `.watchbackup` package. Ure checks and prepares an independent copy. Review its date, app version, record counts, original count, and size. Restore replaces the current library. It does not merge records. Changes made after the backup date will be lost. Save or cancel drafts and wait for pending saves and imports before restoring. You can cancel while checking the package or after review. **Replace Library** requires a separate confirmation.

Before replacement, Ure makes and checks a complete recovery copy of the current library. A failed recovery copy prevents the switch. Library operations drain and database connections close before the pointer changes. The old generation stays saved. A failed first open returns to it. If rollback fails, Ure shows recovery and preserves the files. It never creates an empty replacement. Main screens reset and reload. Open reference windows reset. Commands from old screens cannot write after activation. **Show Recovery Copy in Finder** locates the recovery copy after an attempt that saved one.

Settings retains the last successful user export time. That time does not confirm that the backup still exists. Recovery copies are local protection against app failures. Store an exported copy on another disk to protect against loss of the Mac. Do not keep valuable records only in this app before the Recovery and Release milestones pass.

## Verification

```sh
make lint       # Formatting and unsafe Swift constructs
make build      # Unsigned Debug build, including compiler type and concurrency checks
make release    # Unsigned optimized Release build
make test       # Swift Testing unit tests
make test-ui    # XCUITest keyboard navigation, Settings, and light/dark window launch
make test-all   # All tests
make check      # Full lint, Debug build, and isolated unit tests
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

The Release configuration enables optimization and whole-module compilation. The shared scheme's Profile action uses Release. Use **Product > Profile** with Instruments' SwiftUI and Time Profiler tools to find expensive updates and main-thread work. W031 records realistic data and decoding measurements through `make performance`. Those command-line measurements do not establish native rendering or input performance.

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
- [W027 restore staging verification](docs/planning/restore-staging-verification.md)
- [W028 restore activation verification](docs/planning/restore-activation-verification.md)
- [Design: brand, app icon, and macOS 27 screen rules](docs/design/README.md)
- [Paper design foundations and local installation verification](docs/planning/design-install-verification.md)
- [W033 record notes verification](docs/planning/record-notes-verification.md)
- [W034 material verification](docs/planning/material-verification.md)

The user approved the current-platform direction and W002's SQLite/GRDB storage design on 1 October 2026. Shared caliber records and the repair history rule were approved on 2 October 2026. Watch, caliber, intake, stage, and condition forms use explicit Save and Cancel editing. W003, W004, and W005 are merged through [PR #29](https://github.com/jorgerodrigues/ure/pull/29), [PR #31](https://github.com/jorgerodrigues/ure/pull/31), and [PR #32](https://github.com/jorgerodrigues/ure/pull/32). W006 is merged in [PR #33](https://github.com/jorgerodrigues/ure/pull/33). W007 is merged in [PR #34](https://github.com/jorgerodrigues/ure/pull/34). W008 is implemented in [PR #35](https://github.com/jorgerodrigues/ure/pull/35). Native UI and device checks are deferred to release acceptance by agreement. GitHub holds story descriptions, acceptance criteria, and current status. The repository holds the specification and verification evidence.

The GitHub Actions workflow uses the [macOS 27 arm64 runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) and Xcode 27. It runs `make check` and `make release` on pull requests and pushes to the live default branch, `w002-recoverable-library`. `make check` selects only `UreTests`. Native UI and device checks run locally during release acceptance and never on CI.

Current platform references: [Apple's Xcode requirements](https://developer.apple.com/xcode/system-requirements/), [Observation](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro), [Swift concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html), and [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance).
