# W039 checklist verification

Recorded on 5 November 2026 for W039, [issue #67](https://github.com/jorgerodrigues/ure/issues/67), the seventh Rework story. The branch started at `2877fae` on `w002-recoverable-library`, which includes W033 to W037. W038 runs at the same time in another session.

## Design source

The session read the live Paper file Ure, page "Rework · Simple", token hash `b9b53808`. It read the Checklist on the "2 Job" artboard and the "Steps and parts" card on "7 Typing" with the JSX and computed-style tools, and compared them with the window check's renders.

The checklist was built from the JSX values. The heading is 17 pt bold with "6 of 10 done" in 13 pt on the right, 4 pt above a 2 pt bar with a 2 pt radius. The bar's track is the quiet system fill and its fill is the accent colour, as wide as the share of steps done. The lines start 8 pt below the bar. A step is 32 pt high, with a 16 pt tick box with a 5 pt radius, 12 pt from its 15 pt text. A ticked box is filled with the accent colour and a white tick drawn from the artboard's path, and its text is in the secondary colour. An open box is a 1.5 pt outline. A heading is 12 pt semibold in the secondary colour, in line with the step text, 14 pt below the line before it, or 4 pt at the top, and 6 pt above the next line. The last row has a 12 pt plus and "Add a step" in the tertiary colour. The line you type in has the accent colour at 7 percent behind it, with an 8 pt radius reaching 8 pt past the text on each side, as on the "7 Typing" card. While you type, the card's key hints show under the checklist: "Return Next step", "⇧⌘U Tick", "⌃⌘ ↑↓ Move" and "# Start a heading", in 11 pt medium keys on the quiet fill with a 5 pt radius.

### Differences found and fixed

1. The key caps on the "7 Typing" card have a 1 pt line along their lower edge, which the first render left out. The keys now draw it in the separator colour.

### Differences left on purpose

- "2 Job" shows the checklist at rest. The session chose that the "7 Typing" card's key hints show under the checklist only while you type in it, because the card shows them under a line being typed.
- An empty checklist reads "No steps yet" in the heading, with an empty bar. The designs show only a full checklist.
- The cursor is the system's text cursor, where the card draws it in the accent colour.
- The artboards show no hover state for steps, so a step has none.
- The window check's renders draw every AppKit one-line field's text darker than its colour, also the job title from W037. A plain `NSTextField` rendered the same way does the same: label-colour text renders black. So this is how `cacheDisplay` draws text fields, not the checklist's colours. The ticked text and the headings use `secondaryLabelColor`, and the open steps `labelColor`, as the artboard's tokens do.

## What changed

- Migration `v24-checklist-steps` makes the `checklistStep` table: a job, a position, the text, whether it is a heading and whether it is ticked. The database requires text and refuses a ticked heading. Each task becomes a step with the same ID and times, in the same order. Done and Skipped tasks are ticked. A group label becomes a heading where the group changes from the task before, so a group that comes back gets its heading again and a task without a group gets none. Each task's detail, waiting reason and skipped reason go into the job's notes under "From the old record", after a line such as "Step · Let down the mainspring". Then the task table and the links between tasks and parts go. Parts stay as they were. No updated time changes, and the job search keys are rebuilt, so a moved reason is found through the job.
- The job page's Checklist is rebuilt from "2 Job". It is typed like a note. Typing in "Add a step" makes a step there, Return starts the next step, Return on a step without text moves on like Tab, and Backspace on a step without text removes it and puts the cursor at the end of the step before. A line that starts with "#" and a space becomes a heading, and Backspace on an empty heading makes it a step again. The Up and Down arrows move between the lines. ⇧⌘U ticks, and ⌃⌘↑ and ⌃⌘↓ move a step. A click on a tick box ticks it. Each step has a right-click menu, also while you type, and the new Checklist menu has the same commands with the same names: Tick Step or Untick Step, Make Heading or Make Step, Move Step Up, Move Step Down, and Delete Step or Delete Heading. The menu shows only while the job can change.
- A checklist saves as you type through its own editor, `ChecklistEditor`. A step's text saves half a second after typing stops and when you leave the step, and a tick, a heading, a move or a removal saves at once. Each save makes the job's stored steps the ones on screen, in order, in one transaction. A step without text stays on screen while you type in it and is never saved. Each burst of typing and each other change is one Undo step, and Undo and Redo save again. Esc puts back the step's text from when the cursor came in. A failed save keeps the steps, says so and offers Try Again, and quitting saves first and asks when it can't.
- Progress counts the ticked steps out of all steps. Headings and steps without text do not count. The watch page's job rows and the Workshop rows show the same count.
- The task editor, the task detail page, the task drafts, the task-part links and their availability labels, task removal and the Task menu are gone. Only the part editor still saves with ⌘S and asks Save, Discard or Stay. Steps and parts are independent, and nothing creates or ticks a step for you.
- The UI tests lost the task tests and the task-part tests and have one checklist test. The recovery harness checks that every task of the retained libraries becomes a step in order with its tick and reasons, and that the task tables are gone. The performance fixture seeds 10,000 steps with headings.

## Executed checks

Development Mac: Apple silicon, macOS 27.3, Xcode 27.2. The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed explicitly. The Mac's region format is Denmark, and it runs in dark appearance.

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make check` | Passed lint, unsigned Debug, and 238 tests in 379 runs with no failures or skips, on the final code, commit `d9f91b4`. Result bundle `ure-20261105-150925.xcresult`. All test targets also compile, including the new checklist UI test |
| `make release` | Passed, unsigned optimized Release, on the final code. The Release `UrePerformanceHarness` also builds |
| `make recovery` | Passed all 58 recovery scenarios, including upgrades of the retained v10 and v15 libraries with every interruption checkpoint, on the first run. The persistence code has not changed since |
| Isolated running app | Passed. See below |
| Local window check | Passed. See below |

### Acceptance criteria

1. You can type a whole checklist without the mouse. `ChecklistEditorTests` types a checklist from the row that adds a step with Return, "# " for a heading, ⇧⌘U, ⌃⌘↑, Return in the middle, Return on an empty step and Backspace, and checks the order and what saved. It also checks the arrows, Backspace in the empty last row and on an empty heading. The window check typed one key at a time into the real fields and pressed Return and Backspace through the field editor.
2. Each change saves without a button, and ⌘Z undoes it. `ChecklistEditorTests` checks the save after the typing pause, one Undo per burst of typing, Esc, the trimmed text on leaving, and Undo and Redo of typing, a tick, a move, a heading and a deletion, each with its name, and that each saves again. `ChecklistServiceTests` saves through the library, including a Done job, and refuses an archived job and a step of another job. `WorkshopEditingTests` checks that leaving the job and quitting save the checklist without the draft question. The window check read "Undo Move Step", "Undo Tick Step" and "Redo Tick Step" in the real window and read the library after each.
3. Progress counts ticked steps and ignores headings. `ChecklistEditorTests`, `ChecklistServiceTests`, `WorkshopOverviewTests` and `ReleaseJourneyTests` check "1 of 3 done", "No steps yet" and a checklist of only a heading. The migration test checks "3 of 8 done" after the upgrade. The window check rendered "6 of 10 done" with its bar.
4. Every existing task appears as a step in the same order, under its group heading, and no typed detail or reason is lost. `ChecklistMigrationTests` upgrades an on-disk library made by the v23 schema with groups that change and come back, a task without a group between them, a label with spaces around it, all five statuses, details over two lines, blank details, waiting and skipped reasons, a task with both a detail and a reason, notes that already hold the heading, and links between tasks and parts. It checks every line, the IDs, positions and times, every job's notes text, that no job's updated time changes, that the parts stay and the task tables go, that a moved reason is found by search, and the integrity and foreign key checks. The W037 migration test now upgrades through v24 too and finds its skipped reason in the notes.
5. A backup made before this change restores. `ChecklistMigrationTests` stages and activates a backup package made by the v23 schema and checks every line and notes text. The older migration and restore tests upgrade through v24. The restore test for a task linked to a part of another job now builds an older backup, because only those have links.

The test that takes a current library back to an older schema, which every older migration test uses, now starts by taking the steps back to tasks. A test checks that it leaves exactly the v23 schema.

### Isolated running app

The Debug binary ran directly with `URE_TESTING=1` and a new `URE_TEST_LIBRARY_ID`. Its library is in the app container's `tmp/UreTests/<id>`, because the Debug build from the test runs is signed with the app sandbox. The library there was a v23 library written by the real migrator before the launch, seeded as "2 Job": three watches, a job with ten tasks in Disassembly, Cleaning and Assembly with all five statuses, details, waiting and skipped reasons and links to two parts, a waiting job with two tasks without groups, and a job without tasks. The app upgraded it to `v24-checklist-steps` in a new generation. Reading it showed thirteen lines for the first job with the three headings and six ticked steps, the second job's two steps, every detail and reason in the notes under "From the old record", no task tables, every updated time unchanged, and an integrity check that passed. The copy was quit by its PID, and no Debug copy is left running. The installed `/Applications/Ure.app` and the real library were not touched.

### Local window check

This Mac gives sessions no Screen Recording or Accessibility permission. As accepted for the Rework stories on 5 November 2026, a local-only test hosted the app's real `LibraryRootView`, with every session environment, in a window of the test host. It opened a library made by the v23 schema, seeded as above, and drove the real views. It was never committed and never runs on CI. It ran again on the final code and checked these things in order:

- The migrated library has the steps, headings and notes above.
- The job page with its checklist, as "2 Job", reads "6 of 10 done" with its bar, in light and dark appearance. The watch page's job row reads "6 of 10 done".
- Each line's AppKit cell has the text field role and sits in the window's accessibility tree. A ticked step has the label "Step, ticked" and its text as the value, an open step "Step, not ticked", a heading "Heading", and the last row "Add a step".
- The right-click menu of a ticked step reads "Untick Step (⇧⌘U), Make Heading, Move Step Up (⌃⌘↑), Move Step Down (⌃⌘↓), Delete Step". A heading's menu reads "Tick Step" turned off, "Make Step" and "Delete Heading". While you type, the step's commands come first, above the text commands.
- On a job without steps, typing "Clean all parts", Return, "# Assembly", Return, "Fit the new mainspring", Return and "Oil the escapement" makes a step, a heading and two steps, with the cursor moving to each new line. The line you type in has its accent fill and the key hints show.
- ⇧⌘U and ⌃⌘↑, run as the Checklist menu runs them, tick "Oil the escapement" and move it above "Fit the new mainspring", and the cursor stays in it. Return there makes an empty step, and Backspace removes it and puts the cursor back at the end of "Oil the escapement". The library then holds the four lines.
- Undo reads "Undo Move Step" and puts back the order, then "Undo Tick Step" and unticks it, and Redo makes both again. The library follows each.

The renders are in `~/Developer/test-assets/jorge-w039-checklist-7d4d54/window-check/`, with `check-log.txt` listing what each step read. `debug-binary-migrated-library.txt` in the same folder is the reading of the running app's upgraded library.

These are the limits of the substitution:

- The window ignores the mouse, because a real mouse over the test window crashed SwiftUI's hover hit test in W036. Clicks on tick boxes, the right-click menus and the menu bar were not driven. The menus were read from the fields, and ⇧⌘U and ⌃⌘↑ ran the Checklist menu's own command for the step with the cursor, because the test host has no key events.
- The test host turns off undo grouping by event, so the check groups each burst of typing and each menu command by hand. Return and Backspace register no Undo, so they run without a group.
- SwiftUI fills in its accessibility tree only when an accessibility client is attached, so the tick boxes and the checklist heading could not be read in the test host. VoiceOver itself did not run. The AppKit fields could be read.
- The offscreen render draws AppKit text fields darker than their colour, as described above, and leaves out the window's own background, so the check gives its root view the window background colour.

## Codex review

The review ran with `codex exec review --ignore-user-config`, which used Codex's default model, `gpt-6-astra`, and left `~/.codex/config.toml` unchanged. Each round read the whole diff against `2877fae`.

1. Round one reported no findings. Some small changes came after it started: a step's right-click menu now shows only while its job can change, the key caps have their lower edge, a focus request clears after the view update that sees it, and the performance worker checks the new counts.
2. Round two read the final code, commit `d9f91b4`, and reported no findings.

## Remaining gates

- Native UI tests were not run, as the repository rules require during story work. `JobUITests` has a new checklist test that types a checklist with the keyboard, ticks and moves a step, undoes and redoes, and reads the order after a restart. It compiles but has not run. W042 runs it.
- The performance measurement was not rerun. Only its fixture's checklist rows changed.
- W038 changes the Jobs list, the sidebar and job creation at the same time. Whichever of W038 and W039 merges second moves its migration after the other's.
