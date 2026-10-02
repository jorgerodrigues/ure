# W010 local photo verification

Implemented on 2 October 2026 for [W010 (#8)](https://github.com/jorgerodrigues/ure/issues/8), in [PR #37](https://github.com/jorgerodrigues/ure/pull/37). W009 is closed and merged in [PR #36](https://github.com/jorgerodrigues/ure/pull/36), at `f27d6eed6f2eb1f1ba19cabd2785942e38950463`.

## Scope and behavior

- Photos are LibraryItems owned by exactly one watch, job, or caliber. The v9 forward migration preserves links, records, original files, and timestamps. It adds file-asset references, captions, photo stages, and watch cover references.
- The system picker and URL file drop share FileImportService's batch loop and use the approved 100,000,000 byte original limit and 200-file batch limit. Each file reports success or failure. Repeated imports create separate items. Cancellation keeps complete committed items.
- The coordinator publishes the complete original before committing its asset and photo item in one database transaction. An attachment failure rolls back both rows. Cleanup and snapshots share the coordinator gate. Postcommit failures retain the successful item.
- Stage filters and previous/next navigation stay in the selected scope. Changing the selected photo's stage leaves adjacent matching photos navigable. Title, caption, and stage edits use Save, Cancel, Command-S, and the existing navigation/window/quit guard. Closed-job imports and edits are disabled in the UI and rejected by the service.
- Watch covers can reference their own photos or photos from their jobs. The service and database validate cover ownership. Watch identity edits preserve the cover. Deleting a referenced item clears the cover through its foreign key. Child removal UI remains W023.
- The coordinator resolves validated original URLs and asset metadata. ImageIO decodes thumbnails and viewer images in a concurrent PhotoService function, outside the mutation actor. Thumbnails are bounded to 256 pixels and honor orientation. No list row decodes a full original. No cache layer was added without profiling. A thumbnail failure leaves a placeholder and the original command available.
- The native scroll view supports fit, zoom, pinch, drag pan, and scrolling. Keyboard arrows select adjacent photos. Original export uses a save panel, an item replacement directory on the destination volume, and an atomic destination replacement. Missing originals show a viewer error and Retry. Export stays available after a decode failure.
- Existing reference state and link edits remain limited to Link records. Opening a saved external link remains a synchronous main-actor command. W007 navigation behavior is unchanged.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -configuration Debug CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO -resultBundlePath ~/Developer/test-assets/w010-photo-library/compile-20261002.xcresult build-for-testing`: passed. All unit and native UI test sources compiled. No tests executed.
- Review fixes: `make lint`, the unsigned Debug build, and compilation of all unit/native UI sources passed again. The second compilation bundle is `~/Developer/test-assets/w010-photo-library/compile-review-r2.xcresult`. The final message and closed-job Save-command fixes also passed lint and the Debug build; their test compilation uses `compile-review-r3.xcresult` in the same folder. No tests executed.
- After rebasing onto the brand and icon configuration in [PR #38](https://github.com/jorgerodrigues/ure/pull/38), lint, the unsigned Debug build, and all test-source compilation passed again. The bundle is `compile-rebase.xcresult` in the same folder. No tests executed.
- `git diff --check`: passed.

The sandboxed build could not write Xcode's package/module caches. The build passed with host cache access. The initial test compilation found a mutable array captured by a Sendable closure. The final compilation uses an immutable ID capture and passed. Xcode's App Intents metadata tool reports its existing no-framework extraction notice. Swift compilation keeps complete concurrency checks and warnings as errors.

## Behavioral test sources

`PhotoServiceTests` covers all owners, title/caption/stage persistence, source removal and reopen, rotated HEIC thumbnail/viewer dimensions, unchanged-byte export, mixed successes and failures, PDF rejection, count/size limits, attachment rollback, precommit and postcommit failures, closed-job protection, cover ownership, cover clearing, identity-edit preservation, link-editor kind guards, missing originals, and forward migration.

`PhotoStateTests` covers every stage filter, scope-limited keyboard selection, draft Stay/Save/Discard, failed-save retention, shared navigation guards, duplicate-import protection, cancellation, preserved earlier photos, and stale closed-job edits. Existing migration fixtures remove v9 before v8/v7. Existing W009 import/recovery test sources remain in place.

These sources compiled. Their behavior has not been executed in this story.

## Independent review and CI

Round 1 found two P0-P2 issues and two P3 issues. All four were fixed:

- Export staging now uses FileManager's item replacement directory instead of a sibling outside the save panel's granted path. [Apple documents this replacement staging API](https://developer.apple.com/documentation/foundation/filemanager/searchpathdirectory/itemreplacementdirectory).
- Image decoding moved to concurrent service work so thumbnails and originals do not occupy the coordinator's mutation queue.
- Navigation starts from the unfiltered owner order and selects the next matching stage, including after re-staging the selected photo.
- Photos now use W009's shared generic batch loop, so count/size/cancellation behavior is exercised by the existing infrastructure test sources too.

Round 2 found no P0-P2 issues. Its one P3 message mismatch was fixed by mapping unsupported photo content to the JPEG/PNG/HEIC-specific error. The driving check also made the Save menu and editor use the same closed-job guard. The stale-editor test source verifies that guard.

Round 3 reviewed the full updated branch and reported no actionable findings. No code-reading step was blocked. PR CI runs formatting/lint and an unsigned Debug build. Its current results are available in [PR #37 checks](https://github.com/jorgerodrigues/ure/pull/37/checks).

PR #38 merged during closeout. Rebasing preserved both README verification/design links. The W010 feature, persistence, and test sources did not change. The new design rules and Paper file were inspected. Paper had no W010 feature page at that time. W010 uses native controls and semantic colors; runtime visual acceptance remains pending below.

## Pending release gates

- Execute behavioral tests under W032. Keep `URE_TESTING=1` and isolated library locations.
- Manually verify file picker access, multi-file drop, individual results, cancellation, captions, stages, watch/job/caliber scope, and covers with realistic photos.
- Verify fit, zoom, pinch, pan, keyboard focus/navigation, resize, rotated HEIC, failed thumbnails, missing originals, export replacement, source deletion, and offline use on macOS 27.
- Verify VoiceOver, increased contrast, system appearances, and unsaved window/quit protection locally during release acceptance. Never run native UI automation on GitHub Actions.
- Restore unit test execution and Release builds in CI during W032. Profile realistic data in W031 before adding caches.

W009's known P3 remains: MOV/MP4/M4A originals are safely rejected but may be classified as corrupt instead of unsupported. See [file import verification](file-import-verification.md). No PDF items/viewer, bench panes, editing/annotation, camera, Photos integration, or later-feature placeholder UI was added.
