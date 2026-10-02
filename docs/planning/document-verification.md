# W011 technical PDF verification

Implemented on 2 October 2026 for [W011 (#9)](https://github.com/jorgerodrigues/ure/issues/9), in [PR #39](https://github.com/jorgerodrigues/ure/pull/39). W009 is closed with [PR #36](https://github.com/jorgerodrigues/ure/pull/36) merged at `f27d6eed6f2eb1f1ba19cabd2785942e38950463`. W010 is closed with [PR #37](https://github.com/jorgerodrigues/ure/pull/37) merged at `e98ba0937282a8743d79f6070facb2b1009780a5`.

## Scope and behavior

- Documents are distinct LibraryItems owned by one watch, job, or caliber. Their reference rows show PDF and offline availability. Link rows retain their external-reference label and synchronous, explicit browser command.
- PDF picker and file drop use the shared import loop and approved 100,000,000 byte original and 200-file limits. Each file reports its own result. Complete successful imports survive failed or cancelled siblings.
- W011 validates the staged original as an unprotected PDF. It rejects both password-required and owner-restricted PDFs. The W009 infrastructure's empty-password policy remains unchanged for its internal API.
- The coordinator publishes complete original bytes before committing the asset and document in one transaction. The existing rollback and recovery gate covers attachment failures. Export uses the coordinator's atomic replacement path and never rewrites the PDF.
- The v10 forward migration replaces the item table under GRDB's deferred foreign-key checks. It preserves existing photo/link rows and watch cover IDs, then checks foreign keys before commit. The watch-cover triggers are restored. Earlier migration fixtures remove v10 before v9/v8/v7.
- The document editor saves title, optional HTTP/HTTPS source URL, source description, and notes. It uses Save, Cancel, Command-S, and the shared navigation/window/quit draft guard. Failed saves keep the draft. Closed-job imports and edits are disabled in UI and rejected by the service, including stale drafts.
- The coordinator reads managed PDF bytes on its dedicated actor. A concurrent service function loads PDFKit and validates pages before transferring the document to the main actor with Swift's `sending` ownership transfer. The reader uses native PDFView page navigation, fit, zoom, and scrolling. Widget annotations are read-only and markup mode is off. Retry and original export remain available after reader errors where possible.
- No annotation tools, form editing, content search, automatic downloads, bench panes, or future-feature placeholders were added. W007 behavior is unchanged.

## Design inspection

The live Paper file had Brand, Logo, macOS 27, Watches · W003, and Page 1 pages. No W011 feature page existed. The macOS 27 rules artboard's JSX and computed styles were read. This implementation uses the established reference section, system text styles, native controls, and semantic colors. It adds no content glass or toolbar background. Runtime visual acceptance remains pending.

## Checks actually run

- `make lint`: passed.
- `make build XCODE_EXTRA_FLAGS=SDK_STAT_CACHE_ENABLE=NO`: unsigned Debug build passed.
- `xcodebuild -project Ure.xcodeproj -scheme Ure -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO SDK_STAT_CACHE_ENABLE=NO build-for-testing`: passed. All unit and native UI test sources compiled. No tests executed.
- `git diff --check`: passed.

The final compilation also wrote `~/Developer/test-assets/w011-technical-pdfs/compile-final.xcresult` under the test-assets skill. It compiled all unit/native UI sources without execution. Remove the branch asset folder after merge.

The initial test compilation found an async-context Thread API assertion and one missing document-state fixture injection. Both were corrected. Xcode retains its existing App Intents no-framework extraction notice. Swift compilation retains complete concurrency checks and warnings as errors.

## Behavioral test sources

DocumentServiceTests covers three-page originals with misleading extensions, every scope, saved source context, source deletion and reopen, unchanged-byte export and replacement, mixed success/corrupt/protected/photo results, import limits, precommit/postcommit failures, attachment rollback, closed-job writes, wrong owner/kind, invalid source URLs, missing/corrupt/protected managed content, and v9-to-v10 cover/link/photo preservation.

DocumentStateTests covers scope selection, explicit source opening with an injected browser, failed drafts, Stay/Save/Discard, pending imports, duplicate prevention, cancellation, and closed-job save rejection. DocumentReaderStateTests covers page bounds, zoom clamps, Fit, and unavailable-file state.

These sources compiled. Their behavior has not been executed in this story.

## Pending release gates

- Execute behavioral and reader tests during W032 with isolated libraries and `URE_TESTING=1`.
- Verify multi-page PDFs after source deletion and with networking disabled. Check page controls, keyboard arrows, scrolling, pinch zoom, Fit, resize, original export and replacement, and retry with missing or invalid content on macOS 27.
- Verify system picker and drag/drop access, mixed batches, cancellation, per-file errors, saved source context, and closed-job controls.
- Verify read-only PDF widgets, absent annotation/search tools, light/dark appearance, increased contrast, VoiceOver, focus, and unsaved window/quit guards locally during release acceptance. Native UI automation never runs on GitHub Actions.
- Restore CI unit execution and Release builds in W032. No Release build or app tests ran here. Profile realistic documents during W031 before adding caches.

## Independent review and CI

The independent read-only review inspected the full branch diff and added files. Round 1 reported: No findings cleared the bar. No blocked code access was reported. One aggregate Bash read was denied; the review completed with the available read tools. PR CI runs formatting/lint and the unsigned Debug build. Current results are in [PR #39 checks](https://github.com/jorgerodrigues/ure/pull/39/checks).

Automatic approval review first rejected the Claude.ai source transfer on 2 October 2026 because it did not accept the authorization carried in the handoff. The user then directly approved the transfer in this chat and asked for the approval to be saved in the repository. See [independent review approval](review-approval.md).
