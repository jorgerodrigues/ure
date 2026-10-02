# W009 managed file import verification

Issue: [#7](https://github.com/jorgerodrigues/ure/issues/7). PR: [#36](https://github.com/jorgerodrigues/ure/pull/36). Branch: `w009-managed-file-import`.

W009 is internal infrastructure. `FileImportService` imports JPEG, PNG, HEIC, and PDF originals through `LibraryCoordinator`. There is no file picker, gallery, thumbnail, or viewer in this story. W010 and W011 add the user-facing file items.

The user approved 100 MB (100,000,000 bytes) per original and 200 files per batch on 2 October 2026. A batch beyond that count returns a per-file limit error without importing it. Within the limit, a failed file leaves the other files available for import. Repeated imports produce separate assets.

## Storage and recovery

The forward `v8-file-assets` migration stores generated relative keys, original filenames, detected types, byte counts, SHA-256 hashes, import times, image dimensions, and EXIF orientation. Existing links, notes, jobs, watches, calibers, and original files remain in place. Earlier migration fixtures remove v8 before v7.

Each import runs on the coordinator actor without a suspension point. It holds the same gate as database mutations, startup recovery, and internal snapshots. It obtains security-scoped source access, opens regular files without following a source symlink, copies bounded chunks into the active generation's `imports/` folder, hashes those copied bytes, and validates that copy with Image I/O or Core Graphics. It synchronizes the complete staged file, atomically moves it to `originals/<UUID>.original`, synchronizes the original directory, and then commits the asset row. The user's filename is metadata only. It never controls the destination path.

A failed write checks database references before removing the original. Failed cleanup leaves the file for startup recovery. Recovery reads only committed asset storage keys, so pre-migration snapshots do not decode asset metadata with the current model. Recovery checks those keys and removes only unreferenced generated originals and staged import names. It preserves unknown filenames and referenced originals. Internal snapshots use this same recovery gate. Recovery before generation activation completes before the active pointer changes.

Cancellation before commit returns a per-file cancellation error. Cancellation or an injected failure after commit retains and returns the committed asset. Existing assets stay intact. Image decoding, hashing, file I/O, and database work run on the coordinator actor away from the main actor.

## Checks performed on 2 October 2026

- `make lint` passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO` passed as an unsigned Debug build.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO build-for-testing` passed. This compiled all unit and native UI test sources without execution.
- `git diff --check` passed.

Xcode emitted its existing App Intents metadata notice because the app does not use App Intents. There were no Swift compiler warnings or errors in the successful checks. The SDK file-cache workaround was passed locally and was not committed.

## Behavioral coverage and pending gates

The test sources generate real, non-sensitive JPEG, PNG, HEIC, and PDF files with Apple's encoders. They cover byte preservation after source removal and restart, misleading and hostile filenames, dimensions and orientation, repeated imports, per-file errors, size and batch limits, truncated images, corrupt and password-locked PDFs, owner-restricted PDFs that open without a password, subsecond import date round-trips, actual database rejection, injected disk exhaustion and interruption at copy/rename/commit boundaries, cancellation, cleanup retry, preserved references and unknown files, symlink rejection, concurrent imports/cleanup/snapshots, and forward migration, including a pre-migration asset metadata shape that cannot decode until its migration runs.

These test sources were compiled, not executed. Unit execution, Release checks, native UI acceptance, minimum-OS checks, and full recovery acceptance remain pending for W032 and the recovery milestones. No app tests were launched on the active desktop. No UI automation ran on CI.

## Independent review

Three full review rounds completed, with no P0-P2 finding remaining in the final round. One intermediate attempt was stopped before a report to complete the empty-password PDF check against Apple's [Quartz PDF opening sequence](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_pdf_scan/dq_pdf_scan.html).

The review fixes accept owner-restricted PDFs that open with an empty password, normalize import dates using the same Unix-time round-trip as the other services, and make pre-migration recovery read only stable storage keys rather than decode current asset metadata. Regression sources were added and compiled for each fix.

One P3 finding remains: non-image ISO media such as MOV, MP4, and M4A files are rejected as corrupt rather than unsupported. No such file is imported. The error message is less useful. A later change can narrow the fallback to HEIF brands.

## Remote checks

[CI run 37000321307](https://github.com/jorgerodrigues/ure/actions/runs/37000321307) passed formatting and the unsigned Debug build. PR #36 had no GitHub review comments or threads when checked after that run. The final documentation update will receive its own CI run before merge. Runtime and native acceptance gates remain deferred.
