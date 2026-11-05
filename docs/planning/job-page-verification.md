# W037 job page verification

Recorded on 5 November 2026 for W037, [issue #65](https://github.com/jorgerodrigues/ure/issues/65), the fifth Rework story. The branch started at `ff6a2ee` on `w002-recoverable-library`, which includes W033 to W036.

## Design source

The session read the live Paper file Ure, page "Rework · Simple", token hash `b9b53808`. It read the "2 Job" artboard's header, Parts, Checklist, Material and Notes sections and the job card and the "What goes", "Nothing typed is lost" and "Decided" lists on "1 Model" with the JSX and computed-style tools, and compared them with the window check's renders. It also read "6 New job" for the problem field's prompt, "What's wrong with it?".

### Differences found and fixed

The page was built from the JSX values: an 88 pt cover with a 16 pt radius 20 pt from the text, the state pill 22 pt high with a 6 pt dot and the pop-up's arrows, "Opened 12 October · 23 days" in 12 pt 10 pt after it, the 26 pt bold title, the 13 pt line that links the watch and its caliber and names the owner, and the 15 pt problem on a 24 pt line at most 600 pt wide, 20 pt under the header. Sections are 40 pt apart, and the Parts and Checklist headings sit 4 pt above rows that are 8 pt apart.

1. The first renders drew the task and part rows grey, like disabled buttons, because the rows kept the borderless button look outside their old form. On "2 Job" the rows read in the label colour. The rows now use the plain button style that the watch page's job rows use.

### Differences left on purpose

- The cover is the watch's cover photo, or the job's first photo when the watch has none, or a watch symbol. The artboard's cover is an illustration.
- The Parts and Checklist sections keep their current rows, as the issue says, until W039 and W040. The artboard's part pills, prices, "1 to buy · €42.40 paid", the checklist's progress bar, headings and ticks, and the add rows at the end of each section come with those stories.
- The Checklist heading reads "6 of 10 done · 60%", with "· 1 skipped" when tasks are skipped, where the artboard reads "6 of 10 done". The specification keeps the percentage and the skipped count visible while tasks have statuses, until W039 makes steps.
- "2 Job" shows only an In progress job. The designs have no Waiting or Done variant, so the session chose these. A waiting job shows **Waiting for** as a fact under the header, written in place, and choosing Waiting puts the cursor there. A Done job's pill is grey with a tick, as on "4 Watch", and its line reads "Opened 12 October · Done 2 November". A job opened today reads "Opened today".
- The title's in-place box is 40 pt high, as on the watch and caliber pages, where the artboard's title line is 32 pt.
- The sidebar groups, the Jobs list and its counts in the toolbar come with W038. The Workshop list keeps its rows, grouped under In progress and Waiting.

## What changed

- Migration `v23-job-states` rebuilds the job table with three states. Planned, In progress and Ready become In progress, Waiting stays Waiting with its reason as what it waits for, and Completed and Cancelled become Done, with the time they closed as the done date. It writes the agreed scope, intake condition, outcome, recommendations, cancellation reason and the two unfinished reasons into the job's notes under "From the old record", one line each. A cancelled job reads "Cancelled: Owner declined the quote". Intake snapshot values are written only where the watch no longer holds them, such as "Serial at intake: 0012", and a snapshot of another version is written as it was saved. Reasons typed into the activity history that no record holds any more follow under "History", one dated line each, such as "15 October 2026 · Task · Fit the new mainspring · Waiting reason: Mainspring on order". Then the activity records go. No updated time changes. The database now checks that only a waiting job has a waiting text and only a done job has a done date.
- The job page is rebuilt from "2 Job". The title, the problem and the waiting text save as you type with Undo. The state is a pop-up that saves at once. Undo puts back the state before with its waiting text and done date, and Redo the state it was given, with the same done date. Start Job makes "New Job" with the cursor in the title and the title selected.
- A Done job stays editable, with its tasks, parts, material and notes. The closed-job guard is gone from jobs, tasks, parts, notes, material and task removal. Only an archived job can't change. A job of an archived watch can change its state. Starting a job still needs a watch that is not archived. A job leaves Done only while its watch has no other open job.
- The job editor, the action editor, the timeline, the closure summary and their drafts are gone, and so are the Record menu's job edit, stage and reopen items. Task and part saves no longer write history.
- W036's `ArchiveUndo` became `ChangeUndo<Value>`, which archiving and job states share.
- The recovery harness checks the state, problem, waiting text, done date and moved values of every job after an upgrade, and that the history table is gone. The performance fixture seeds the three states.

## Executed checks

Development Mac: Apple silicon, macOS 27.3, Xcode 27.2. The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed explicitly. The Mac's region format is Denmark, and it runs in dark appearance.

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build` | Passed, unsigned Debug |
| `make check` | Passed lint, unsigned Debug, and 256 tests in 426 runs with no failures or skips, on the final code. Result bundle `ure-20261105-141553.xcresult`. All test targets also compile, including the rewritten job UI tests |
| `make release` | Passed, unsigned optimized Release. The Release `UrePerformanceHarness` also builds |
| `make recovery` | Passed all 58 recovery scenarios on the second run, including upgrades of the retained v10 and v15 libraries with every interruption checkpoint. The first run stopped at `upgrade-v10-documents-afterSwitch`: the worker reached its checkpoint and wrote it, but exited with code 2 instead of being killed by its own `SIGKILL`, so the harness saw no interruption. That is the worker's `kill` racing its next line, not the upgrade. The rerun of the same build passed every scenario |
| Isolated running app | Passed. See below |
| Local window check | Passed on the final code. See below |

### Acceptance criteria

1. Every existing job shows the right new state after migration, and no typed value is lost. `JobMigrationTests` upgrades an on-disk library made by the v22 schema with a job in each of the six old stages, every removed job field, notes that already hold the heading, an intake snapshot with values the watch no longer holds, a snapshot of another version, and activity records whose reasons the records no longer hold. It checks each state, waiting text, done date, problem and notes text, that updated times do not change, that the tasks, parts and triggers stay, and that the history table is gone. Unit tests cover the removed-value lines, the intake comparison and the history rules, including a reason a record still holds, a removed task, a condition note and a value it can't read. The running app and the window check upgraded a v22 library the same way. The recovery matrix checks every job of the retained libraries.
2. Changing the state saves, records the date, and ⌘Z undoes it. `JobTransitionTests` changes every state to every state and checks the done date, the waiting text and the opened date, restores a state with its done date and waiting text, and refuses to move a Done job back while its watch has another open job. `JobStateTests` sets Done, checks "Undo Change State", Undo, "Redo Change State" and Redo with the same done date, puts back a waiting text with its state, and undoes a state and the waiting text before it in one go. The window check did the same in the real window.
3. A Done job can still be edited, with its tasks and parts. `JobServiceTests` sets a job Done and then changes its title and problem, ticks, adds, moves and removes tasks, orders a part, writes notes and adds a link. Task, part, procurement, ordering, task-link, notes, material and search tests check Done jobs the same way, and that only an archived job refuses changes. The window check edited the title of a Done job and found its tasks, parts and notes writable.
4. The title, problem and waiting text save in place without a button. `JobStateTests` types each one, checks the library after the pause, and keeps the last good title when the title is blank. `WorkshopEditingTests` checks that leaving the page and quitting save them without the draft question. The window check typed into the real fields.
5. A backup made before this change restores. `JobMigrationTests` stages and activates a backup package made by the v22 schema and checks every state and notes text. The older migration and restore tests in `RecordNotesTests`, `MaterialMigrationTests`, `CaliberMigrationTests` and `WatchMigrationTests` now upgrade through v23 too.

### Isolated running app

The Debug binary ran directly with `URE_TESTING=1` and a new `URE_TEST_LIBRARY_ID`. The Debug build from the test runs is signed with the app sandbox, so its library is in the app container's `tmp/UreTests/<id>`. Its first launch made an empty library there. It was quit, that library was replaced by a v22 library written by the real migrator, and it was launched again. The seed had five watches, a job in each of the six old stages with every removed job field, a cancelled job with its reason, ten tasks, a part, a link, and eight activity records with typed reasons. The app upgraded the library to `v23-job-states` in a new generation and kept a v22 recovery copy. Reading it showed Planned, In progress and Ready jobs In progress, the waiting job Waiting with "A crystal from Cousins", the completed and cancelled jobs Done on the days they closed, every removed value and history reason in the notes, no `activityEvent` table, every updated time unchanged, and an integrity and foreign key check that passed. The copy was quit by its PID each time, and no Debug copy is left running. The installed `/Applications/Ure.app` and the real library were not touched.

### Local window check

This Mac gives sessions no Screen Recording or Accessibility permission, so there is no screenshot of the running app's own window. As accepted for the Rework stories on 5 November 2026, a local-only test hosted the app's real `LibraryRootView`, with every session environment, in a window of the test host. It opened a library made by the v22 schema and drove the real views. It was never committed and never runs on CI. It ran again on the final code and checked these things in order:

- The migrated library has the states and notes above.
- The job page In progress, as "2 Job", in light and dark appearance, with "Opened 12 October · 24 days" and "Ana Ribeiro, +351 912 480 117".
- The title field's cell has the text field role, the label "Title" and its value, and sits in the window's accessibility tree. The problem's text view has the text area role, the label "Problem" and its text.
- Typing in the problem saves after the pause, and the menu reads "Undo Problem".
- Waiting puts the cursor in **Waiting for**, whose cell has the label "Waiting for". Typing there saves after the pause.
- Done records today and clears the waiting text, and the menu reads "Undo Change State". Undo puts back Waiting with its text and no done date, and the menu then reads "Redo Change State". Redo makes it Done again on the same date.
- A Done job's title is editable and saves, and its tasks, parts and notes can change.
- Each migrated job renders: Planned, Waiting, Ready, Completed and Cancelled.
- Start Job makes "New Job" with the cursor in its title and the whole title selected. Typing replaces it and Return saves it.
- The Workshop list groups open jobs under In progress and Waiting.

The renders of the final code are in `~/Developer/test-assets/jorge-vigorous-khayyam-2e1a38/window-check/`, with `check-log.txt` listing what each step read. `debug-binary-migrated-library.txt` in the same folder is the reading of the running app's upgraded library.

These are the limits of the substitution:

- The window ignores the mouse, because a real mouse over the test window crashed SwiftUI's hover hit test in W036. Clicks, hover, the pop-up's menu and the links to the watch and caliber were not driven. A state change was the call that the pop-up's choice makes, with the window's undo manager.
- The test host turns off undo grouping by event, so each simulated key press and state change opens and closes its own group. A state change registers its Undo after it saves, so the check keeps the group open across it.
- SwiftUI fills in its accessibility tree only when an accessibility client is attached, so the state pop-up, the links and the checklist heading could not be read in the test host. VoiceOver itself did not run. The AppKit fields could be read.
- The offscreen render leaves out the window's own background, so the check gives its root view the window background colour. The selected sidebar row's label is blank, as in W033 to W036.

## Codex review

The review ran with `codex exec review --ignore-user-config`, which used Codex's default model, `gpt-6-astra`, and left `~/.codex/config.toml` unchanged. Each round read the whole diff against `ff6a2ee`.

1. Round one found two things, and both were fixed. Two quick Undo steps, of a state change and then of the waiting text before it, could run out of order: the state's restore saved the text first while the job was still Done, failed, and then blocked every later state change. Typing on the job now saves before a state change joins the queue, and a waiting text saves only after state changes still saving, while the job still waits. A new state test undoes and redoes both in one go. Round one also found that the part UI test still expected a Done job's part to be read-only.
2. Round two found that the Checklist heading no longer showed the task percentage and the skipped count, which the specification keeps visible. The heading now reads "6 of 10 done · 60%", with the skipped count when there is one, and the wording has unit tests.
3. Round three read the final code, commit `f0b9103`, and reported no findings.

## Remaining gates

- Native UI tests were not run, as the repository rules require during story work. `JobUITests` was rewritten for the job page you write on, and the job steps of the other UI tests were updated. They compile but have not run. W042 runs them. Some UI tests still hold steps from before the Rework, such as note records, that earlier stories left for W042.
- The performance measurement was not rerun. Only its fixture's job rows changed.
