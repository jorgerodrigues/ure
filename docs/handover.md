# Run and recover Ure locally

Ure stores a lasting watch record and separate repair jobs. A watch can have one open job. Shared caliber records hold reusable knowledge. Job stage, watch condition, and task progress change independently.

First-release acceptance is **pending**. See the [acceptance report](planning/release-acceptance.md) before using Ure as the only copy of valuable records. The local bundle identity is `local.ure.app`. Distribution identity, signing, and notarization are separate work.

## Fresh checkout and launch

Use an Apple silicon Mac with macOS 27 or later and Xcode 27 or later. Select Xcode in its Settings > Locations, then check `xcode-select -p` and `xcodebuild -version`. The repository requires GitHub read access. Building and local ad-hoc signing require no Apple developer account.

```sh
git clone git@github.com:jorgerodrigues/ure.git
cd ure
make check
make release
make run
```

Xcode resolves the committed GRDB version. It is the sole runtime package. You can also open `Ure.xcodeproj`, select the shared Ure scheme, and Run. `make release` builds an unsigned optimized app; `make run` builds and launches the locally signed Debug app.

If `clang-stat-cache` stalls on the development beta, pass `XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` to each Make command. An ignored `Config/Local.xcconfig` can contain `SDK_STAT_CACHE_ENABLE = NO`. Keep machine settings and credentials out of tracked files.

## Enter a repair

1. Select Watches with **Option-Command-2**. Use **Command-N**, enter a name, and save with **Command-S**. Leave unknown specifications blank.
2. Use **Start Job** in the watch detail. Enter its title and intake. Save. The intake snapshot keeps the watch identity at that time.
3. Add notes, tasks, parts, supplier links, photos, and PDFs in that job. A part link can contain only a complete HTTP or HTTPS URL. Keep manufacturer references separate from supplier stock codes.
4. Import originals before removing source files. Saved photos and PDFs remain local. External links need their destination website.
5. Pin a reference while working on tasks. Use **Option-Command-R** for the read-only reference window. Use **Change Job Stage** to record Waiting and its reason. Part arrival changes availability, without resuming a Waiting task.
6. Use **Change Stage** to complete the job. Enter an outcome and explain unfinished work when requested. A later repair uses **Start Job** on the same watch. Earlier intake and outcome stay saved.

Editors use Save and Cancel. Navigation, closing, and quitting offer Save, Discard, or Stay for a changed draft. A failed save keeps the draft. Task progress excludes Skipped tasks. No counted tasks shows **No tasks planned**.

## Find the library

Open Settings with **Command-comma**. Copy the displayed **Library folder** location. The sandbox resolves this path. Do not assume a fixed path under your home folder.

`active-library.json` selects the current directory under `generations/`. It holds `library.sqlite`, `manifest.json`, and immutable `originals/`. Recovery copies live under `recovery/`. Do not edit these files or change the pointer by hand. A failed open shows recovery and preserves the saved library. Retry after addressing the reported cause.

## Export and restore

In Settings, use **Export Library Backup…** and choose a `.watchbackup` location. Wait for the success message. Store a copy on another disk. A local recovery copy does not protect against loss of the Mac. The last-export time does not prove the exported file still exists.

Restore replaces the current library. It does not merge records. Changes after the backup date are lost. Save or cancel drafts first. Use **Restore Library Backup…**, review its date and counts, then **Replace Library…** and the separate confirmation. Ure validates the package and its originals. It saves a complete recovery copy before switching. A failure shows its reason and keeps or recovers a complete library. **Show Recovery Copy in Finder** locates a saved recovery copy after an attempt.

Try restore in a disposable instance first. Quit any running Ure instance after building the Debug app, then launch:

```sh
test_library_id=$(uuidgen)
open -n --env URE_TESTING=1 --env URE_TEST_LIBRARY_ID="$test_library_id" \
  .build/DerivedData/Build/Products/Debug/Ure.app
```

The marker selects only a temporary test library. A UUID reuses that isolated library across marked restarts. It cannot inject an arbitrary path. Check Settings to confirm the temporary location before restoring. Quit this instance when done. An ordinary `make run` reopens the regular library.

After restore, compare watch names and exact identifiers, job history, task/part states, supplier links, notes, and file counts with the source library. Open the restored photos and PDFs with networking disconnected. Export sample originals and compare bytes with the backup originals. The automated `ReleaseJourneyTests` also checks all record values and every original's size and SHA-256 for fresh, v10, and v15 libraries.

## Verification and remaining acceptance

`make check` runs formatting, the unsigned Debug build, and all isolated unit tests. `make release` builds optimized Release. CI runs both. `make recovery` runs the retained process interruption matrix. UI automation runs only locally on an idle desktop with Accessibility permission for Xcode Helper. Use `make test-ui` for the native suite. Result bundles are saved under `~/Developer/test-assets/<branch>/`.

Native file panels, full keyboard and VoiceOver journeys, appearance/accessibility settings, optimized window/input timing, large-image viewer allocations, and minimum macOS 27.0 still need the evidence listed in the [acceptance report](planning/release-acceptance.md). Passing unit tests or CLI timings does not complete these gates.
