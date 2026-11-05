# W036 watch in place verification

Recorded on 5 November 2026 for W036, [issue #64](https://github.com/jorgerodrigues/ure/issues/64), the fourth Rework story. The branch started at `065d581` on `w002-recoverable-library`, which includes W033, W034 and W035.

## Design source

The session read the live Paper file Ure, page "Rework · Simple", token hash `b9b53808`. It read the "4 Watch" and "4b Archived watch" artboards, the Material section on "4 Watch", and the rules on "1 Model" with the JSX tool, and compared them with the window check's renders. Two rules on "1 Model" decided the archive: "Archiving has no rules", and an archived watch's open job stays in Jobs.

### Differences found and fixed

The page was built from the JSX values. The first renders of it still differed from the artboards in these ways, and both are now fixed:

1. The Watches and Calibers lists drew a separator between rows. The artboards have none, only the hairline above "Archived".
2. On an archived watch, the caliber pop-up was greyed out like a disabled button. On "4b Archived watch" the caliber reads in the label colour with its arrow. A fact pop-up that can't change now reads as plain text, like a typed fact at rest. The archived caliber's winding reads the same way.

### Differences left on purpose

- The open job under the watch's name shows the job's own title, such as "Full service". The artboard's "In for a full service" is sample wording that the app can't build from a title.
- The artboards' watch thumbnails, cover and material tiles are illustrations. The page shows the watch's cover photo, or a watch symbol when it has none. Clicking the cover chooses a photo, which the artboard does not show.
- "4b Archived watch" shows the drop strip on the archived watch. The specification keeps an archived record read-only, so its page says "Unarchive this record to add or change its material" instead.
- A watch with no open job offers Start Job under its jobs. The artboards only show a watch with an open job. W038 starts jobs inline.
- The list's stage words are the current six stages until W037 makes them In progress, Waiting and Done. "Completed" has the tick the artboard gives "Done".
- PDF tiles say the date they were added, not "2 pages", which would need the PDF read on every page.
- The toolbar's "+" on "4 Watch" is named "New job" in the Paper layers. The app keeps it as Add Watch, because ⌘N in Watches makes a watch.
- The sidebar's Workshop and Library groups and plain counts come with W038.

## What changed

- Migration `v22-watch-owner` adds `owner` and `contact` to the watch. Each watch takes the owner of its most recent job that names one, with that job's email and phone joined into the contact, such as "ana@example.pt · +351 912 480 117". The issue says to take the owner from the most recent job. The migration takes it from the most recent job that names one, so a newer job with no owner details does not leave the watch without a known owner, and the name and contact always come from the same job. Every other job whose owner differs is written into the watch's notes under "From the old record", oldest first, as "Job · Full service" followed by "Owner:", "Email:" and "Phone:" lines. The watch's condition, condition note, water resistance and specification notes are written there too, one line each. Unknown was the default condition, so it is not written. Then those columns go from the watch, and the owner columns go from the job. No updated time changes. Search finds the owner and contact, and older owners through the notes.
- The watch page is rebuilt from "4 Watch" with W035's in-place fields: the cover, the name as the title, the open job under it, the eleven facts in three columns, the jobs with their stage, task progress and date, the Material section and the notes. Each fact saves on its own through `WatchService.update`, with Undo. Diameter and lug width read millimetres as written on paper. As you type a brand, the library's brands show under the field. The caliber is a pop-up of the calibers that are not archived, and its arrow opens the caliber's page. ⌘N in Watches makes "New Watch" with the cursor in its name and the name selected.
- The watch editor sheet, `WatchDraft`, the old caliber picker and the watch parts of the Save, Discard and Stay guard are gone. Watch facts count as fields that save as you type, so leaving asks nothing and quitting waits for them.
- Archiving has no rules. Archive Watch and Unarchive Watch are in the Record menu and in the list's right-click menu, and an archived watch's page has Unarchive in the toolbar. ⌘Z undoes an archive or an unarchive, and ⇧⌘Z redoes it, through the new `ArchiveUndo`. An open job of an archived watch stays in Workshop and the parts overview and can still change. Starting a job or reopening one still needs a watch that is not archived. Calibers archive the same way.
- Archived watches and calibers fold away in a collapsed Archived section at the end of their lists, with a count and a trailing chevron. Selecting an archived record, also from search, opens the section. Search always includes archived records and marks them archived. The Archive sidebar section, `ArchiveState` and `ArchiveView` are gone, and the sections are ⌥⌘1 to ⌥⌘4.
- The job page shows the owner and contact from its watch. The job editor has no owner fields, and Change Watch Condition is gone. Old condition changes stay readable in the job's activity until W037 removes it.
- W034's Material section, page style, now matches "4 Watch": 116 pt tiles with a 10 pt radius that reflow from four to a row, the one-line strip "Add photos, PDFs or links, or drop them here", and the caliber's chips on one line. The material title's VoiceOver label is now on its cell as well as its field, so VoiceOver reads it.
- The recovery harness checks every removed watch value and every owner after an upgrade. The performance harness measures one search, because search no longer has an archive switch.

## Executed checks

Development Mac: Apple silicon, macOS 27.3, Xcode 27.2. The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed explicitly. The Mac's region format is Denmark.

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build` | Passed, unsigned Debug |
| `make check` | Passed lint, unsigned Debug, and 266 tests in 470 runs with no failures or skips, on the final source. Result bundle `ure-20261105-124555.xcresult`. All test targets also compile, including the rewritten watch and archive UI tests |
| `make release` | Passed, unsigned optimized Release. The Release `UrePerformanceHarness` also builds |
| `make recovery` | Passed all 58 recovery scenarios, including upgrades of the retained v10 and v15 libraries with every interruption checkpoint |
| Isolated running app | Passed. See below |
| Local window check | Passed. See below |

### Acceptance criteria

1. Each watch fact saves in place without a button. `WatchServiceTests` saves every fact on its own and rejects a blank name, dimensions out of range and a missing caliber. `WatchStateTests` types every fact, including "35mm" and "18.0 mm", picks a caliber, and reads each saved value back. The window check typed into the real fields and read the library after the pause.
2. After migration, each watch shows the owner and contact from its latest job, and other owner values appear in its notes. `WatchMigrationTests` upgrades an on-disk library made by the v21 schema with a watch with no job, a watch with one job, a watch with five jobs with different owners, emails and phones, including one identical to the kept owner and a newest job with only blank owner values, and a watch whose only job has a phone with spaces around it. It checks every owner, contact and notes text, the removed columns, that jobs keep their titles and stages, and that no updated time changes. The running app and the window check upgraded a v21 library the same way.
3. A watch with an open job can be archived, and ⌘Z or Unarchive brings it back with its jobs and history unchanged. `ArchiveServiceTests` archives a watch with an open job and a task, keeps the job in Workshop, edits the job and its notes while the watch is archived, refuses watch edits, a new job and a reopen, and unarchives after a restart with every job, task and activity record unchanged. `WatchStateTests` archives through the state with an undo manager, checks "Undo Archive Watch", Undo, "Redo Archive Watch", Redo and Unarchive against the library, and that archiving waits for a fact still saving and stops at a fact that is not valid. The window check did the same in the real window.
4. Archived watches and calibers are hidden from the main lists, appear in the folded Archived sections, and appear in search. `SearchQueriesTests` finds an archived caliber, its material, an archived job and an archived watch, each marked archived. `SearchStateTests` opens an archived watch and an archived caliber from search and finds each in its opened Archived section, and the list search filters that section too.
5. No typed value from a removed field is lost, and a backup made before this change restores. `WatchMigrationTests` stages and activates a backup package made by the v21 schema and checks every owner, contact and notes text. `MaterialMigrationTests`, `RecordNotesTests` and `CaliberMigrationTests` restore their older backups through v22 too. The recovery matrix upgrades the retained v10 and v15 libraries.

⌘N is covered by `WatchStateTests` and the window check, which ran the call the menu command makes and found the name focused with "New Watch" selected.

### Isolated running app

The Debug binary ran directly with `URE_TESTING=1` and a new `URE_TEST_LIBRARY_ID`. Because the Debug build from the test runs is signed with the app sandbox, its library lives in the app container's `tmp/UreTests/<id>`, not in `$TMPDIR`. Its first launch made an empty library there, so it was quit, that library was replaced by a v21 library written by the real migrator, and it was launched again. The seed had four watches: one with no job and a condition and water resistance, one with an open and a closed job with different owners and every removed watch field, an archived watch with a closed job, and one whose jobs had only blank owner values. It also had an archived caliber and an open job on a watch with only blank owner values. The app upgraded the library to `v22-watch-owner` in a new generation and kept a recovery copy. Reading it showed every owner and contact from the right job, every removed value in the notes under one heading, the older owner as "Job · New crystal and gaskets" with its name and email, no owner for the blank values, the removed columns gone, every updated time unchanged, and an integrity and foreign key check that passed. The copy was quit by its PID each time. The installed `/Applications/Ure.app` and the real library were not touched.

### Local window check

This Mac gives sessions no Screen Recording or Accessibility permission, so there is no screenshot of the running app's own window. As accepted for the Rework stories on 5 November 2026, a local-only test hosted the app's real `LibraryRootView`, with every session environment, in a window of the test host. It opened a library made by the v21 schema and drove the real views. It was never committed and never runs on CI. It checked these things in order:

- The migrated library has the owners, contacts and notes above, and the watch page shows them.
- Each of the eleven facts' accessibility elements has the text field role, its label and its value, and sits in the window's accessibility tree. The material title's cell now has the label "Material title" and the title as its value.
- Tab moves from the name to the brand, Return to the model, and Shift-Tab back.
- Typing a serial saves after the pause, and "Undo Serial" puts it back.
- "wide" in the diameter shows as not valid yet with "Enter a number, such as 38 mm.", and the watch keeps 35 mm. Undo clears it.
- Choosing another caliber saves at once, and "Undo Caliber" puts the first back.
- The Watches and Calibers lists show their folded Archived sections. The archived caliber and the archived watch read as "4b Archived watch", read-only.
- Archiving the watch with an open job keeps "Full service" in Workshop, and the menu reads "Undo Archive Watch". Undo brings the watch back, and the menu then reads "Redo Archive Watch". Archive and Unarchive again leave every job unchanged.
- The job page shows "Ana Ribeiro" and "+351 912 480 117" in its Owner section.
- Searching "Smiths" finds the archived caliber and the archived watch, both marked archived, and opening the watch opens the Archived section.
- ⌘N's call makes "New Watch" with its name focused and selected. Typing replaces it, Return moves to the brand, typing "Om" offers "Omega", and Tab takes it.
- The watch page in dark appearance.

The renders of the final build are in `~/Developer/test-assets/jorge-w036-watch-177705/window-check/`, with `check-log.txt` listing what each step read. `debug-binary-migrated-library.txt` next to it is the reading of the running app's upgraded library.

These are the limits of the substitution:

- A real mouse moving over the test window crashed SwiftUI's hover hit test in the test host, so the window ignores the mouse. Hover, clicks, right-click menus and the caliber's arrow were not driven. The arrow opens the caliber through the same navigation as a search result.
- Key presses were sent to the field editor as commands. Archive, ⌘N and Unarchive were the state calls that the menu commands and the toolbar button make. The real keyboard, menu bar and mouse were not driven.
- The test host turns off undo grouping by event, so each simulated command opens and closes its own group. An archive registers its Undo after its save, so the check keeps the group open across the save. Without that, AppKit refuses the registration outside a group and the test host crashes. In the app, grouping by event is on and opens the group itself.
- VoiceOver itself did not run. The check read the accessibility elements that VoiceOver reads, walking up from each field to the window.
- The offscreen render leaves out the window's own background, so the check gives its root view the window background colour. The selected sidebar row's label is blank and the sidebar's labels read dark in dark appearance, as in W033 to W035.

## Codex review

The review ran with `codex exec review --ignore-user-config`, which used Codex's default model, `gpt-6-astra`, and left `~/.codex/config.toml` unchanged. Each round read the whole diff against `065d581` and the new files.

1. Round one read the whole branch, with the page, the migration, the tests and the documents, and reported no findings.
2. The Paper comparison then changed two views: the read-only pop-up and the list separators. Round two read the whole branch on the final code, commit `59a595a`, and reported no findings.

The window check also found and fixed nothing in the app beyond the two Paper differences. Its one crash and one hang came from how the check drove the test host, as the limits above say.

## Remaining gates

- Native UI tests were not run, as the repository rules require during story work. `WatchUITests` and `ArchiveUITests` were rewritten for the page you write on and free archiving, and the watch steps of the other UI tests were updated. They compile but have not run. W042 runs them. The other UI tests still hold steps from before the Rework, such as note records, that earlier stories left for W042.
- The performance measurement was not rerun. Only its search measurement changed.
