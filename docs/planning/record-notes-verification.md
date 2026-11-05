# W033 record notes verification

Recorded on 4 November 2026 for W033, [issue #61](https://github.com/jorgerodrigues/ure/issues/61), the first Rework story. The branch started at `0d7fda2` on `w002-recoverable-library`. W033 has no dependencies.

## Design source

Read the live Paper file Ure, page "Rework · Simple". The token hash was `b9b53808`. The issue names the artboards "1 Model" and "7 Typing". The notes values come from the JSX of the Notes section on the "4 Watch" and "2 Job" artboards and the "Typing" field on "7 Typing".

- Notes text is 15 pt with a 24 pt line height and a 600 pt maximum width, so a line stops at about 75 characters.
- The hint under a field you are typing in is 11 pt secondary text: "Saved as you type · Esc undoes this field".
- A field error is 12 pt red text with a filled exclamation mark.

The editor keeps the current grouped form and its standard "Notes" section header. The new page layouts, including the 17 pt section heading and the "Edited" date, come in later Rework stories. The design shows a 12 pt gap between paragraphs. The editor uses no paragraph spacing, so measurement lists in old notes stay compact. Old notes are separated by a blank line instead.

## What changed

- Migration `v19-record-notes` adds a `notes` text to watch, caliber and job. It joins each record's note records into it, oldest first by occurred date and then created time. Each old note starts with "date · kind · title" on its own line, followed by its body. A blank line separates old notes. Then the note table goes. The migration does not change any record's updated time.
- Migrations v17 and v18 now pass their own search fields, so a later schema change cannot break an old library's upgrade.
- `AutosaveField` is the shared autosave base in the feature state layer. A change saves half a second after typing stops, at once when focus leaves, and when the app saves everything before quitting. Each burst of typing is one Undo step. Undo and Redo save again. Esc puts back the text from when focus entered the field.
- `RecordNotesState` keeps one field per record. `NotesTextView` is a plain-text AppKit editor. It leaves Undo to the field and puts ⌘D's date at the cursor. Edit offers "Insert Today's Date" with ⌘D while notes are focused.
- Leaving a record saves its pending notes without the Save, Discard or Stay question. Quitting waits for pending notes to save. If a save fails, the app asks before it quits. Restore waits until notes have saved.
- Search finds words in the notes text and opens the record. The note search kind, note removal, note timeline entries and the Notes feature code are gone.
- The recovery and performance harnesses now expect the joined notes instead of the note table.

## Executed checks

Development Mac: Apple silicon, macOS 27.2 (`26B123`), Xcode 27.2 (`27B52`). The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed explicitly.

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build` | Passed, unsigned Debug |
| `make check` | Passed lint, unsigned Debug, and 506 unit test runs with no failures or skips. Result bundle `ure-20261104-182447.xcresult` |
| `make release` | Passed, unsigned optimized Release |
| `make recovery` | Passed all 58 recovery scenarios. These include upgrades of the retained v10 and v15 libraries, which hold a note, with every interruption checkpoint, and restores of a retained v10 backup |
| `UrePerformanceHarness` Debug build | Passed. The performance measurement itself was not run |
| Isolated running app | Passed. See below |
| Local window check | Passed. See below |

### Acceptance criteria

1. Every note in an existing library appears in its record's notes text, oldest first, with its date, kind and title. `RecordNotesMigrationTests` upgrades a real on-disk library made by the v18 schema. It has notes of all four kinds on a watch, an open job, a closed job and a caliber, with an empty body, a long body and two notes with the same date. `ReleaseJourneyTests` checks the retained v10 and v15 fixtures.
2. Typing saves without a Save button, and quitting while typing loses no text. `AutosaveFieldTests` covers the half-second pause and the save when focus leaves. `RecordNotesStateTests` covers saving everything before quitting and saving when navigating away. The window check typed into the real editor and read the saved text back after the pause.
3. ⌘Z undoes a notes change after it saved, and ⇧⌘Z redoes it. `AutosaveFieldTests` and the window check, through the window's undo manager. Its Undo menu title is "Undo Notes".
4. A failed save keeps the text on screen and says that it did not save. `AutosaveFieldTests`, `RecordNotesStateTests` and the window check, which archived the caliber while its notes were waiting to save.
5. A backup made before this change restores, and its notes appear in the notes texts. `RecordNotesMigrationTests` stages and activates a backup package made by the v18 schema. The recovery matrix restores a retained v10 backup.
6. Search finds a word that was only in an old note. `RecordNotesMigrationTests` and the window check.

### Isolated running app

The Debug binary ran directly with `URE_TESTING=1` and a new `URE_TEST_LIBRARY_ID`. Its library was seeded at schema v15 from the retained fixture, with six more realistic notes on a watch, a job and a caliber. The app upgraded it to `v19-record-notes`. Reading the new generation showed every old note in its record's notes, oldest first, with its date, kind and title. The copy was quit by its PID. The installed `/Applications/Ure.app` and the real library were not touched.

This Mac does not let the session capture or drive another app's window. `screencapture -l` returned "could not create image from window", because Screen Recording is not granted. AppleScript returned "osascript is not allowed assistive access", because Accessibility is not granted. Automation Mode is disabled and needs the user's password. So there is no screenshot of the running app's own window.

### Local window check

A local-only test hosted the app's real `LibraryRootView`, with every session environment, in a window of the test host. It opened a Paper-like library made by the v18 schema and drove the real `NotesTextView`. It was never committed and never runs on CI. It checked these things in order:

- The watch, job and caliber pages show the migrated notes.
- Typing saves after the pause, ⌘D types today's date, and Undo and Redo change the saved text.
- Esc puts back the notes from when focus entered them, and leaving the field saves at once.
- Saving everything before quitting saves the text still being typed, and restore is blocked until then.
- A failed save shows the red message and Try Again, and keeps the text until the caliber is unarchived.
- Search finds the watch by "J.R. 1958", which was only in an old note.

The renders in `~/Developer/test-assets/jorge-w033-notes-94d20e/` show the watch, job and caliber notes in light and dark, the failed save, and the search result. The text matches the Paper notes block: 15 pt, 24 pt lines, and the first line breaks at the same word as the "4 Watch" artboard. Offscreen rendering leaves the selected sidebar row's label blank. That is a capture limit, not a change in this story. The typing hint sits below the visible part of the long watch page, so it is not in a render. The check confirmed that the field reports editing while focused, which is what shows the hint.

## Accepted app check

On 5 November 2026 the user accepted the local window check as the W033 app check, in place of a screenshot of and keyboard input to the running app's own window. Those need Screen Recording and Accessibility for the session, or Automation Mode.

## Remaining gates

- The Codex review could not run. The model in `~/.codex/config.toml`, `gpt-6.1-sol`, is not supported for this ChatGPT account.
- The performance measurement was not rerun. Only its fixture and expected results changed.
- Native UI tests were not run, as the repository rules require during story work.
