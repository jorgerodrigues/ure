# W034 material verification

Recorded on 5 November 2026 for W034, [issue #62](https://github.com/jorgerodrigues/ure/issues/62), the second Rework story. The branch started at `d95938c` on `w002-recoverable-library`, which includes W033.

## Design source

The Paper app was not connected during this story. Its connection was refused, so the session could not read the "2 Job", "4 Watch" and "5 Caliber" artboards on the "Rework · Simple" page with the JSX and computed-style tools. The Material section follows the issue's description of the design: tiles with a title and a line such as "Photo · 12 Oct", a drop strip that you can also click, pasting a URL to add a link, and caliber material as chips such as "From Omega 552:". Tile size, spacing and the strip's wording are this story's choice. They use semantic colours and system fonts, so a later story can match the artboards' exact values without changing behaviour.

The section keeps the current grouped form, like W033's notes. The new page layouts come in later Rework stories.

## What changed

- Migration `v20-material` keeps every photo, PDF and link as material on the same record. Material keeps its kind, title, file or URL, and dates. Before it drops the photo stage, caption, PDF source URL, source description and item notes, it writes their values into the owner's notes under "From the old record". Each item starts with its kind and title, such as "Photo · Dial at intake", followed by one line per value, such as "Stage: Before". An Unclassified stage was the default, so it is not written. The existing notes keep every character. The migration does not change any record's updated time, and the watch cover stays.
- The Material section replaces the photo, document and reference sections on the watch, job and caliber pages. Tiles show the material in the order it was added, and a photo tile shows its thumbnail. The strip accepts dropped files and links. A click on it opens the file picker and gives it focus, so ⌘V then pastes a link. Its shortcut menu also has Paste Link.
- A tile's title is a one-line field that saves with the W033 `AutosaveField`. Undo goes through the field, not the text field's own Undo. A blank title puts back the old one when you leave it. `AutosaveField` now takes an optional rule for the texts it accepts, so Undo never offers back a blank title. Notes accept any text, as before.
- Opening a photo or PDF tile uses the existing photo viewer or PDF reader. Opening a link tile opens the default browser.
- Watch and job pages show their caliber's material as chips. The chips open the caliber material in place. Removing and renaming happen only on the caliber page.
- Removing material is immediate and can be undone and redone. The removal keeps the original's file record and marks it in a new `removedFileAsset` table. When the library next opens, marked file records that no material uses are deleted, and startup recovery removes their originals. Undo puts back a cover that the removal cleared. Unmarked file records, such as W009's bare imports, are kept as before.
- The photo, document and reference states, services, drafts, editors, detail views and sections are gone, with their tests. The bench reference pane keeps working with material.
- The recovery and performance harnesses use the material service and the new columns. The recovery driver checks that each removed value appears in its owner's notes.

## Executed checks

Development Mac: Apple silicon, macOS 27.2, Xcode 27.2. The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed explicitly.

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build` | Passed, unsigned Debug |
| `make check` | Passed lint, unsigned Debug, and 477 unit test runs with no failures or skips. Result bundle `ure-20261105-082322.xcresult` |
| `make release` | Passed, unsigned optimized Release. The Release `UrePerformanceHarness` also builds |
| `make recovery` | Passed all 58 recovery scenarios. They include upgrades of the retained v10 and v15 libraries, whose photo, PDF and link have a stage and source descriptions, with every interruption checkpoint |
| Isolated running app | Passed. See below |
| Local window check | Passed. See below |

### Acceptance criteria

1. Every existing photo, PDF and link appears as material on the same record, and no original file moves or changes. `MaterialMigrationTests` upgrades a real on-disk library made by the v19 schema. It has photos of every stage, captions, PDFs and links with source details and notes on a watch, an open job, a closed job and a caliber, plus a photo whose original file is missing. Every item keeps its ID, owner, title, URL or file, and dates. Every file record and original is unchanged, and the cover stays. The recovery matrix and `ReleaseJourneyTests` check the retained v10 and v15 libraries.
2. Dropping, choosing or pasting adds material to the record on screen. `MaterialServiceTests` imports a mixed batch and adds links. `MaterialStateTests` pastes a valid URL, an invalid URL and plain text. The window check pasted through the strip's responder chain and dropped a file on it.
3. Removing material can be undone with ⌘Z, and its original is deleted only when Undo can no longer bring it back. `MaterialServiceTests` and `MaterialStateTests` remove, undo, redo, and then quit by closing the library. The original stays until the library opens again, and an original that other material uses stays after that. The window check showed "Undo Remove Photo" and brought the photo back.
4. Caliber material shows on its watches' and jobs' pages and opens from there. `MaterialStateTests` opens a caliber photo from a watch page, moves to the next photo and opens a caliber link in the browser. The window check rendered the chips and opened the caliber's photo and PDF from the watch page.
5. Values from removed item fields appear in the owner's notes. `MaterialMigrationTests`, the recovery matrix, `ReleaseJourneyTests`, the running app and the window check.
6. A backup made before this change restores with all its material. `MaterialMigrationTests` stages and activates a backup package made by the v19 schema, with its originals.

### Isolated running app

The Debug binary ran directly with `URE_TESTING=1` and a new `URE_TEST_LIBRARY_ID`. Its library was seeded at schema v15 from the retained fixture. Six more items were added: photos with the Before, During and After stages and captions on a watch, a job and a caliber, a PDF with a source URL, a source description and notes, and links with source descriptions and notes. The photos were 1600-pixel JPEGs made from the system desktop pictures. The app upgraded the library to `v20-material`. Reading the new generation showed all nine items as material on their owners, each removed value in its owner's notes under "From the old record", the watch cover kept, and all six originals byte for byte the same as the old generation. The copy was quit by its PID. The installed `/Applications/Ure.app` and the real library were not touched.

### Local window check

This Mac gives sessions no Screen Recording or Accessibility permission, so there is no screenshot of the running app's own window. As accepted for the Rework stories on 5 November 2026, a local-only test hosted the app's real `LibraryRootView`, with every session environment, in a window of the test host. It opened a library made by the v19 schema and drove the real views. It was never committed and never runs on CI. It checked these things in order:

- The watch, job and caliber pages show the migrated material, and the notes show the removed values.
- Pasting plain text and an incomplete address through the strip shows why nothing was added. Pasting a complete address adds a link titled "omegawatches.com".
- Dropping a photo on the strip adds it to the watch.
- Typing in a tile's title saves it, the text field's own Undo is off, and Undo puts the old title back.
- Removing a photo takes its tile away, the Undo menu says "Undo Remove Photo", the original stays, and Undo brings the photo back.
- The caliber's chips show on the watch and job pages. The caliber's photo and PDF open from the watch page in the photo viewer and the PDF reader.
- A long chip title truncates within the row at a narrow width.
- A closed job's material is read-only and says to reopen the job.
- Saving everything before quitting saves a title still being typed. After the library closes and opens again, the removed photo's original is gone.

The renders in `~/Developer/test-assets/jorge-w034-material-b9d8a7/` show these steps, the watch page in light and dark, and the viewers. The window is 3,400 points tall, because a grouped form ignores AppKit scroll requests and the Material section is far down each page. The PDF reader's page is blank in the render, because PDFView draws its pages in layers that `cacheDisplay` does not capture. Its page count shows that the document loaded. The selected sidebar row's label is blank in offscreen renders, as in W033. The test host has no mouse or key events, so a real click on the strip, the file picker, and the shortcut menu were not driven. Context menus can't be opened in the test host, so removal ran through the same state call that the tile's Remove item uses.

## Codex review

The review ran with `codex exec review --ignore-user-config`, which used Codex's default model, `gpt-6-astra`, and left `~/.codex/config.toml` unchanged. Each round read the whole diff and the new files, and each round raised different findings. All of them were real and were fixed, with tests where the behaviour can be tested:

1. Round one found three. A title still saving when its material was removed kept counting as unsaved, and blocked restore and quitting. Undo could bring back a blank title. A long chip title overflowed its row.
2. Round two found that Undo after Redo lost a cover chosen in between, because Redo kept the first removal's snapshot.
3. Round three found that the file picker hid supported files with the wrong extension. It accepts any file again, and content detection decides.
4. Round four found that a finished import could reset a title renamed while the batch was running.

The review skill stops after four rounds. The coordinating session approved a fifth round, because each round had found a real issue. Round five read the whole branch and reported no findings.

## Remaining gates

- The Paper artboards' exact values were not read, because the Paper app was not connected. A later Rework story can match them.
- Native UI tests were not run, as the repository rules require during story work. `JobUITests.testReferenceWindowDoesNotSaveOrReplaceTheMainDraft` still drives the reference and note editors that W033 and W034 removed, so W042 must update it.
- The performance measurement was not rerun. Only its fixture and worker changed.
