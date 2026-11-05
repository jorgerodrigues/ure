# W035 caliber in place verification

Recorded on 5 November 2026 for W035, [issue #63](https://github.com/jorgerodrigues/ure/issues/63), the third Rework story. The branch started at `6bf50f4` on `w002-recoverable-library`, which includes W033 and W034.

## Design source

The Paper app was not connected when the first build of this story was made. It was connected before the merge, so the session read the live Paper file Ure, page "Rework · Simple", token hash `b9b53808`. It read the "5 Caliber" and "7 Typing" artboards and the caliber card on "1 Model" with the JSX tool, and compared them with the window check's renders.

### Differences found and fixed

The first build kept the grouped form and put each label in a column to the left of its value. The artboards differ in these ways, and all of them are now fixed:

1. A fact's 11 pt medium label sits above its value, indented 8 pt to line up with the text in the 32 pt box. The first build had a 120 pt label column and 13 pt labels.
2. The box has an 8 pt radius and 8 pt padding. Typing turns the label to the accent colour and shows a 1 pt accent outline with a 4 pt accent ring at 18%. The first build used a 3 pt keyboard-focus ring and left the label grey.
3. Not valid yet turns the label red with a 1 pt red outline, and the message is short, such as "Enter a beat rate above 0 vph." The first build prefixed "Not valid yet." and added "The saved value stays …", which the artboard does not show.
4. Suggesting shows a list of the library's matches under the field, with a count, and the first row in the accent colour. The first build showed only the grey completion and a hint.
5. Winding is a pop-up with an up-and-down chevron. The first build typed it with a suggestion.
6. At rest, a unit such as "vph" or "h" reads in the secondary colour.
7. The page is a document, not a grouped form: 40 pt top, 56 pt sides and 40 pt between sections. The header has a 104 pt photo tile with an 18 pt radius, the maker and name as the 26 pt bold title, and "In 1 watch" in 15 pt secondary. The name in the title is the field you type in, and ⌘N puts the cursor there.
8. The six facts sit in three columns under a hairline: maker, winding and beat rate, then jewels, power reserve and lift angle.
9. Watches, Material and Notes have 17 pt bold headings with a 13 pt count or date on the right, such as "1 watch", "2 PDFs · 1 photo · 1 link" and "Edited 21 September". Watch rows are 52 pt with a thumbnail, the brand and year, the open job, and a chevron.
10. The list shows each caliber's maker and name, such as "Omega 552", and "Automatic · 1 watch", in order of maker and name. The toolbar's subtitle counts the calibers.
11. The archive button is gone from an active caliber's page, as on the artboard. The Record menu still archives it, and an archived caliber's page shows Unarchive.

### Differences left for later stories

- The Material tiles, the drop strip's wording and the photo viewer belong to W034's Material section, which the watch and job pages also use. The artboard's tiles fill four columns at 116 pt and the strip reads "Add photos, PDFs or links, or drop them here". The section keeps W034's tiles.
- The list's thumbnails and the sidebar's Workshop and Library groups come with W038, which groups the sidebar.
- The header tile shows the caliber's first photo. With no photo it shows a gear, because the artboard's illustration is sample content.

## What changed

- Migration `v21-caliber-facts` adds a `winding` column that takes Manual, Automatic or Quartz. It keeps those three, and makes Unknown and Other empty. Before it drops the variant, the movement type, the specification notes and the source note, it writes their values into the caliber's notes under "From the old record", one line each, such as "Variant: A/2" and "Movement type: Other". When the notes already have that heading, from W034's material values, the lines go under it. The migration does not change any caliber's updated time. Search still finds an old variant, because it is now in the notes.
- `FactField`, next to W033's `AutosaveField`, is the in-place fact field that the watch, job and part pages can reuse. `FactRow` and `InPlaceField` show it, and `InPlaceTextView` is its one-line AppKit field. `NumberEntry` reads and shows numbers. `AutosaveField` no longer saves a text it does not accept, so a number it cannot read stays on screen and the record keeps its last good value. A blank material title now behaves the same way, and quitting puts the old title back first, as leaving the title already did.
- The caliber page is rebuilt from the "5 Caliber" artboard. The name is the title, and the other six facts sit in three columns. Each saves on its own through `CaliberService.update`, so two facts never overwrite each other, and a value that is already saved changes nothing. ⌘N makes "New Caliber", selects it, and puts the cursor in its name with the name selected. Winding is a `FactPopUp`. As you type a maker, the library's makers show under the field. `PageSectionHeading` and the page style of the Material and Notes sections give a page its headings.
- The caliber editor sheet, `CaliberDraft`, and the caliber parts of the Save, Discard and Stay guard are gone. Caliber facts count as fields that save as you type, so leaving asks nothing, quitting waits for them, and restore waits until they have saved.
- Watch pages show the new facts. Search, the archive list and the watch's caliber picker name a caliber by its maker and name. New job intake snapshots have no caliber variant. Older snapshots keep theirs.
- The recovery harness checks that every winding and every removed caliber value survives an upgrade. The performance fixture no longer writes a movement type.

## Executed checks

Development Mac: Apple silicon, macOS 27.3, Xcode 27.2. The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed explicitly. The Mac's region format is Denmark, so its numbers use a decimal comma and a dot between thousands.

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build` | Passed, unsigned Debug |
| `make check` | Passed lint, unsigned Debug, and 266 tests in 482 runs with no failures or skips, on the final source. Result bundle `ure-20261105-113342.xcresult`. All test targets also compile, including the caliber UI tests |
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
- Tab moves from the name in the title to the maker, Return moves on to the beat rate past the winding pop-up, and Shift-Tab moves back.
- The 2824-2's winding pop-up is empty and shows its prompt. Choosing Automatic, through the call the menu item makes, saves it, and Undo and Redo change it back and forth.
- Typing "26 jewels" saves after the pause. Typing "21600vph" and leaving saves and shows the number in the region format. Undo and Redo change the saved beat rate.
- "fast" shows as not valid yet when focus leaves. The text stays, the saved beat rate does not change, and restore waits. Undo puts the last good value back.
- Leaving the caliber asks nothing and saves the power reserve being typed.
- Archiving while a fact is being typed makes the facts read-only first, saves the typing, and then archives.
- ⌘N's call makes "New Caliber" with its name focused and selected in the title. Typing replaces it, and Return moves to the maker.
- The new caliber's empty maker shows its prompt. Typing "Om" lists "Omega · 1 caliber" under the field with "ega" in grey, and Tab takes it and saves it.
- Saving everything before quitting saves a beat rate still being typed.

The first version of the check found two real problems, both fixed before review. SwiftUI reused a fact's AppKit field when you switched to another caliber, and the field kept typing into the first caliber's fact. The field now follows the current fact, and each caliber's rows are rebuilt. VoiceOver reads the field's cell, which had no label, so the label is now on the cell too. The renders also showed the prompts nearly as dark as values, so they now use the same tertiary grey as the notes prompt.

The renders of the final build are in `~/Developer/test-assets/jorge-w035-caliber-534e84/window-check-paper/`. They show the caliber page in light and dark, the 2824-2, the new caliber with its name focused and filled, the archived caliber, and five of the six field states side by side in `00-six-states.png`: at rest, empty with a prompt, focused, suggesting with the list, and not valid yet, with the empty winding pop-up. They match the artboards' layout, sizes, colours and text, apart from the differences left for later stories above. `voiceover-labels.txt` lists what each typed fact's element reports. The renders of the first build, before the comparison, are in `window-check/` next to it.

These are the limits of the substitution:

- The hover state is not in a render. The test host has no mouse, and SwiftUI's hover tracking ignored the mouse-move events the check sent, so `03-state-hover.png` shows the field at rest. The hover fill is one line of view code.
- Key presses were sent to the field editor as commands, not as key events, and ⌘N was the same state call that the menu command makes. The real keyboard, menu and mouse were not driven.
- VoiceOver itself did not run. The check read the accessibility elements that VoiceOver reads. SwiftUI fills in its accessibility children from the top only when an accessibility client is attached, so the check walked up from each field to the window instead of down. The winding pop-up is a SwiftUI menu with the label "Winding" and the winding as its value, and the check could not reach its element.
- The offscreen render leaves out the window's own background, so the check gives its root view the window background colour. Without it, a dark page rendered as white text on nothing.
- The selected sidebar row's label is blank in offscreen renders, as in W033 and W034.

## Codex review

The review ran with `codex exec review --ignore-user-config`, which used Codex's default model, `gpt-6-astra`, and left `~/.codex/config.toml` unchanged. Each round read the whole diff and the new files. Every finding was real and was fixed, with a test where the behaviour can be tested:

1. Round one found two. In a region that shows numbers in its own digits, such as Arabic, a field could not read back the number it showed, so the value could not be edited and Undo refused it. The parser now takes decimal digits in any script, and the new round-trip test also showed that Indian grouping such as "12,34,567" was refused, so it is taken now too. Archiving also went ahead when a fact had not saved, which locked a text that was not valid yet in a read-only field. Archiving now stops and says to correct or undo the fact first.
2. Round two found that Undo kept a suggestion made for the text it took away, so Tab could then save "Automatic" over the undone value. A suggestion now holds only for the text it was made for.
3. Round three found that the facts stayed editable while an archive waited on the database, so a change typed then was locked in a read-only field. The facts are read-only while the caliber saves, and an edit in progress ends and saves first.
4. Round four read the whole branch and reported no findings.
5. After the Paper comparison changed the field and the page, the coordinating session asked for one more round with the same command. Round five read the whole branch, including the rebuilt page, and reported no findings.

## Remaining gates

- Native UI tests were not run, as the repository rules require during story work. `CaliberUITests` and the caliber part of `WorkshopUITests` were rewritten for the page you write on and compile, but have not run. W042 runs them.
- The performance measurement was not rerun. Only its fixture changed.
