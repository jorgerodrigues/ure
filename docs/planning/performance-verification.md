# W031 library performance verification

The optimized command-line measurements meet the proposed 300 ms target for the measured data queries. Native usable-window and input acceptance remain unverified. Large-image resident memory grows in the async worker and remains an open concern. No performance acceptance is claimed for the native app.

## Fixture and method

Measurements were recorded on 4 October 2026 in the W031 implementation run. Hardware: Mac16,8, Apple M4 Pro, 48 GiB RAM. System: macOS 27.2 beta, build 26B5091g. Toolchain: Xcode 27.0, build 27A266a. The command-line target uses the project's Release configuration, `-O`, whole-module compilation, Swift 6, complete concurrency checking, and warnings as errors. The app and UI tests were not launched. CI remains formatting/lint and unsigned Debug until W032.

`make performance XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` builds the harness. `PerformanceHarness/run.py` creates a marked disposable library with deterministic record IDs and saved dates. Access goes through `LibraryCoordinator`. Each worker requires `URE_TESTING=1`, an injected path matching its marked fixture, and a Release build. No worker opens the normal user library. Reuse requires a marked directory under `.build/performance-runs/`.

The fixture contains exactly 500 watches, 1,000 jobs, 10,000 tasks, and 5,000 photo items. It also contains 50 calibers, 1,000 notes, 1,000 parts, 2,000 supplier links, and 2,000 task-part links. Each watch has two jobs. The first 450 watches have one open and one closed job. The other 50 watches are archived with two closed jobs. Each job has ten tasks: two each of To do, Doing, Waiting, Done, and Skipped. Each job has one Needed part with quantity seven and two linked tasks. The overview must count that part once. Five calibers are archived.

Photos belong to jobs. Each has its own asset row, storage key, original file, and metadata. Three deterministic RGB JPEG templates repeat across the originals at 640 × 480, 2400 × 1600, and 6000 × 4000 pixels. They have orientation 1. This is a reproducible size/decode workload, not a representative camera codec or orientation distribution. Every watch has a cover reference. Logical original bytes total 4,626,353,056. APFS can share physical storage for copied bytes. The encoder can change output across OS versions; compare the recorded fixture hash before comparing measurements.

The driver independently checks expected result IDs, duplicate absence, database integrity, foreign keys, record counts, and all 5,000 original hashes and sizes. It repeats inspection after measurement to prove that queries and viewing did not change saved content. The fixture content SHA-256 is `ff6d0674b0c4e9cd0b2038500b13df3884d6c9a8377ff697a7045be2bd48f8db`. W029's historical SQL and binary fixtures are unchanged.

Three fresh measurement processes use that same fixture. Each data query has one first read and ten warm reads per process. Query timings include the actor call, SQL, record decoding, and result-ID projection. They exclude SwiftUI rendering, local view-state filtering, search debounce, and navigation. Thumbnail timings include original-path lookup and background ImageIO decoding. Thirty thumbnails per process cycle through all three size classes. Each process then opens and releases 20 distinct 6000 × 4000 originals, retaining only scalar measurements. Resident memory is sampled before the decode, while its image is held, and after the consumer returns. Process isolation prevents fixture creation and its images from contributing to measurement memory.

## Recorded measurements

These are the final reproduction values on unchanged app code. Each query has 30 warm samples. Thumbnail decoding has 90 samples. The original baseline used the same fixture and build mode. Its warm maxima were 35.91 ms for bench metadata, 34.50 ms for tasks, 31.09 ms for search, and 12.57 ms for thumbnails. Differences in the final run are run variation, not an optimization gain.

| Operation | Median ms | Maximum ms |
| --- | ---: | ---: |
| Watch list, 500 records | 1.75 | 1.86 |
| Job list, 1,000 records | 5.74 | 6.07 |
| Task snapshot, 10,000 tasks and linked parts | 29.55 | 30.51 |
| Photo metadata list, 5,000 records | 24.85 | 25.31 |
| Parts overview, 450 requirements | 8.25 | 8.51 |
| Workshop overview, 450 open jobs | 16.76 | 17.46 |
| Bench metadata snapshot | 30.23 | 30.91 |
| Search Synthetic, archive excluded, 7,695 results | 24.11 | 26.12 |
| Search Synthetic, archive included, 8,550 results | 26.02 | 26.66 |
| Search ÜHREN, archive excluded/included | 19.11 / 20.52 | 19.54 / 20.97 |
| Search supplier code `00.A_%`, excluded/included | 4.64 / 4.90 | 4.74 / 5.08 |
| Search literal serial `00.001_%'`, one exact watch | 2.17 / 2.14 | 2.24 / 2.24 |
| Search no match, excluded/included | 2.45 / 2.40 | 2.54 / 2.55 |
| Thumbnail lookup and decode, at most 256 pixels | 2.23 | 11.54 |

