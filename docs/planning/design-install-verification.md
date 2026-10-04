# Paper design foundations and local installation

Recorded on 4 October 2026. This update implements the user's request for the Paper icons and basic design system, then installs an optimized local app. It uses merged release foundation `56fa50a` from the live default branch, `w002-recoverable-library`. This report does not close [W032 #28](https://github.com/jorgerodrigues/ure/issues/28) or its remaining acceptance gates.

## Design source and scope

Read the live [Paper Ure file](https://app.paper.design/file/01M3XMBQN7WXTGQBWF7QYKP790). The token hash was `b9b53808`. Read the Logo Pomme v2 vectors, macOS 27 rules and main window JSX, watch detail and implementation notes, and computed window, sidebar, list and detail styles. The existing Icon Composer source already matched the Pomme v2 geometry and layer settings. Its dashed illustrative guides remain outside the actual artwork. The light and dark accent asset already matched `#2340B0` and `#5068DB`.

The native foundation now shares the 1000 × 650 minimum, 1200 × 800 default, 220-point sidebar and 320-point list width. List thumbnails are 36 points. Rows use consistent title and subtitle spacing. Sidebar symbols keep equal slots, the user's accent, and a semibold selected title. Saved watches, calibers and jobs have readable system-style headings with short section toolbar titles. Watch values without recorded data use Paper's “Not recorded” and semantic tertiary colour. Toolbar actions have native symbols, accessible text labels, help and their existing menus. Every editor has one prominent Save. Native lists, grouped forms, selection, backgrounds and scroll-edge effects remain system-owned.

The watch-page proposal to change Save/Discard/Stay was not part of this visual foundation. The existing guarded editing behavior stays as specified. No schema, stored value, original file, runtime package, font, custom glass surface or animation was changed.

## Executed checks

Development Mac: Apple silicon, macOS 27.2 beta (`26B5091g`), Xcode 27.0 (`27A266a`). The local SDK cache workaround was passed explicitly.

| Check | Result |
| --- | --- |
| `make lint` and `git diff --check` | Passed on the final sources |
| `make check XCODE_EXTRA_FLAGS='SDK_STAT_CACHE_ENABLE=NO -parallel-testing-enabled NO'` | Passed Debug build, lint, and 282 unit definitions across 49 suites; 539 executions including parameter cases, zero failures or skips |
| `make release XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Passed optimized unsigned Release |
| Icon Composer exports | Default, Dark, Tinted Light/Dark, Clear Light/Dark rendered and visually inspected; Default also inspected at 16 and 32 points |
| Installer behavior with disposable signed app copies | Fresh installation and full replacement passed; stale resources were removed; corrupt-signature input left the prior app intact; injected final-move failure restored the previous verified app; staging cleaned up |
| `bash -n scripts/install-local.sh` | Passed |
| `make install INSTALL_DIR=/Applications XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` | Built signed Release, verified its signature, installed `/Applications/Ure.app`, and opened it |
| Installed bundle | `codesign --verify --deep --strict` passed; arm64 binary; ad-hoc signing and runtime flags `0x10002`; sandbox and user-selected file access only; no debug entitlement; AppIcon.icns and Assets.car present; AppIcon and AccentColor selected in Info.plist |
| Installed launch | Confirmed running from `/Applications/Ure.app/Contents/MacOS/Ure` with an on-screen native window |

The result bundle is `ure-20261004-133617.xcresult` under `~/Developer/test-assets/paper-design-foundations/`. Icon renders are in the same folder. Keep that folder while the branch is active. Build and check logs are under ignored `.build/paper-*.log`. The suite retains its existing test-only backup checkpoint priority-inversion warning. Xcode retains the AppIntents metadata notice. No Swift compiler warnings or errors were reported.

## Remaining gates

Native UI automation was checked before this work. Automation Mode is disabled and requires user authentication. No native UI test was run or counted as passing. A capture of only the installed Ure window also failed with “could not create image from window”; no installed-window image was produced. The final native appearance, active/inactive selection, minimum-size toolbar overflow, both appearances and accessibility settings still need their acceptance pass.

The app is optimized and signed for use on this Mac. It is not notarized for distribution. Keep minimum macOS 27.0 native acceptance, the complete repair and backup/restore journeys, and the remaining performance and image-memory checks pending as listed in [release-acceptance.md](release-acceptance.md). CI results for this design PR are recorded in the PR.
