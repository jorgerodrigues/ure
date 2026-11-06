# Run and recover Ure locally

Ure keeps four kinds of record. A caliber is what you know about a movement. A watch is the object on your bench, and it keeps its jobs. A job is one repair of one watch, and a watch has at most one open job. A part is what you buy, for a job or as a spare in the drawer. Each record is a page you write on. There is no Edit button and no Save: every field saves as you type, and ⌘Z undoes any change.

First-release acceptance is **pending**. The Rework was accepted for everyday use on 6 November 2026. See the [acceptance report](planning/release-acceptance.md) and the [Rework acceptance record](planning/rework-acceptance-verification.md) before you use Ure as the only copy of valuable records. The local bundle identity is `local.ure.app`. Distribution identity, signing and notarization are separate work.

## Fresh checkout and launch

Use an Apple silicon Mac with macOS 27 or later and Xcode 27 or later. Select Xcode in its Settings › Locations, then check `xcode-select -p` and `xcodebuild -version`. The repository needs GitHub read access. Building and local ad-hoc signing need no Apple developer account.

```sh
git clone git@github.com:jorgerodrigues/ure.git
cd ure
make check
make release
make run
```

Xcode resolves the committed GRDB version. It is the only runtime package. `make check` runs formatting, the unsigned Debug build and the unit tests. `make release` builds the unsigned optimized app. `make run` builds and opens the Debug app on your real library. `make install` builds a locally signed Release, installs it in `~/Applications` and opens it.

If `clang-stat-cache` stalls on a development beta, pass `XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` to each Make command. An ignored `Config/Local.xcconfig` can hold `SDK_STAT_CACHE_ENABLE = NO`. Keep machine settings and credentials out of tracked files.

## Enter a repair

1. Press ⌘4 for Calibers and ⌘N. Type the caliber's name, then Tab through its maker, beat rate, jewels, power reserve and lift angle. Choose its winding in the Winding pop-up. Leave unknown facts empty.
2. Press ⌘3 for Watches and ⌘N. Type the watch's name, then Tab through its brand, model, reference, serial, year, case, diameter, lug width, owner and contact. Choose its caliber in the Caliber pop-up. Numbers take what you would write on paper, such as "35 mm" or "35,5".
3. Click Start Job under the watch's jobs. Type the title, then the problem in your own words. ⌘N in Jobs also makes a job, and Return then moves to its watch picker.
4. Type the checklist like a note. Return starts the next step, a line that starts with "# " is a heading, Shift-⌘U ticks a step, and Ctrl-⌘ with an arrow moves it.
5. Type each part on the line under the parts, with Tab to its description and Return to add it. Typing a name also offers the spares in hand, and Return uses the highlighted one.
6. Open a part to compare where to buy it. Paste a link on "Paste a link to add an option", then type its price and shipping. Choose a currency other than your home currency in the option's currency menu first. Set your exchange rates once in Settings › Money.
7. Click Needed on a part, or Mark as Bought… on its page, to record what you paid. A click on a later state moves the part on to In hand and Fitted.
8. Set the job's state to Waiting with what it waits for, or to Done once it is finished. Write the outcome and anything left for later in the job's notes.
9. Drop or paste photos, PDFs and links on a page's Material box. ⌘D in the notes types today's date.
10. Archive a watch from the Record menu or with a right-click. It folds away at the end of the Watches list and stays in search. Unarchive brings it back.

## Saving and Undo

Every change goes through one edit queue in the order you make it, and saves within half a second. Quitting and closing the window wait until every change has saved. ⌘Z and Shift-⌘Z undo and redo any change, also after it saved, such as a typed fact, a tick, Mark as Bought, an archive or a deleted part.

If a change cannot be written, a bar at the top of the window says so. Your changes stay on screen and wait in order. Try Again saves them once the cause is fixed. Discard Unsaved Changes… asks first, then puts back what the library holds. Quitting while changes wait asks whether to try again or discard them.

## Find the library

Open Settings with ⌘, and copy the **Library folder** location. The sandbox resolves this path, so do not assume a fixed path under your home folder.

`active-library.json` selects the current directory under `generations/`. It holds `library.sqlite`, `manifest.json` and the original files in `originals/`. Recovery copies live under `recovery/`. Do not edit these files or change the pointer by hand. A library that fails to open shows recovery and keeps the saved library. Retry once the cause is fixed.

## Upgrading a library from before the Rework

The first launch of the reworked app upgrades the library in a new generation and keeps the old one. The upgrade of the realistic W031 library, with 1,000 jobs and 5,000 photos, took 7.8 seconds in a Debug build. Nothing you typed is lost: a value from a field that went is written into its record's notes, under "From the old record". Note records join their record's notes, oldest first. Tasks become checklist steps, with Done and Skipped ticked and group labels as headings. Part links become options without prices.

One older change is not part of this rule. On 24 October 2026 (PR #60) part links lost their supplier name, price, stock code and notes. A library that an app from before that PR made still has them, and its first launch with the reworked app drops them.

## Export and restore

In Settings, use **Export Library Backup…** and choose a `.watchbackup` location. Wait for the success message, and store a copy on another disk. A local recovery copy does not protect against the loss of the Mac. The time of the last export does not prove that the file still exists.

Restore replaces the current library. It does not merge records, and changes made after the backup are lost. Export and restore wait until every change has saved, and refuse while the failure bar shows. Use **Restore Library Backup…**, check its date and counts, then **Replace Library…** and the second confirmation. Ure checks the package and its originals, upgrades it in a staging copy, and saves a complete recovery copy before it switches. A failure shows its reason and keeps or recovers a complete library. **Show Recovery Copy in Finder** finds a saved recovery copy afterwards. A backup made before the Rework restores with every typed value. The W031 backup of 4.3 GB took 23.5 seconds.

Try a restore in a disposable copy first. Quit any running Ure, build the Debug app, then launch:

```sh
test_library_id=$(uuidgen)
open -n --env URE_TESTING=1 --env URE_TEST_LIBRARY_ID="$test_library_id" \
  .build/DerivedData/Build/Products/Debug/Ure.app
```

The marker selects a temporary test library, and the same UUID reuses it across launches. It cannot point at another path. Check the library folder in Settings before you restore. Quit this copy when done. A plain `make run` opens your regular library again.

After a restore, compare watch names and identifiers, jobs, checklists, parts with their options and what you paid, notes and file counts with the source. Open the restored photos and PDFs with networking off.

## Verification and remaining acceptance

CI is turned off for the prototype phase. Before you merge, run `make check` and `make release` on the final commit. `make recovery` runs the process interruption matrix. `make performance` measures the W031-shaped library in an optimized worker. `make test-ui` runs the native UI tests on an idle desktop, and macOS asks for your password once to turn on Automation Mode. Result bundles go to `~/Developer/test-assets/<branch>/`.

Still to check by hand: the native UI test run, a spoken VoiceOver pass, Increase Contrast, file panels with sandbox grants, large-image memory in the viewers, and a run on macOS 27.0. The [acceptance report](planning/release-acceptance.md) keeps the list.
