# W042 Rework acceptance verification

The reworked app passes acceptance for everyday use on the development Mac, with the gaps below fixed in this PR. Every journey ran on a fresh library and on the realistic W031 library upgraded from before the Rework. A backup made by the app from before the Rework restored with every typed value. List browsing is as fast as W031 or faster. Four things still need you at the Mac: the native UI test run, a spoken VoiceOver pass, a look at Increase Contrast, and a run on macOS 27.0. They are listed with their commands at the end.

Recorded on 6 November 2026 for [W042, issue #70](https://github.com/jorgerodrigues/ure/issues/70). The base is `072e09c` on `w002-recoverable-library`, after W033 to W041 and the edit queue merged. Hardware: Mac16,8, Apple M4 Pro, 48 GiB. System: macOS 27.3, build 26C5035r. Toolchain: Xcode 27.2, build 27B52.

## What changed in this PR

The acceptance found five gaps that normal use hits. Each is fixed where the rule lives.

1. Tab skipped every multi-line text and every paste box. On a part's page Tab went from the name to the quantity, past the description, and then stayed in the quantity. A job's problem and every record's notes were never reached. Tab now moves through every place on a page that takes input, in reading order. Return in a one-line field still moves to the next one-line field, so Return in a new job's title still goes to its watch picker.
2. A value longer than its column was cut off with no "…". A long filename as a material title, or a long case in a watch's facts, simply stopped at the column's edge. A field now ends in "…" at rest and scrolls while you type.
3. The Calibers list had no photo tiles. W035 left them to W038, and W038 did not build them. Each row now shows the caliber's first photo, the same photo as its page's header, as on "5 Caliber".
4. A caliber's watch rows cut their detail at 200 points, so "Omega · About 1958 · In progress" read "In progr…" on a wide page. The detail now keeps its full width, and a long watch name gives way first.
5. The Material count always put PDFs first, as on "5 Caliber", so a watch read "1 PDF · 2 photos" where "4 Watch" reads "2 photos · 1 PDF". The larger count now comes first, which matches all three artboards.

Three native UI tests still drove the screens from before the Rework: the search test used note records, the keyboard test used ⌥⌘1 to ⌥⌘5 and the Archive section, and the reference-window test used the old notes and references. They now drive the reworked app. Their identifiers and texts were checked against the source, and they compile.

## Design rules

1. Tab and Shift-Tab stop at every place on a record page that takes input, top to bottom and then left to right: the one-line fields, the notes texts, and the boxes that paste material or an option. Return in a one-line field moves to the next one-line field. The place is `ReadingOrder` in `Ure/Features/Autosave/ReadingOrder.swift`. Each view that takes input says whether it is a stop through `ReadingOrderStop`, and every Tab handler calls `ReadingOrder.moveFocus`. The tests are `ReadingOrderTests`, which lay out a part's page and press Tab, Shift-Tab and Return through the real handlers, and the window check, which pressed Tab through the real job, part, watch and caliber pages.
2. A one-line value ends in "…" where it does not fit, and scrolls while you type. Scrolling resets the cell's line break, so one helper sets both states. The place is `truncatesAtRest()` and `scrollsWhileTyping()` on `NSTextField`, used by `InPlaceTextField` and `MaterialTitleField`. The tests are `LongValueTests` and the window check's renders of a long case while typing and at rest, and of a long material title.

## Journeys

The local window check hosted the real `LibraryRootView` with every session state in a window of the test host, as the Rework stories did. It typed through the real AppKit fields with key commands and rendered PNGs. It is `W042-LocalAcceptanceAppCheck.swift` in the shared notes folder, and it was never committed.

On a fresh library, one run did the whole journey of the issue:

1. ⌘N in Calibers, then the caliber's name, maker, beat rate, jewels and power reserve typed in place.
2. ⌘N in Watches, then the watch's name, brand, model, reference, year, case, diameter, lug width, owner, contact and notes typed in place, and three files added as material.
3. Start Job, then the title, the problem and the notes typed in place.
4. A checklist of three headings and ten steps typed like a note, with Return between lines and "# " for headings. Six steps ticked, and the heading read "6 of 10 done".
5. Three parts typed on the job's add line, with Tab to the description and Return to add, and a spare from the drawer used by typing "click", the Down Arrow and Return.
6. Three links pasted as options. "£12.90" and "$13.95" on a new option asked to choose the currency first, as W041 decided, and choosing it saved the typed price. The options read "≈ 21,40 €", "24,00 €" and "≈ 26,40 €", with Lowest on the first.
7. Two parts marked bought, one moved to In hand and the spare to Fitted. The job's Parts heading read "1 to buy · 38,20 € paid".
8. Mark as Bought from the popover with Return, then ⌘Z and ⇧⌘Z.
9. A job set to Done, then its watch archived, ⌘Z and ⇧⌘Z.
10. ⌘N in Jobs, a title, Return to the watch picker, "ham", and Return to pick the watch.

Every value was read back from the library after each step. The upgraded library had its own run: it opened, listed 450 open jobs, 500 watches, 50 calibers and 450 parts, and opened a watch, a job, a caliber, a part and a library search.

The real Debug app also ran directly with `URE_TESTING=1` and an isolated library, which was a copy of the W031 library at v17. It upgraded the copy to `v27-buying-options` in a new generation and kept the old one. The new generation had every record, and its integrity check passed. The copy was quit by its PID. The installed app and the real library were not touched.

## Nothing typed is lost

The realistic library is W031's fixture from 3 October 2026, at schema v17: 500 watches, 1,000 jobs, 10,000 tasks, 1,000 notes, 1,000 parts with 2,000 links, 5,000 photos and 50 calibers. Two copies were made with APFS clones. The original was only read.

1. The reworked app opened one copy, which ran every migration from v18 to v27.
2. The app from before the Rework, built at `0d7fda2` in a scratch worktree, opened the other copy and exported a backup with its own Export Library Backup code. That backup is at v18 and holds 5,000 originals.
3. The reworked app restored that backup into a new library. Staging applied v19 to v27.

A script then read the old library and both new ones. It took every distinct text value in a column a person types into, 14,072 values, and looked for each in the new library, as a whole value or inside one, such as the notes under "From the old record". It checked that every record kept its ID and that number facts kept their values. It also compared the upgraded and the restored library table by table.

- The upgraded and the restored libraries are identical, row for row, in every table.
- Every typed value is in both, with two exceptions. A watch condition of "Unknown" is the old default, so W036 does not write it, as for the other defaults. A part link's supplier stock code is gone because v18 dropped it, as described next.
- Every watch, job, caliber, task, part, link, photo and file kept its ID. Note records joined their record's notes text, so their own IDs are gone, as W033 designed.
- All 1,000 part quantities kept their values.

v18 is the migration from 24 October 2026 (PR #60), when you removed supplier details from part links. It drops a link's supplier name, price, stock code and notes, and writes them nowhere. It is from before the Rework, so this PR does not change it. A library that is still at v17, made by an app from before #60, loses those values on its first launch, and W041's options cannot bring them back. A library already at v18 lost them on 24 October.

The per-story migration tests also restore a backup made before each Rework migration. `RecordNotesTests.backupMadeBeforeRecordNotesRestoresWithItsNotes` restores a v18 backup through every Rework migration. `ReleaseJourneyTests` upgrades the frozen v10 and v15 libraries and restores them, and `make recovery` passed all 58 scenarios, including the upgrades of those libraries at every interruption point.

## Performance

`make performance` built a new fixture with the current generator. It has the same shape as W031's: 500 watches, 1,000 jobs, 10,000 checklist steps, 5,000 photos, 1,000 parts and 2,000 options. The measurement used the same Release worker, three processes, and ten warm reads each. Search now always includes archived records, so its rows compare with W031's "archive included" numbers.

| Operation | W031 median ms | W031 max ms | W042 median ms | W042 max ms |
| --- | ---: | ---: | ---: | ---: |
| Watch list, 500 | 1.75 | 1.86 | 1.64 | 1.79 |
| Job records, 1,000 | 5.74 | 6.07 | 2.63 | 2.94 |
| Tasks, now checklist steps, 10,000 | 29.55 | 30.51 | 16.36 | 17.96 |
| Photo metadata, 5,000 | 24.85 | 25.31 | 24.61 | 25.77 |
| Parts list, 450 | 8.25 | 8.51 | 5.19 | 5.53 |
| Workshop, now the Jobs list, 450 | 16.76 | 17.46 | 13.60 | 14.58 |
| Bench metadata | 30.23 | 30.91 | 26.55 | 27.64 |
| Search "Synthetic" | 26.02 | 26.66 | 25.45 | 26.08 |
| Search "ÜHREN" | 20.52 | 20.97 | 22.04 | 23.00 |
| Search a supplier code | 4.90 | 5.08 | 4.78 | 5.21 |
| Search a serial | 2.14 | 2.24 | 1.38 | 1.77 |
| Search with no match | 2.40 | 2.55 | 1.65 | 2.11 |
| Thumbnail decode | 2.23 | 11.54 | 2.53 | 12.70 |

A second run on the same fixture gave the same picture, within a millisecond. Opening the library took 69 to 72 ms, against 73 to 76 ms in W031. Every list is as fast or faster. The search for "ÜHREN" is about 1.5 ms slower with the same 6,500 results, because the search key now holds more text per record. It stays near 22 ms against the 300 ms target, so it was not changed. The large-image memory is unchanged from W031: each worker still ends near 1.98 GB after 20 large originals.

In the window, with the upgraded W031 library and the Debug build of the test host, every list loaded in 0.56 s. A section switch, laid out and drawn, took 0.10 to 0.27 s. Selecting a watch took 0.09 s, opening a job 0.11 s, filtering the watches 0.08 s, and a library search 0.08 s. These are Debug timings in a test host, so the optimized app is faster. Upgrading the W031 library with every migration took 7.8 s once, and restoring its 4.3 GB backup took 23.5 s.

## Pages against the artboards

Every page rendered at 1280 points wide, with the window tall enough for the whole page. The renders and the field readings are in `~/Developer/test-assets/jorge-w042-acceptance-b73667/captures/`.

- "1 Model" lists the four records, what goes and what is decided. The pages and the migration check above match it.
- "2 Job" matches: the header with the state pop-up, the title and the links, the problem, the parts with their pills and prices, the checklist with its bar, the material and the notes.
- "3 Parts" matches: the list's groups, the part's header with Mark as Bought, the description beside the quantity, the options with Lowest, the paste box, and the notes.
- "3b Part, after Buy" matches. The label reads "Paid, in EUR" where the artboard says "Paid, in euros", as W041 chose.
- "3c Mark as bought" matches in both forms.
- "4 Watch" matches, now with "2 photos · 1 PDF".
- "4b Archived watch" matches. The page says "Unarchive this record to add or change its material." where the artboard still shows the add box, because an archived record takes no changes.
- "5 Caliber" matches, now with the list's photo tiles and the full watch detail.
- "6 New job" matches, with the picker over the page.
- "7 Typing" matches: the field states, the checklist and part keys, and the rules for every page. Rules 4 and 11 needed the Tab fix above.

These differences are left and named here:

1. A PDF's tile shows a document icon, not its first page as the artboards draw it. W034 built page thumbnails only for photos. Rendering PDF pages is new work, so it is a follow-up.
2. The toolbar has three reference buttons, Pin Reference, Open Reference Window and Toggle Reference Pane, which the artboards do not show. They come from W012, and each is also in the View menu with its key. They stay until you decide otherwise.
3. Typing "£12.90" into a new option asks you to choose GBP in its currency menu first, while the Mark as Bought popover takes the "£" as the currency. W041 chose this so typing never relabels an amount.
4. A watch's cover is the photo you choose. A watch with photos and no cover shows a placeholder in the lists, while the artboards' sample watches all have covers.

## Appearances and accessibility

Every page rendered in light and dark. Dark Mode needed no change: every page reads well, and the selected rows, pills and the accent all adapt. The app uses system colours and the accent colour asset only, which has light and dark values. White text appears only on the accent fill of a selected row, a highlighted suggestion and the In hand pill.

Increase Contrast could not be rendered. The test host drew the high-contrast appearances exactly like the normal ones, byte for byte, because SwiftUI follows the system setting, and a session may not change system settings. Since every colour is a system colour, the pages should follow the setting. Checking it is in the list below.

The check read the accessibility label and value of every field on every page from its AppKit view: 23 on the job page, 5 on the part page, 4 after Buy, 16 on the watch page, 12 on the archived watch, 8 on the caliber page, 8 on the new job with its picker, and the fields of Search and Settings. Every one has a label, such as "Title", "Problem", "Step, ticked" with the step's text as the value, "Add a part or use a spare", "Watch" and "Paste a link to add an option". The one field without an AppKit label is the popover's "Charged to you", which takes its label from SwiftUI's `accessibilityLabel`. SwiftUI builds its own accessibility tree only when an assistive app is attached, so its pop-ups, buttons and labels could not be read in the test host. A spoken VoiceOver pass is in the list below.

Tab, as the keyboard sends it, went through each page in reading order:

- Job: title, problem, each part's name, the add line, its description, each checklist line, the add-step line, the material box, the notes.
- Part: name, description, quantity, the paste box, the notes.
- Watch: name, brand, model, reference, serial, year, case, diameter, lug width, owner, contact, the material box, the notes. The caliber pop-up is a control, so it is reached with Full Keyboard Access.
- Caliber: name, maker, beat rate, jewels, power reserve, lift angle, the material box, the notes.

## The HIG review points

- Pop-up buttons: the job state, a part's state on its page, the winding, the watch's caliber, an option's currency and the home currency are pop-ups. Clicking a state pill on a job's line moves the part on, and Needed opens Mark as Bought, as "3c" says.
- Search: ⌘F puts the cursor in the toolbar's Search field in every section, and ⇧⌘F opens Search Library. The search check typed into both.
- A menu command for every toolbar button: the toolbar holds Hide Sidebar, Pin Reference, Open Reference Window, Toggle Reference Pane, New Job (or New Watch, New Part, New Caliber) and Search. Each is a menu command with the same name: Show Sidebar ⌃⌘S, Pin Reference, Open Reference Window ⌥⌘R, Toggle Reference Pane ⇧⌘R, New Job ⌘N and Search ⌘F. Unarchive is Unarchive Watch in the Record menu.
- Right-click menus: steps, parts, watches, calibers, material and options have them. W039 to W041 checked them in their window checks.
- Keyboard paths: ⌘1 to ⌘4 select the sections, ⌘N makes a record and puts the cursor in its name, Tab and Return move through each page, the checklist's keys, the part line's keys, and Esc in a field.
- Region formats: money and numbers follow the Mac's region. This Mac is in Denmark, so the pages show "21,40 €" and "19.800 vph".
- System colours: see Appearances.

## Not verified

1. The native UI tests did not run. Automation Mode is off and needs your password (`automationmodetool status` says so), and a session must not work around it.
2. VoiceOver was not spoken. The fields' labels and values were read from AppKit, and SwiftUI's controls only by their source.
3. Increase Contrast was not rendered.
4. Nothing ran on macOS 27.0.
5. The test host's windows are never key, so prominent buttons render grey and the sidebar renders blank. The toolbar is not in the renders.
6. The Debug app logged one AppKit warning while it loaded the upgraded library's 450 jobs: "Application performed a reentrant operation in its NSTableView delegate." It appeared once and changed nothing on screen. Its cause is not known yet.

## What you still have to run

Each of these needs you at the Mac.

1. Run the native UI tests from Terminal with `make test-ui`, on an idle desktop. macOS asks for your password once to turn on Automation Mode. If you would rather it never asks, `sudo automationmodetool enable-automationmode-without-authentication` turns that off, which is a security setting and your call. The result bundle goes to `~/Developer/test-assets/<branch>/`.
2. With VoiceOver on (⌘F5), go through a job page, a part page with Mark as Bought, a watch page and Settings, and listen to the state pop-ups, the pills, the tick boxes, the option cards and the popover's fields.
3. Turn on Increase Contrast in System Settings › Accessibility › Display, and look at a job page and a part page in light and dark.
4. Run `make check` and `make release` on a Mac with macOS 27.0.
