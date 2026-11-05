# W035 caliber in place verification

Recorded on 5 November 2026 for W035, [issue #63](https://github.com/jorgerodrigues/ure/issues/63), the third Rework story. The branch started at `6bf50f4` on `w002-recoverable-library`, which includes W033 and W034.

## Design source

The Paper app was not connected during this story. Its connection was refused, so the session could not read the "5 Caliber" and "7 Typing" artboards on the "Rework · Simple" page with the JSX and computed-style tools. The page and the field follow the issue's description of the design and the values W033 read from "7 Typing": 15 pt typed text on a 24 pt line, the 11 pt hint "Saved as you type · Esc undoes this field", and a 12 pt red error with a filled exclamation mark. The six states, the 120 pt label column, the hover fill and the focus ring are this story's choice. They use semantic colours and system fonts, so a later story can match the artboards' exact values without changing behaviour.

The page keeps the grouped form that the watch and job pages still use. The order follows the issue: header, facts, the watches that use the caliber, material and notes. The header shows the maker and name, such as "Omega 552", and "Edited" with the date. Archiving stays where it was, because W036 changes it.

## What changed

- Migration `v21-caliber-facts` adds a `winding` column that takes Manual, Automatic or Quartz. It keeps those three, and makes Unknown and Other empty. Before it drops the variant, the movement type, the specification notes and the source note, it writes their values into the caliber's notes under "From the old record", one line each, such as "Variant: A/2" and "Movement type: Other". When the notes already have that heading, from W034's material values, the lines go under it. The migration does not change any caliber's updated time. Search still finds an old variant, because it is now in the notes.
- `FactField`, next to W033's `AutosaveField`, is the in-place fact field that the watch, job and part pages can reuse. `FactRow` and `InPlaceField` show it, and `InPlaceTextView` is its one-line AppKit field. `NumberEntry` reads and shows numbers. `AutosaveField` no longer saves a text it does not accept, so a number it cannot read stays on screen and the record keeps its last good value. A blank material title now behaves the same way, and quitting puts the old title back first, as leaving the title already did.
- The caliber page shows its seven facts in place. Each saves on its own through `CaliberService.update`, so two facts never overwrite each other, and a value that is already saved changes nothing. ⌘N makes "New Caliber", selects it, and puts the cursor in its name with the name selected.
- The caliber editor sheet, `CaliberDraft`, and the caliber parts of the Save, Discard and Stay guard are gone. Caliber facts count as fields that save as you type, so leaving asks nothing, quitting waits for them, and restore waits until they have saved.
- Watch pages show the new facts. Search, the archive list and the watch's caliber picker name a caliber by its maker and name. New job intake snapshots have no caliber variant. Older snapshots keep theirs.
- The recovery harness checks that every winding and every removed caliber value survives an upgrade. The performance fixture no longer writes a movement type.

## Executed checks

Development Mac: Apple silicon, macOS 27.3, Xcode 27.2. The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed explicitly. The Mac's region format is Denmark, so its numbers use a decimal comma and a dot between thousands.

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build` | Passed, unsigned Debug |
| `make check` | Passed lint, unsigned Debug, and 265 tests in 481 runs with no failures or skips, on the final source. Result bundle `ure-20261105-110649.xcresult` |
| `make release` | Passed, unsigned optimized Release. The Release `UrePerformanceHarness` also builds |
| `make recovery` | Passed all 58 recovery scenarios, including upgrades of the retained v10 and v15 libraries with every interruption checkpoint |
| Isolated running app | Passed. See below |
| Local window check | Passed. See below |

### Acceptance criteria

1. Every caliber fact can be changed on the page, and each change saves without a button. `CaliberStateTests` types every fact, including "auto" for the winding, "24 jewels" and "50h", and reads each saved value back. `CaliberServiceTests` saves each fact on its own. The window check typed into the real fields and read the library after the pause.
2. An invalid number shows as not valid when you leave the field. Your text stays, and the saved value does not change. `FactFieldTests` and `CaliberStateTests` cover it, including that the message waits until you leave, stays while you correct it, and that a change saved elsewhere does not replace your text. The window check typed "fast" into the beat rate and rendered the result.
3. ⌘Z undoes a fact change after it saved. `FactFieldTests` and `CaliberStateTests` undo and redo through an undo manager and check the saved value. Undo never brings back a value that is not valid. The window check used the window's undo manager, whose menu title is "Undo Beat Rate".
4. ⌘N makes a caliber with the cursor in its name. `CaliberStateTests` covers the state, and the window check ran the same call that the menu command makes and found the name field focused with "New Caliber" selected.
5. Values from removed fields appear in the caliber's notes, and a backup made before this change restores. `CaliberMigrationTests` upgrades an on-disk library made by the v20 schema, with every movement type, every removed field, blank values, multi-line notes, and notes that already have the heading. It also stages and activates a backup package made by the v20 schema. The recovery matrix and the running app cover older libraries.
6. VoiceOver reads each field's label and value. The window check read the accessibility element of each fact: its role is a text field, its label is the fact's name, its value is the shown text, and it sits in the window's accessibility tree. See the limits below.

Number parsing is tested in the Portugal and United States region formats in `NumberEntryTests`, with grouping by spaces, the region's mark and the other of "." and ",", units, values below the minimum, and showing numbers in each format. A round trip also runs in the Swiss, Egyptian Arabic, Persian and Hindi formats, which use their own digits or Indian grouping.

### Isolated running app

The Debug binary ran directly with `URE_TESTING=1` and a new `URE_TEST_LIBRARY_ID`. Its library was seeded at schema v15 from the retained fixture, with six more calibers: an Omega 552 that is Automatic with specification notes and a source note, a Unitas 6498 that is Manual with a variant, an ETA 2824-2 that is Unknown with a variant, a Ronda 715 that is Quartz with a source note, a Bulova 214 that is Other with two lines of specification notes and a source note, and a caliber with only a name and a blank variant. A watch used the 552. The app upgraded the library to `v21-caliber-facts`. Reading the new generation showed Manual, Automatic and Quartz kept as the winding, Unknown and Other empty, every removed value in the caliber's notes under one heading, and every updated time unchanged. The retained fixture's caliber already had a W034 material value in its notes, and its heading was not repeated. The copy was quit by its PID. The installed `/Applications/Ure.app` and the real library were not touched.

### Local window check

This Mac gives sessions no Screen Recording or Accessibility permission, so there is no screenshot of the running app's own window. As accepted for the Rework stories on 5 November 2026, a local-only test hosted the app's real `LibraryRootView`, with every session environment, in a window of the test host. It opened a library made by the v20 schema and drove the real views. It was never committed and never runs on CI. It checked these things in order:

- The migrated caliber page shows the facts in the region format and the removed values in the notes.
- Each fact's accessibility element has the text field role, its label and its value.
- Tab moves from the name to the maker, Return moves on to the winding, and Shift-Tab moves back.
- An empty winding shows its prompt. Typing "Au" shows "tomatic" in grey after it, and Tab takes "Automatic" and saves it.
- Typing "26 jewels" saves after the pause. Typing "21600vph" and leaving saves and shows the number in the region format. Undo and Redo change the saved beat rate.
- "fast" shows as not valid yet when focus leaves. The text stays, the saved beat rate does not change, and restore waits. Undo puts the last good value back.
- Leaving the caliber asks nothing and saves the power reserve being typed.
- Archiving while a fact is being typed makes the facts read-only first, saves the typing, and then archives.
- ⌘N's call makes "New Caliber" with its name focused and selected. Typing replaces it, and Return moves to the maker, which suggests "Omega".
- Saving everything before quitting saves a maker still being typed.

The check found two real problems, both fixed before review. SwiftUI reused a fact's AppKit field when you switched to another caliber, and the field kept typing into the first caliber's fact. The field now follows the current fact, and each caliber's rows are rebuilt. VoiceOver reads the field's cell, which had no label, so the label is now on the cell too. The renders also showed the prompts nearly as dark as values, so they now use the same tertiary grey as the notes prompt.

The renders in `~/Developer/test-assets/jorge-w035-caliber-534e84/window-check/` show the caliber page in light and dark, the new caliber, the archived caliber, and five of the six field states side by side in `00-six-states.png`: at rest, empty with a prompt, focused, suggesting, and not valid yet. `voiceover-labels.txt` lists what each fact's element reports.

These are the limits of the substitution:

- The hover state is not in a render. The test host has no mouse, and SwiftUI's hover tracking ignored the mouse-move events the check sent, so `03-state-hover.png` shows the field at rest. The hover fill is one line of view code.
- Key presses were sent to the field editor as commands, not as key events, and ⌘N was the same state call that the menu command makes. The real keyboard, menu and mouse were not driven.
- VoiceOver itself did not run. The check read the accessibility elements that VoiceOver reads. SwiftUI fills in its accessibility children from the top only when an accessibility client is attached, so the check walked up from each field to the window instead of down.
- The selected sidebar row's label is blank in offscreen renders, as in W033 and W034.

## Codex review

The review ran with `codex exec review --ignore-user-config`, which used Codex's default model, `gpt-6-astra`, and left `~/.codex/config.toml` unchanged. Each round read the whole diff and the new files. Every finding was real and was fixed, with a test where the behaviour can be tested:

1. Round one found two. In a region that shows numbers in its own digits, such as Arabic, a field could not read back the number it showed, so the value could not be edited and Undo refused it. The parser now takes decimal digits in any script, and the new round-trip test also showed that Indian grouping such as "12,34,567" was refused, so it is taken now too. Archiving also went ahead when a fact had not saved, which locked a text that was not valid yet in a read-only field. Archiving now stops and says to correct or undo the fact first.
2. Round two found that Undo kept a suggestion made for the text it took away, so Tab could then save "Automatic" over the undone value. A suggestion now holds only for the text it was made for.
3. Round three found that the facts stayed editable while an archive waited on the database, so a change typed then was locked in a read-only field. The facts are read-only while the caliber saves, and an edit in progress ends and saves first.
4. Round four read the whole branch and reported no findings.

## Remaining gates

- The Paper artboards' exact values were not read, because the Paper app was not connected. A later Rework story can match them.
- Native UI tests were not run, as the repository rules require during story work. `CaliberUITests` and the caliber part of `WorkshopUITests` were rewritten for the page you write on and compile, but have not run. W042 runs them.
- The performance measurement was not rerun. Only its fixture changed.