Coordinator open took 73.91, 73.16, and 76.48 ms. It includes pointer, manifest, database validation, and abandoned-import recovery. These are fresh-process opens with an already read filesystem cache. They are neither cold-disk launch timings nor usable-window measurements. The first metadata reads are retained separately in the raw report. The 3-second native usable-window target remains pending. The entire benchmark process time includes every query and image cycle and must not be presented as app launch time.

Workshop assertions confirm 2 Done, 8 counted, and 2 Skipped tasks for every open job. Each job has one unresolved part despite quantity seven and two task links. Exact ID checks include archived owners, closed jobs, literal percent/underscore/quote characters, Unicode case matching, no matches, and supplier matches without duplicate results. Search excludes tasks by the existing product contract.

## Image memory investigation and limits

The original baseline grew from about 62 MiB to 1.9 GiB resident memory across 20 async original open/release cycles. The final reproduction ends at 1,988,247,552, 1,981,956,096, and 1,983,561,728 resident bytes. Growth after the first four cycles is about 1.53 GB in each process. This is an unresolved measured result. It is not a passing memory acceptance result.

Separate isolated diagnostics compared a scoped autorelease pool, ImageIO cache options/removal, direct decoding into an owned bitmap, async ownership transfer, and a queue with a per-operation autorelease boundary. Synchronous direct bitmap decoding released the large buffers. The async reproduction retained them. The proposed product decoder changes did not improve the same fixture's async measurements and were removed. There is no measured justification for a query index, paging, or cache layer, so none was added. The harness's resident-memory observation alone does not identify which object retains the buffers or establish that the native app has the same lifetime. W032 must use native allocation profiling and inspect the actual viewer's lifetime before accepting repeated large-image viewing or selecting a fix.

The final report stores every open/release sample and the observed memory growth. A successful measurement command confirms completion and unchanged data, not memory or native performance acceptance. Thumbnail dimension checks confirm bounded output in this workload. They do not prove that native scrolling loads only visible rows or that task input remains responsive. JPEG templates do not establish HEIC/PNG, transparency, color-profile, or orientation acceptance.

## Checks and retained evidence

Local formatter/lint, unsigned Debug build, optimized harness build and execution, Python syntax parsing, and diff whitespace checks passed. All existing unit and native UI sources compile with `build-for-testing` without execution. The harness runs focused data/count/integrity checks in its own process; app behavioral execution remains deferred. Xcode retains its existing AppIntents no-framework metadata-extraction notice.

Raw reports and the reusable fixture are under `.build/performance-runs/76a5caea-a0ae-4d70-abc6-c6ef5d7558b5/`. The initial summary is retained at `.build/w031/before-summary.json`. The documented reproduction summary is also copied to `.build/w031/recorded-summary.json`. Build logs and diagnostic logs are under `.build/w031/`. These ignored files are local evidence, not a durable release artifact. Preserve the large fixture for W032. No screenshot, video, or result bundle was created.

## Pending W032 acceptance

- Restore CI unit execution and Release builds before first-release acceptance. Native UI/device automation stays off CI.
- Measure an optimized native usable window from process launch against the 3-second target. Record hardware, cache state, and actual results.
- Use the same fixture for native list/search response, scrolling, and task input while thumbnails decode. The 300 ms target is passed only for the measured data layer here.
- Profile allocations and resident memory while opening, navigating, and closing large originals in the main and reference viewers. Explain the async worker's observed growth. Fix only a demonstrated cause and rerun the same fixture and mode.
- Run existing behavioral tests in isolated libraries. Check orientation, color, transparency, HEIC/PNG, cancellation, missing originals, and retained-image readability if decoder code changes.
- Complete W030 keyboard, VoiceOver, appearance, minimum-window, draft, close/quit, and failure acceptance from `keyboard-access-verification.md`, plus W029's remaining native recovery and file-panel gates.
- Record the minimum macOS 27.0 acceptance run or leave it explicitly pending. No first-release acceptance follows from this report alone.
