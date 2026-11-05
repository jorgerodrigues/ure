# W038 sidebar and jobs verification

Recorded on 5 November 2026 for W038, [issue #66](https://github.com/jorgerodrigues/ure/issues/66), the sixth Rework story. The branch started at `2877fae` on `w002-recoverable-library`, which includes W033 to W037. W039 ran at the same time in another session and merged first as `619bf6e`. The branch then took in W039, the migration moved after W039's `v24-checklist-steps`, and the Jobs list counts W039's checklist steps.

## Design source

The session read the live Paper file Ure, page "Rework · Simple", token hash `b9b53808`. It read the sidebar, the toolbar, the Jobs list and the page of a job without a watch on "6 New job" with the JSX tool, and compared the sidebar and toolbar of "2 Job", "3 Parts" and "4 Watch" with the window check's renders.

### Differences found and fixed

The sidebar, the toolbar, the Jobs list and the picker were built from the JSX values. The sidebar has the 11 pt group headings "Workshop" and "Library", 28 pt rows with an 18 pt icon slot and plain counts. The icons follow the artboard: a wrench for Jobs, a box for Parts, a watch for Watches and a ringed dot for Calibers. The Jobs rows have a 36 pt tile 10 pt from the text, a 13 pt semibold name and an 11 pt line, and a job without a watch has a dashed tile with 8 pt corners. The picker's list is 380 pt wide with a 6 pt inset, 12 pt corners, 48 pt rows with 32 pt tiles and a 36 pt last row, placed 4 pt left of the field and 8 pt under it. The renders matched the artboards in layout, so no layout change was needed after them.

1. The first renders drew the whole sidebar column blank. The sidebar itself was right: captured on its own it shows both groups, the icons and the counts. The window's frame view leaves out the glass that holds the sidebar, so the check now also captures the sidebar list directly.
2. The toolbar's "+" buttons were named "Add Watch" and "Add Caliber" while the menu said "New Watch" and "New Caliber". The artboards' toolbars have one New button per section, so the buttons and the menu now share "New Job", "New Watch" and "New Caliber".

### Differences left on purpose

- The counts follow the artboards. Jobs counts the rows of its list, as "2 Job" counts four with three open and one done recently. Parts counts the parts still to buy, as "3 Parts" counts two with "2 to buy · 2 ordered". Watches and Calibers count what is not archived.
- The toolbar's search field is the native one. It grows with the toolbar where the artboard's field is 220 pt wide.
- The sidebar uses the native sidebar selection and counts. The selected row's label draws black in the offscreen render, as it did in W033 to W037.
- Tiles show the watch's cover photo, or a photo symbol when it has none, as the Watches list does. The artboards' tiles are illustrations.
- The picker does not set the typed letters in bold, as "6 New job" does in "**Ham**ilton".
- A job without a watch keeps the job page's sections in their current order and wording: Parts before Checklist, "Opened today" and "Add photos, PDFs or links". "6 New job" puts Checklist first and says "Opened just now" and "Add intake photos". W040 rebuilds the Parts section.
- The job page's pin and reference buttons stay in the toolbar while a job is open, as W012 needs. The artboards leave them out.
- In Jobs the toolbar has no Back to Watch button, because the list holds the job. A job opened from its watch's page still has it.
- Search Library is no longer a toolbar button, because every window artboard has only the New button and the search field. It stays in the Edit menu with ⇧⌘F.

## What changed

- Migration `v25-jobs-without-watch` rebuilds the job table so a job's watch can be empty. Every row keeps every value, and no updated time changes. The indexes and the two watch cover triggers come back as they were. The rule of one open job per watch stays in the database index, and jobs without a watch do not count against each other. No field goes, so nothing is written into notes.
- The sidebar has two groups, Workshop with Jobs and Parts, and Library with Watches and Calibers, each with a plain count. ⌘1 to ⌘4 select them in that order, where they were ⌥⌘1 to ⌥⌘4.
- Jobs replaces the workshop overview and its stage filter. It groups In progress, Waiting and Done recently, each open job once, and the jobs done on any day from 30 days ago to today. A row shows the watch's cover and name and a line such as "Full service · 6 of 10 · 1 to buy". The toolbar reads "Jobs" with "4 open · 1 waiting". The workshop overview's state, view and query are gone.
- New Job in the toolbar and ⌘N in Jobs make "New Job" without a watch, with the cursor in its title and the title selected. Return moves to the watch picker, which finds a watch by name, brand or caliber and can make a new watch with the typed name. Picking a watch saves at once, and ⌘Z puts back "No watch yet". A watch that already has an open job says so, and picking it opens that job. The new job goes away then only when nothing is in it yet.
- A job without a watch shows "No watch yet" in the list and on its page, has no cover, and keeps everything typed on it. Search finds it as "No watch yet · New crystal" and opens it in Jobs. The parts overview lists its parts. Bench references offer its own material.
- The toolbar holds the section's New button and a search field with the prompt "Search", which finds within the section. ⌘F puts the cursor there from every section. The Search Library toolbar button is gone. Search Library stays in the Edit menu with ⇧⌘F.
- Every toolbar button is a menu command with the same name. The menu's New command takes the section's name, "New Job", "New Watch" or "New Caliber", and the toolbar's New buttons took the same names, where they were "Add Watch" and "Add Caliber". The Record menu's Edit, Remove and Back commands take the names of the buttons on the open detail, such as "Edit Part", "Remove Photo" and "Back to Job". "Cancel Editing" became "Cancel".
- The Parts toolbar reads "1 to buy · 1 ordered", as on "3 Parts".
- The specification sections 3, 4, 5, 6, 10 and 11 and the README describe the sidebar, the toolbar, Jobs, New Job and jobs without a watch. The UI tests use the new shortcuts and names, and the workshop UI test now drives New Job and the picker.

## Executed checks

Development Mac: Apple silicon, macOS 27.3, Xcode 27.2. The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed explicitly. The Mac's region format is Denmark, and it runs in dark appearance.

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build` | Passed, unsigned Debug |
| `make check` | Passed lint, unsigned Debug, and 254 tests in 395 runs with no failures or skips, on the merged final code. Result bundle `ure-20261105-152824.xcresult`. Before the merge it passed 272 tests in 442 runs. All test targets also compile, including the rewritten UI tests |
| `make release` | Passed, unsigned optimized Release, before and after the merge. The Release `UrePerformanceHarness` also builds |
| `make recovery` | Passed all 58 recovery scenarios, before and after the merge, including upgrades of the retained v10 and v15 libraries with every interruption checkpoint |
| Isolated running app | Passed. See below |
| Local window check | Passed on the final code. See below |

### Acceptance criteria

1. The sidebar groups and counts match the artboards, and ⌘1 to ⌘4 work. `WorkshopSectionTests` checks the two groups, the order and the shortcuts 1 to 4. The window check rendered the sidebar with "Workshop" holding Jobs 6 and Parts 1, and "Library" holding Watches 7 and Calibers 2, selected each section in turn, and read ⌘1 Jobs, ⌘2 Parts, ⌘3 Watches and ⌘4 Calibers in the app's real View menu.
2. Jobs shows each open job once in the right group, and the jobs done in the last 30 days. `JobListTests` checks that every open job shows once in its group, with a job without a watch under In progress, and that an archived job and a job done 40 days ago do not show. It checks the boundary with jobs done 29 and 30 days ago, at the first moment of the day 30 days ago, at the last moment of the day 31 days ago, and 31 days ago, and that a job leaves the list when the day changes. `JobListStateTests` checks that the list follows checklist steps, parts, the waiting text and the watch's name, and moves a Done job to Done recently. The window check's seed had jobs done 29, 30 and 31 days ago, and the list showed the first two.
3. ⌘N and New Job make a job with the cursor in its title, and the picker finds a watch by name, brand or caliber. `WorkshopSectionTests` runs the New action in each section. `JobWatchTests` checks the picker's matches by name, brand and caliber, that archived watches stay out, the order, the limit of six, the arrows and the new watch row. The window check ran New Job, found the title focused with "New Job" selected, typed "New crystal", pressed Return, and found the cursor in the Watch field. Typing "ham" showed Railroad pocket watch, "Hamilton · 1940s · Hamilton 992B", then Ventura, "already has an open job", then "New watch named “ham”". The real File menu reads "New Job" with ⌘N.
4. A watch with an open job never gets a second open job. `JobWatchTests` checks that the service refuses it on start and on a watch choice, that the database refuses it, that a Done job can take that watch and can't leave Done while the watch has an open job, and that picking the watch in the picker opens its job. It checks that the job being set up goes only when it is blank, and stays when you typed in it, also when the typing had not saved yet. The window check picked Ventura and opened its job, and the typed job stayed with no watch.
5. A job without a watch keeps what you typed, also after you quit. `JobWatchTests` writes a title, a problem, notes, a checklist step, a part, a link and a waiting text on a job without a watch, closes the library and opens it again, and finds them all, in Jobs, in the parts overview and in search. The Debug binary kept a job without a watch across a quit and a new launch.
6. ⌘F focuses search from every section. The window check asked for the search focus in Jobs, Parts, Watches and Calibers and found the toolbar's search field with the prompt "Search" focused each time. The real Edit menu reads "Search" with ⌘F, and it has no other ⌘F command.

The migration has its own tests. `JobWatchMigrationTests` upgrades an on-disk library made by the v24 schema and checks every job's values, its checklist steps, parts and material, the indexes, the triggers, the integrity check and the foreign key check, and that the watch is now optional. It restores a backup made before v25, and it upgrades a library whose watch cover is a photo of its job. The older migration and restore tests now upgrade through v25 too. W039's test that its reversal leaves exactly the v23 schema passes with the v25 reversal in front of it.

### Isolated running app

The Debug binary ran directly with `URE_TESTING=1` and a new `URE_TEST_LIBRARY_ID`. The Debug build from the test runs is signed with the app sandbox, so its library is in the app container's `tmp/UreTests/<id>`. Its first launch made an empty library there. It was quit, that library was replaced by a library at the schema before v25, written by the real migrator, and it was launched again. The seed had eight watches, an archived one among them, two calibers, two jobs In progress with ten and fourteen checklist steps and two parts, a waiting job, Ventura with an open job, and Done jobs finished 29, 30 and 31 days ago. The app upgraded the library to `v25-jobs-without-watch` in a new generation and kept the generation before it. Reading it showed the watch optional, the four job indexes and the two cover triggers, an integrity and foreign key check that passed, and every job, step, part and watch row identical to the generation before it. A job without a watch was then written into the upgraded library while the app was quit. The app launched on it, quit, and the job was still there with its title, problem and notes. Each copy was quit by its PID, and no Debug copy is left running. The installed `/Applications/Ure.app` and the real library were not touched.

### Local window check

This Mac gives sessions no Screen Recording or Accessibility permission, so there is no screenshot of the running app's own window. As accepted for the Rework stories on 5 November 2026, a local-only test hosted the app's real `LibraryRootView`, with every session environment, in a window of the test host. This time the hosting view bridged its toolbar into the window, so the New button and the search field are real toolbar items. It opened a library made by the v24 schema and drove the real views. It was never committed and never runs on CI. It ran again on the merged final code and checked these things in order:

- The migrated library has the optional watch and every job.
- The sidebar with both groups and counts, and the Jobs list with In progress, Waiting and Done recently, such as "Grandfather’s Seamaster" with "Full service · 6 of 10 · 1 to buy", "Dress watch, 1962" with "Waiting for a mainspring", and "Field watch" with "New crystal · Done 7 Oct". The toolbar reads "Jobs" and "4 open · 1 waiting", and holds New Job and Search.
- Each section in turn, with its New button or filter, and the search field focused from each.
- The toolbar search finds "seamaster" within Jobs.
- New Job, the title, Return, and the picker as on "6 New job". The picker field's cell has the text field role and the label "Watch".
- A job showing "No watch yet" in the list and on its page.
- The picker on Ventura, a watch with an open job, and picking it, which opens Ventura's job.
- Picking Railroad pocket watch, which gives the job its watch and cover tile and its links, then Undo, which reads "Undo Choose Watch" and puts back "No watch yet".
- A part opened in Parts, then Back to Watch, which shows the watch's page.
- The app's real main menu: New Job ⌘N, Search ⌘F, Search Library ⇧⌘F, Close Search, Jobs ⌘1 to Calibers ⌘4, Toggle Reference Pane, Open Reference Window, Pin Reference, and the Record menu's Edit, Remove and Back.
- The Jobs list and the picker in dark appearance.

The renders of the final code are in `~/Developer/test-assets/jorge-w038-sidebar-0316fa/window-check/`, with `check-log.txt` listing what each step read. `debug-binary-migrated-library.txt` in the same folder is the reading of the running app's upgraded library.

These are the limits of the substitution:

- The window ignores the mouse, because a real mouse over the test window crashed SwiftUI's hover hit test in W036. Clicks on rows, buttons and the picker's rows were not driven. A pick was Return in the picker field, which is the same call a click makes.
- The main menu in the test host belongs to the app's own session, not to the hosted window. The check read its titles and shortcuts, and called what each command calls, such as the New action, the section selection and the search focus, on the hosted session. Key presses through the menu were not sent.
- The test host turns off undo grouping by event, so each simulated key press opens and closes its own group. A watch choice registers its Undo after it saves, so the check keeps the group open across it.
- SwiftUI fills in its accessibility tree only when an accessibility client is attached, so the sidebar's counts and the picker's rows could not be read through accessibility in the test host. VoiceOver itself did not run. The AppKit fields could be read.
- The offscreen render leaves out the glass behind the sidebar, so the window renders show the sidebar column blank and the check captures the sidebar list on its own. There the selected row draws black, as in W033 to W037.

## Codex review

The review ran with `codex exec review --ignore-user-config`, which used Codex's default model, `gpt-6-astra`, and left `~/.codex/config.toml` unchanged. Rounds one to four read the whole diff against `2877fae`.

1. Round one found two things, and both were fixed. Picking a watch that has an open job could remove the new job before a save of what you typed in it had landed, and so lose that text. The pick now waits for every field to save and removes the job only when nothing is unsaved and nothing is in it. Round one also found that Back to Watch from a part in Parts left an empty detail, because Parts now shows the job page straight away. Parts again shows the watch's page when its job closes, and only a job with a watch offers Back to Watch.
2. Round two found two things, and both were fixed. While the fields saved, you could choose another job, and the pick would then remove that other job if it was blank. The pick now belongs to the job it started on and stops when the selection changes. Round two also found that a New Job that did not save said nothing, because no job was selected. The empty Jobs detail now shows why.
3. Round three found that a job done 31 days ago stayed in Done recently, and in the sidebar's count, when the app stayed open past midnight. The cutoff is now observed, and it moves on at the system's day change and when the app becomes active.
4. Round four read the code before the merge, commit `3054ee0`, and reported no findings.
5. Round five, on the merged code against `619bf6e`, did not run. Codex failed to start three times with "Selected model is at capacity", and the user said to continue without it. So the last round that ran is round four, on commit `3054ee0`, and it found nothing. Code changed after round four only in the merge with W039: the migration moved to v25, its test reversal now runs before W039's, the Jobs list counts W039's checklist steps, and the tests moved from tasks to steps. `make check`, the migration tests, the window check and the Debug binary run all passed on the merged code.

## Remaining gates

- Native UI tests were not run, as the repository rules require during story work. The workshop UI test was rewritten for Jobs, New Job and the picker, and the other UI tests use ⌘1 to ⌘4, `newRecord` and ⇧⌘F. They compile but have not run. W042 runs them.
- The performance measurement was not rerun. Its worker now measures the Jobs list as `jobList` and still builds.
- The Parts toolbar's status filter is a pop-up, not a button, so it has no menu command. W040 replaces that list.
