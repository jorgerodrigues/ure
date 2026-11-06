# W040 part records verification

Recorded on 5 and 6 November 2026 for W040, [issue #68](https://github.com/jorgerodrigues/ure/issues/68), the eighth Rework story. The branch started at `0c6db56` on `w002-recoverable-library`, which includes W033 to W039. The latest migration there was `v25-jobs-without-watch`, so this story adds `v26-parts`.

## Design source

For most of the session Paper refused every read of the file Ure with "Edit access is required to use MCP for this file", while the Paper app's active file was another one. The parts were first built from the issue's description and the earlier verification records. Once the user opened Ure again, the session read the live file, page "Rework · Simple", token hash `b9b53808`. It read the Parts section on "2 Job", the list and the part page on "3 Parts", and the parts card on "7 Typing" with the JSX and computed-style tools, and compared them with the window check's renders.

The parts were then rebuilt from the JSX values. On the job page the heading is 17 pt bold with "1 to buy" in 13 pt, 4 pt above a thin line. Each part is a 56 pt row with a thin line under it. The state is a 76 pt pill, 22 pt high, in 12 pt semibold, 16 pt from the name. Needed is an outline at 22 percent of the label colour, Ordered the accent colour at 12 percent with accent text, In hand the accent colour with white text, and Fitted the quiet fill with a 9 pt tick in the secondary colour. The name is 15 pt on a 20 pt line, with the quantity after it in the secondary colour, such as "Gaskets × 3". Under it, 2 pt lower, a 12 pt line in the secondary colour holds the description and the day of the state, such as "Sternkreuz 30.0 mm · ordered 31 Oct". A fitted part's name and line read quieter. The add row is 48 pt high with a 12 pt plus in the middle of the state column and "Add a part or use a spare" in 15 pt tertiary. While you type there, as on "7 Typing", the row shows the Needed pill, the name with the field's typing ring, and a Description field to its right that Tab reaches, with the keys under it in the checklist's key style.

The Parts list has rows of 52 pt with a 36 pt tile with an 8 pt radius 10 pt from the text, a 13 pt semibold name and an 11 pt line. A part on a job shows its watch's cover and name, and a spare shows the `archivebox` drawer on the quiet fill and "Spare". An ordered part adds its order day, such as "Pocket chronometer · 31 Oct", and the quantity follows the name, such as "Dial feet × 2". The part page has the state pop-up pill with "Added 14 October" and the days the part reached, the 26 pt bold name, and one 13 pt medium link after a 20 pt cover, such as "Full service, Grandfather’s Seamaster ›". Under a thin line, 40 pt below the header and 20 pt above the facts, come the description in 15 pt on 24 pt lines, which can take several lines, and the quantity, with the description three times as wide.

### Differences found and fixed

1. The first build drew each part as one dense line with columns for the description, the quantity and the day. "2 Job" has a two-line row, so the rows were rebuilt as above.
2. The first pills were all in the accent colour with a dot, like a job's. "2 Job" gives each state its own look, so the pills changed to the four styles above.
3. The drawer was the `cabinet` symbol. "3 Parts" draws an archive box, so it is `archivebox` now.
4. The Parts list's line said "Grandfather’s Seamaster · Full service · × 3". "3 Parts" names only the watch, puts the quantity in the name, and adds an ordered part's day.
5. The part page had a tile-less header with separate job and watch links and the days without "Added". It now follows "3 Parts" with the added day, one link and the thin line, and the description takes several lines.
6. The add line said "Add a part" and had no description. It now says "Add a part or use a spare", shows the Needed pill while you type, and takes a description after Tab, as on "7 Typing".
7. The first renders put the quantity far from a short name, cut a long name short, and left the typed name on the add line after Return. The name is now as wide as its text, and the line empties its own field at once.

### Differences left on purpose

- The prices, "Compare 3 options", "from €21.40", "€42.40 paid", the Options section, "Mark as Bought…" and "Paste a link as an option" belong to W041. The rows keep the room for the price column, and the job line has a small arrow there that opens the part's page.
- The part page shows the saved links in a Links section with Open, where "3 Parts" has the Options. W041 turns the links into options.
- "From your spares" on a fitted part that came from the drawer is not shown, because a part does not record that it was a spare.
- While you type a name, the spares in hand show under the line in a list like the fact suggestions, with "Spares in the drawer" above them. The artboards describe this in words only.
- The tiles show the watch's cover, or a photo symbol when it has none. The artboards' tiles are illustrations.

## What changed

- Migration `v26-parts` makes the `part` table: an optional job, a place among the job's parts, a name, a description, a quantity, a state, the dates ordered, in hand and fitted, notes and a search key. The database refuses a date that the state has not reached. Each part requirement becomes a part with the same ID, job, quantity and times, in the order its job's requirements were made. The description becomes the name and the manufacturer reference the description. Arrived becomes In hand and Installed becomes Fitted, with their dates. The compatibility, its note, the order reference and the status reason go into the part's notes under "From the old record", and a date the new state does not keep is written as "Ordered on 30 October 2026". A cancelled part goes into its job's notes with every value and link and is not kept. The link table is rebuilt to refer to parts, and every link of a kept part stays. No updated time changes.
- A part on a job is one line. A click on its state moves it on and records the day, and ⌘Z puts back the state before with its day. The line after the last part adds the next one with its description. Return adds it and the line is ready for the next. Return on an empty line moves on to the checklist. While you type a name, the spares in hand whose name matches show under the line, and the Down Arrow and Return, or a click, put one on the job, with Undo. Each burst of typing on the line is its own Undo step. A part that did not save stays under the line with Try Again, and quitting asks about it. Right-click sets any state, opens the part or deletes it with Undo.
- The Parts list groups To buy, Ordered and In hand, on open jobs and in the drawer, and marks spares with a drawer. The toolbar reads "2 to buy · 2 ordered", and the sidebar counts the parts to buy. New Part and ⌘N in Parts make a spare in hand with the cursor in its name.
- The part page shows the state pop-up, the name, the job and watch, the description, the quantity, the saved links and the notes. Each saves as you type with Undo. Delete Part is in the Record menu.
- The parts overview, the part editor sheet, the part drafts and the last Save, Discard or Stay guard are gone. The File menu has no Save or Cancel. Search finds parts by name, description and notes, and a spare opens in Parts. Steps and parts stay independent.
- The specification sections 1 to 6, 10, 11 and 12 and the README describe parts. The recovery harness checks every part requirement of the retained libraries, and the performance fixture seeds parts.

## Executed checks

Development Mac: Apple silicon, macOS 27.3, Xcode 27.2. The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed explicitly. The Mac's region format is Denmark, and it runs in dark appearance.

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build` | Passed, unsigned Debug |
| `make check` | Passed lint, unsigned Debug, and 252 tests in 341 runs with no failures or skips, on the final code, commit `c2433ce`. Result bundle `ure-20261106-060753.xcresult`. An earlier run, while Codex ran on the same Mac, failed two backup export tests on a 10-second wait. Both pass alone in 0.2 seconds and in the final run, and no backup code changed. All test targets also compile, including the rewritten UI test |
| `make recovery` | Passed all 58 recovery scenarios, including upgrades of the retained v10 and v15 libraries with every interruption checkpoint |
| Isolated running app | Passed. See below |
| Local window check | Passed on the final code. See below |

### Acceptance criteria

1. Adding a part on a job takes one line and no sheet. `PartServiceTests` adds parts to the end of a job, Needed, with a blank name taking "New Part", and refuses a part on an archived job. `PartStateTests` adds parts with Undo and Redo, keeps a name that did not save under the line with Try Again, also while the next one is typed, retries it without adding it twice, and asks before quitting while it has not saved. The window check typed "Hairspring", pressed Tab, typed "Nivarox, for 552" and pressed Return, and found the new line and the cursor back in the name.
2. Clicking the state moves it on and records the date, and ⌘Z undoes it. `PartServiceTests` moves a part from Needed to Fitted with each day, keeps it Fitted on another click, keeps and clears days when it goes back, and puts back a state exactly. `PartStateTests` undoes and redoes a click with its day, moves a part on twice with two quick clicks, and puts the state back with ⌘Z. The window check clicked Mainspring's state and read "Ordered" with "ordered 6 Nov", the day of the run, and "Undo Change Part State", then ⌘Z put back "Needed" with no day.
3. A spare can be made in Parts and used on a job from the part line. `PartStateTests` makes a spare with New Part with the cursor in its name, offers only spares in hand whose name has the text, in any case and without accents, moves the highlight with the arrows, and uses a spare with Undo back to the drawer. `WorkshopSectionTests` runs New Part in Parts. The window check typed "crys", found "Crystal, sapphire 30.0 mm" offered, pressed Down and Return, and found the spare on the job.
4. Every existing part keeps its job, quantity, state and dates after migration, and no typed value is lost. `PartMigrationTests` upgrades an on-disk library made by the v25 schema with parts in all five old states, every removed field, a corrected part that kept an order date, two cancelled parts, one with every value and links and one with none, saved links, and job notes that already hold the heading. It checks each part's ID, job, name, description, quantity, state, dates, place, notes and times, that the links of kept parts stay, the exact notes of each job, the search keys, and the integrity and foreign key checks. The recovery matrix checks every part requirement of the retained libraries.
5. A backup made before this change restores. `PartMigrationTests` stages and activates a backup package made by the v25 schema and checks every part and the job notes. The older migration and restore tests now upgrade through v26.

The reversal chain starts with `PartMigrationFixture.restoreRequirements`, and `theReversalLeavesTheSchemaBeforeParts` checks that it leaves exactly the v25 schema.

### Isolated running app

The Debug binary ran directly with `URE_TESTING=1` and a new `URE_TEST_LIBRARY_ID`. The Debug build from the test runs is signed with the app sandbox, so its library is in the app container's `tmp/UreTests/<id>`. Its library was a v25 library written by the real migrator before the launch, seeded with part requirements in all five old states, every removed part field, a cancelled part with its reason and link, and parts with saved links. The app upgraded it to `v26-parts` in a new generation and kept a recovery copy. Reading it showed six parts with their states, quantities, dates and places, the compatibilities, order references and status reason in their notes, the cancelled part in its job's notes with its link, three links on their parts, no `partRequirement` table, the job's updated time unchanged, and an integrity check that passed. The copy was quit by its PID. Two spares with no job were then written into the upgraded library, the app launched on it, and it opened with both spares. It was quit by its PID again. The Debug binary of the final code then upgraded a fresh copy of the same v25 library the same way: six parts, two Needed, two Ordered, one In hand and one Fitted, three links, no `partRequirement` table, and an integrity and foreign key check that passed. Each copy was quit by its PID, and no Debug copy is left running. The installed `/Applications/Ure.app` and the real library were not touched.

### Local window check

This Mac gives sessions no Screen Recording or Accessibility permission, so there is no screenshot of the running app's own window. As accepted for the Rework stories on 5 November 2026, a local-only test hosted the app's real `LibraryRootView`, with every session environment and the bridged toolbar, in a window of the test host. It opened a library made by the v25 schema and drove the real views. It was never committed and never runs on CI. It ran on the final code and checked these things in order:

- The migrated library at `v26-parts`, with every part, its notes and the cancelled part in the job's notes.
- The job's part lines, such as "Needed · Mainspring · GR 3800" and "In hand · Gaskets × 3 · 0012-Å · arrived 3 Nov". Each name field's cell has the text field role and the label "Name", and the add line's has "Add a part or use a spare".
- A click on Mainspring's state, which reads "Ordered" with its day and "Undo Change Part State", and ⌘Z, which puts back "Needed".
- A spare suggestion for "crys", the highlight with the Down Arrow, and Return, which puts the spare on the job and leaves the line empty with the cursor in it.
- A typed part with Tab to its description and Return, which adds "Hairspring" with "Nivarox, for 552" and puts the cursor back in the name, and Return on the empty line, which moves to the checklist.
- The Parts list with To buy, Ordered and In hand, the drawer for the spare, and the toolbar's "3 to buy · 2 ordered".
- The part page, also with a two-line description, and a spare's page.
- New Part, which makes "New Part" in hand with the cursor in its name and the name selected, and typing "Gasket set" over it.
- The job's part lines in dark appearance.

The renders of the final code are in `~/Developer/test-assets/jorge-w040-parts-fb5cc4/window-check/`, with `check-log.txt` listing what each step read.

These are the limits of the substitution:

- The window ignores the mouse, because a real mouse over the test window crashed SwiftUI's hover hit test in W036. The state click and the spare's use were driven through what the pill's button and Return call. Clicks were not sent.
- The main menu in the test host belongs to the app's own session, so the Record menu's Delete Part was not read from the hosted window.
- The test host turns off undo grouping by event, so each simulated key press opens and closes its own group. Adding a part registers its Undo after it saves, so the check keeps the group open across it. Before that, one run crashed in an executor check, as W036 recorded.
- Two runs paused for about nine minutes at one of the check's half-second waits and then passed. A third run of the same code passed in 12 seconds. The pause was not in the app's code path that the check drives, and its cause was not found. The hidden test host may have been throttled.
- SwiftUI fills in its accessibility tree only when an accessibility client is attached, so the pills and the list rows could not be read through accessibility in the test host. VoiceOver itself did not run. The AppKit fields could be read.

## Codex review

The review ran with `codex exec review --ignore-user-config`, which used Codex's default model, `gpt-6-astra`, and left `~/.codex/config.toml` unchanged. Each round read the whole diff against `0c6db56`.

1. Round one found that deleting a part whose quantity read "0" left that field counted as unsaved, so quitting and restore asked about text nobody could reach. A deleted part's fields now go with it.
2. Round two found two things, and both were fixed. A part name that failed to save while the next one was typed was lost, and a deletion went ahead after a valid change on the part failed to save. A name that did not save now stays under the line with Try Again, and a field that did not save stops the deletion.
3. Round three found three things, and all were fixed. Quitting did not count part names that had not saved, two quick Try Agains could add a name twice, and two quick clicks on a state moved the part on only once.
4. Round four, after the design pass, found that Return on an empty name went into the add line's own description. It now skips it and moves to the checklist.
5. Round five found that typing on the add line had no Undo, so ⌘Z removed the part added before it. Each burst of typing there is now its own Undo step.
6. Round six, on commit `1dc998c`, found that two quick choices from the part page's pop-up could drop the last one, because the check used the part's state before the first change had saved. The queued change now lets the stored part decide, and a new test fails without the fix. Six rounds is the most the story steps allow, so no seventh round ran. The final code, commit `c2433ce`, has had no clean Codex round. Code changed after round six only in `PartState.setStage` and its test.

## Remaining gates

- Native UI tests were not run, as the repository rules require during story work. The part UI test was rewritten for the one-line parts, the spare and the state click, and the parts overview UI test was removed. They compile but have not run. W042 runs them.
- The performance measurement was not rerun. Its worker now measures the Parts list as `parts` and still builds.
- No link can be added to a part until W041, which turns links into buying options. The links already saved stay and open.
