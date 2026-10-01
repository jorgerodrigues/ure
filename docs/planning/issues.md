# Watch workshop implementation issues

Version 0.3. Prepared on 1 October 2026. These are 30 implementation issue bodies. Each is intended to produce one focused PR. Product assumptions in specification section 1 must be settled before agents start the affected work. These planning IDs have not been published to an issue tracker.

Read [the specification](specification.md) first. The numbered order below is a valid dependency order. Do not start an issue before its listed dependencies are merged. Requirements that touch persistence must include schema changes, validation, service behavior, UI, and tests in the same PR. Infrastructure issues explicitly state when they have no independent UI.

## Delivery milestones

| Milestone | Issues | Useful result |
| --- | --- | --- |
| Foundation | W001 to W003 | A native app that reliably saves watches |
| Bench records | W004 to W014 | Job history, shared knowledge, files, notes, tasks, and a reference pane |
| Parts | W015 to W018 | Supplier options, procurement status, and waiting-task links |
| Overview | W019 to W023 | History, workshop view, parts overview, search, and archive |
| Recovery | W026 to W028 | User-exported backups and recoverable restore |
| Release | W029 to W032 | Verified recovery, accessibility, performance, and release journeys |

Milestones describe implementation order, not separate production releases. Do not use the app as the only copy of valuable records before Recovery and Release pass.

## Common completion rules

- Read the relevant specification sections and surrounding code before editing.
- Follow repository conventions and the user's AGENTS.md. Use Swift for this native app.
- Keep the PR within its stated boundary. Do not prebuild later features.
- Introduce forward migrations. Preserve existing data and originals.
- Implement the applicable loading, empty, failed-save, and closed-job states.
- Run focused behavioral tests, the app build, the formatter check, and configured lint checks.
- Include actual verification results and any untested gate in the PR.
- Do not add tool attribution or a coauthor footer.
- Ask whether the user wants review comments resolved after addressing them.
- Ask for clarification only when an unresolved choice changes the implementation.

## Issue index

| ID | Issue | Depends on |
| --- | --- | --- |
| W001 | ~~Create the native Mac shell and verification commands~~ (implementation done; UI checks pending) | None |
| W002 | ~~Open and migrate a recoverable SQLite library~~ (implementation done; release gates pending) | W001 |
| W003 | Create and edit watch records | W002 |
| W004 | Add the shared caliber library | W003 |
| W005 | Create job intake and watch repair history | W004 |
| W006 | Control job stages and record watch condition | W005 |
| W007 | Save scoped research and work notes | W006 |
| W008 | Store technical links with source context | W007 |
| W009 | Implement managed file import and recovery | W008 |
| W010 | Import and browse watch and job photos | W009 |
| W011 | Import and read technical PDF files | W009 |
| W012 | Keep a reference visible during bench work | W010, W011 |
| W013 | Create and update job tasks | W006 |
| W014 | Order tasks and show honest progress | W013 |
| W015 | Record required parts with saved links | W006 |
| W016 | Compare several supplier options for a part | W015 |
| W017 | Track ordering arrival and installation | W016 |
| W018 | Link waiting tasks to required parts | W014, W017 |
| W019 | Show the job activity timeline | W007, W013, W017 |
| W020 | Build the workshop overview | W014, W018, W019, W010 |
| W021 | Show parts across open jobs | W017, W020 |
| W022 | Search repair records and shared knowledge | W010, W011, W018, W020, W021 |
| W023 | Archive records and remove child items safely | W010, W011, W019, W022 |
| W026 | Export a complete library backup | W023 |
| W027 | Validate and stage library restore packages | W026 |
| W028 | Activate a restore with recovery after interruption | W027 |
| W029 | Verify recovery across upgrades imports and restore | W028 |
| W030 | Verify keyboard access and native window behavior | W023, W028 |
| W031 | Measure and fix library browsing performance | W022, W028 |
| W032 | Run first-release acceptance and write the handover guide | W029, W030, W031 |

## W001 Create the native Mac shell and verification commands

Status: Done (implementation); native UI acceptance pending. Milestone: Foundation. Target: one focused PR.

Implementation commit: `daa19a4`.

Verification: [setup-verification.md](setup-verification.md).

Dependencies: None.

Specification: sections 1, 4, 9, 12 in [specification.md](specification.md).

### Goal

Launch a native app with a reproducible build and an isolated test environment.

### Scope

- Create the SwiftUI app, shared Xcode scheme, feature folders, test target, and sandbox configuration. Target macOS 27 on Apple silicon with Xcode 27 and Swift 6.4 in Swift 6 mode. Enable Observation, complete concurrency checks, approachable concurrency, and main-actor isolation by default.
- Add the main navigation shell and Settings entry. Document build, focused test, full test, and formatter commands. Use Ure as the working name and local.ure.app for local builds. Settle an owner-controlled identifier before distribution and before storing valuable data.

### Acceptance criteria

- [ ] A fresh checkout builds and launches using the documented commands.
- [ ] The window follows the system appearance and resizes to the proposed minimum without clipped navigation.
- [x] Tests use an injected temporary library path. They cannot open the normal user library.
- [x] The shared scheme supports unsigned CI builds. No account, network service, or third-party UI package is needed.

### Verification

- Build and launch on the development Mac.
- Run the test target with an isolated library. Run the formatter check.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No domain tables, sample production content, signing secrets, release installer, or cloud setup.

## W002 Open and migrate a recoverable SQLite library

Status: Done (implementation); minimum-OS and remote CI checks pending. Milestone: Foundation. Target: one focused PR.

Implementation commit: `07bee8e`.

Verification: [library-verification.md](library-verification.md).

Dependencies: W001.

Specification: sections 5, 9, 10 in [specification.md](specification.md).

### Goal

Make startup preserve an existing library across restarts and failed migrations.

### Scope

- Add pinned GRDB, the library coordinator, the active-generation pointer, and a versioned library manifest. Provide database access, the mutation gate, ID and clock injection, and incremental migrations.
- Create the internal snapshot service used before migrations. It snapshots SQLite with the backup API and copies managed originals under the same mutation gate. Later export reuses this service.

### Acceptance criteria

- [x] First launch creates one library. Later launches reopen it without resetting data.
- [x] Foreign keys are enabled. Related changes can commit atomically. File and database work does not block the main actor.
- [x] An existing library gets a recoverable snapshot before an upgrade. A snapshot failure prevents the upgrade.
- [x] Migration failure, an unreadable database, or a newer schema produces a recovery screen. No empty replacement database is created.

### Verification

- Use on-disk fixtures for first launch, reopen, valid migration, failed migration, and a newer schema.
- Verify rollback preserves old rows and an internal snapshot opens independently.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No business schema beyond library metadata, public backup UI, or remote database abstraction.

## W003 Create and edit watch records

Status: Proposed. Milestone: Foundation. Target: one focused PR.

Dependencies: W002.

Specification: sections 3, 4, 5 in [specification.md](specification.md).

### Goal

Keep a watch record with known and unknown specifications.

### Scope

- Add the watch migration, validated save service, observed list, and detail editor.
- Implement Save, Cancel, Cmd-S, unsaved-draft navigation protection, empty states, and error preservation. Use this editing pattern for later features.

### Acceptance criteria

- [ ] A name-only watch saves and survives restart.
- [ ] Identifiers retain leading zeros and punctuation. Missing values remain absent.
- [ ] Invalid numeric dimensions are rejected with field errors. Duplicate names remain allowed.
- [ ] Editing updates the list and detail after commit. A failed write keeps the draft.

### Verification

- Round-trip a name-only watch and a fully populated watch on disk.
- Test invalid dimensions, identifiers, failed saves, and Cancel. Exercise dirty navigation in the UI.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No jobs, caliber management, archive, photo import, or customer directory.

## W004 Add the shared caliber library

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W003.

Specification: sections 1, 2, 4, 5 in [specification.md](specification.md).

### Goal

Reuse exact caliber and variant information across watches.

### Scope

- Add caliber records, their editor and list, and the watch-to-caliber relationship.
- Display shared specifications and linked watches. Add source notes for technical claims. Update watch editing to select or clear a caliber.

### Acceptance criteria

- [ ] Two watches can refer to one caliber and show its saved changes.
- [ ] Unknown specifications remain empty. Numeric values follow the spec's validation rules.
- [ ] Designation and variant remain separate. No seeded facts imply parts interchangeability.
- [ ] Clearing a watch's caliber link does not delete the caliber or affect another watch.

### Verification

- Test shared references, clearing one reference, and invalid numeric values.
- Verify search by designation within the caliber list and save failure behavior.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No automatic identification, global caliber catalog, technical files, or compatibility engine.

## W005 Create job intake and watch repair history

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W004.

Specification: sections 3, 4, 5 in [specification.md](specification.md).

### Goal

Start a repair without overwriting the watch's earlier jobs.

### Scope

- Add job records, intake editing, optional owner contact fields, and watch history.
- Capture the versioned identity and caliber snapshot on creation. Enforce the one-open-job rule with a database constraint and service validation.

### Acceptance criteria

- [ ] A new job starts at Planned and is reachable from its watch.
- [ ] The user can save a job without customer details.
- [ ] Later watch or caliber edits do not alter its intake snapshot.
- [ ] A second open job is rejected without a partial record. The UI opens the existing job instead.

### Verification

- Test snapshot preservation after watch and caliber changes.
- Test two attempts to create an open job and verify only one commits. Verify restart and cancelled intake.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No customer directory, report generation, tasks, or automatic job templates.

## W006 Control job stages and record watch condition

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W005.

Specification: sections 5, 6 in [specification.md](specification.md).

### Goal

Change workflow stage and physical condition independently with a useful history.

### Scope

- Add the job transition service, condition controls, closure and reopen actions, and ActivityEvent storage.
- Require waiting, cancellation, and closure fields defined by the spec. Add the shared open-job edit guard. Task and part closure summaries are extended by their later issues.

### Acceptance criteria

- [ ] Setting Waiting requires a reason and does not change watch condition.
- [ ] Complete requires an outcome. Cancel requires a reason. Closing disables operational edits through both service and UI.
- [ ] Reopen checks for another open job. Previous transitions remain in history.
- [ ] Each successful job or condition change commits its event with the state update. Failure commits neither.

### Verification

- Test every allowed transition and required-field failure.
- Test transactional event rollback, repeated pending actions, and reopening when another job is open.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No timeline UI yet, automatic stage transitions, or claims that Ready means tasks are complete.

## W007 Save scoped research and work notes

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W006.

Specification: sections 3, 5, 6 in [specification.md](specification.md).

### Goal

Record findings at the job, watch, or caliber level.

### Scope

- Add note persistence, exactly-one-owner validation, note lists, and plain-text editing.
- Support Observation, Research, Work log, and Measurement kinds. Keep occurred date distinct from created and updated times.

### Acceptance criteria

- [ ] A note appears only in its own scope unless explicitly shown in a shared-reference view.
- [ ] Editing text preserves the occurred date unless the user changes it.
- [ ] Job notes cannot be edited after closure until the job is reopened.
- [ ] Long and Unicode text survives restart. Save errors keep the draft.

### Verification

- Test all owner types and reject zero or several owners.
- Test date preservation, closed-job writes, long text, and draft cancellation.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No rich text, OCR, automatic summarization, or structured instrument measurements.

## W008 Store technical links with source context

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W007.

Specification: sections 3, 5, 7 in [specification.md](specification.md).

### Goal

Collect technical references without losing where they came from.

### Scope

- Add LibraryItem with scoped ownership and Link kind. Provide title, source URL, source description, and notes editing.
- Show job, watch, and caliber reference sections with clear scope labels. Open links through the default browser after a user action.

### Acceptance criteria

- [ ] Several links can be stored for each scope and survive restart.
- [ ] Only HTTP and HTTPS URLs are accepted. Invalid input keeps the draft.
- [ ] The UI labels a link as an external reference. It does not claim that its content is saved offline.
- [ ] A closed job cannot gain or edit job-owned references until reopened.

### Verification

- Test URL parsing and forbidden schemes, ownership, and closed-job writes.
- Use a browser-opening test double to confirm that no link opens during loading or saving.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No scraping, automatic downloads, link previews, or embedded browser.

## W009 Implement managed file import and recovery

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W008.

Specification: sections 5, 7, 9, 10 in [specification.md](specification.md).

### Goal

Store complete immutable originals without depending on their source location.

### Scope

- Add FileAsset, generated relative keys, staged import, detected types, hash and size metadata, and abandoned-import cleanup.
- Support the documented image and PDF formats through a service API. Coordinate with the library mutation gate and internal snapshots. This is an internal infrastructure PR.

### Acceptance criteria

- [ ] Import preserves original bytes and cannot write outside the managed library.
- [ ] A committed asset always has a complete original. A failed database commit does not leave a visible broken item.
- [ ] Unsupported, oversized, or corrupt files return per-file errors. Cancel and disk-full behavior preserve existing assets.
- [ ] Startup cleanup checks references before deleting abandoned imports. An active import cannot be mistaken for abandoned data.

### Verification

- Use real JPEG, PNG, HEIC, and PDF fixtures plus corrupt files and hostile filenames.
- Inject failures before and after file rename and database commit. Reopen the library and inspect consistency.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No gallery, thumbnail UI, automatic duplicate merging, or arbitrary document formats.

## W010 Import and browse watch and job photos

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W009.

Specification: sections 4, 5, 7 in [specification.md](specification.md).

### Goal

Use local photos during repair and preserve their context.

### Scope

- Add file-picker and file-drop photo import for each supported owner. Add stage labels, captions, thumbnails, cover selection, and the image viewer.
- Support fit, zoom, pan, keyboard navigation, and original export. Decode thumbnails off the main actor and respect orientation.

### Acceptance criteria

- [ ] Photos remain viewable after the source files are moved and networking is disabled.
- [ ] Before, During, After, and Unclassified filters show the right items.
- [ ] A rotated HEIC displays correctly. A failed thumbnail has a placeholder and does not hide a valid original.
- [ ] A watch cover can reference its own or one of its jobs' photos. Mixed batches show individual failures and retain successful imports.

### Verification

- Test scope, cover ownership, stage filtering, and mixed batch outcomes.
- Manually verify zoom, pan, keyboard navigation, rotation, and offline use with realistic images.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No image editing, annotation, direct camera access, or Photos library integration.

## W011 Import and read technical PDF files

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W009.

Specification: sections 4, 5, 7 in [specification.md](specification.md).

### Goal

Keep technical sheets available without a network connection.

### Scope

- Add PDF import to reference sections and allow an optional source URL on the document item.
- Integrate PDFKit for page navigation and zoom. Add original export and useful invalid-file errors.

### Acceptance criteria

- [ ] A multi-page PDF opens after its source file has been removed.
- [ ] Imported documents keep their scope and source information.
- [ ] A corrupt or unsupported protected PDF produces a useful error without a crash or lost draft.
- [ ] Documents and links remain visually distinct. Imported PDF content is available offline.

### Verification

- Use multi-page, corrupt, and password-protected fixtures. Define protected PDFs as unsupported in this release.
- Verify page navigation, zoom, original byte preservation, and offline reading.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No PDF annotation, form filling, full-document search, or automatic URL download.

## W012 Keep a reference visible during bench work

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W010, W011.

Specification: sections 3, 4, 7 in [specification.md](specification.md).

### Goal

Read a photo or technical sheet while editing another section of a job.

### Scope

- Add a collapsible reference pane and a read-only reference window.
- Allow pinning accessible job, watch, or caliber items. Persist the last selected job and valid reference preference.

### Acceptance criteria

- [ ] Switching between job sections keeps the pinned reference visible.
- [ ] Switching jobs clears an unrelated pin and preserves an applicable watch or caliber reference.
- [ ] The pane collapses at narrow widths without hiding the main editing controls.
- [ ] A removed or unavailable item clears the pin safely. A reference window cannot issue data mutations.

### Verification

- Exercise section switching, different watches, shared calibers, and missing items.
- Verify resizing at the specified minimum, restart preference restoration, and unsaved draft behavior.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No multi-item canvas, annotation tools, or second editing window.

## W013 Create and update job tasks

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W006.

Specification: sections 3, 5, 6 in [specification.md](specification.md).

### Goal

Track each planned piece of work with explicit status.

### Scope

- Add task persistence, validation, editor, and list. Implement To do, Doing, Waiting, Done, and Skipped.
- Enforce the closed-job guard. Add task state events and extend the job completion summary with unfinished tasks.

### Acceptance criteria

- [ ] Tasks save with title, optional detail, group label, and status.
- [ ] Waiting requires a reason until part links are available. Skipped always requires a reason.
- [ ] Completing and reopening a task records a committed event. The job stage stays unchanged.
- [ ] Closing a job with unfinished tasks requires an explanation and preserves their statuses.

### Verification

- Test state changes, reason validation, transactional events, and attempts to edit closed jobs.
- Verify duplicate pending clicks and failed saves do not create extra records.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No subtasks, due dates, estimates, templates, or part links.

## W014 Order tasks and show honest progress

Status: Proposed. Milestone: Bench records. Target: one focused PR.

Dependencies: W013.

Specification: sections 4, 6 in [specification.md](specification.md).

### Goal

See work in bench order and understand how much of the task list is complete.

### Scope

- Add persisted task ordering, optional group display, drag reordering, and keyboard Move up and Move down actions.
- Add the shared progress calculation and display counts and percentage in the job header. Expose it for the workshop overview.

### Acceptance criteria

- [ ] Reordering survives restart and never changes task status.
- [ ] Progress uses Done divided by all non-Skipped tasks. Skipped count stays visible.
- [ ] Zero counted tasks shows No tasks planned. Adding or reopening a task updates the result.
- [ ] A completed job with unfinished work can show less than 100 percent. The app never fabricates completion.

### Verification

- Test empty, all-skipped, mixed, added, and reopened task lists.
- Test persisted ordering after several moves and a failed write. Verify keyboard alternatives.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No time-based estimates, weighted progress, or automatic job stage changes.

## W015 Record required parts with saved links

Status: Proposed. Milestone: Parts. Target: one focused PR.

Dependencies: W006.

Specification: sections 3, 5 in [specification.md](specification.md).

### Goal

Keep an exact list of what each repair needs.

### Scope

- Add part requirements, the job parts list, and editing for description, quantity, manufacturer reference, and compatibility assessment. Add PartLink records and an Add link control during part creation and editing.
- Use one line per separately tracked unit or lot. Add the shared part status type, initially Needed. Later procurement actions extend it.

### Acceptance criteria

- [ ] Description and a positive whole quantity are required.
- [ ] Manufacturer references retain leading zeros. An unknown reference is allowed.
- [ ] The user can save a URL without supplier metadata or a manufacturer reference. Each part can have zero, one, or several links with explicit Open actions.
- [ ] Part requirements cannot be edited on closed jobs.
- [ ] Confirmed compatibility requires an evidence note. Unsuitable and Unchecked remain distinguishable.

### Verification

- Test quantity validation, reference round-trip, evidence requirements, and job ownership. Save a part with a URL, add a second link, restart, and verify both are retained.
- Verify draft retention and the empty parts state. Reject invalid URL schemes. Confirm that links open only after a user action.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No shared stock, replacement recommendations, supplier comparison, or receipt tracking yet.

## W016 Compare several supplier options for a part

Status: Proposed. Milestone: Parts. Target: one focused PR.

Dependencies: W015.

Specification: sections 5 in [specification.md](specification.md).

### Goal

Keep alternate sources without mixing supplier codes with manufacturer numbers.

### Scope

- Extend the existing PartLink records with optional supplier name, listing title, stock code, price and currency, and notes. Reuse the URLs introduced by W015.
- Allow choosing one supplier option for a part. Preserve simple product or identification links that have no supplier metadata. Open websites only through an explicit user action.

### Acceptance criteria

- [ ] A part can retain several options and one selection.
- [ ] Supplier stock code does not replace the manufacturer's reference.
- [ ] Price is stored exactly with a currency. A price without currency or an invalid URL is rejected.
- [ ] Removing the selected option clears the selection and preserves the part. Closed-job edits are rejected.
- [ ] Existing links survive the migration unchanged. Adding supplier details never creates a duplicate link record.

### Verification

- Test multiple options, valid ownership of the selected option, exact decimal persistence, and removal.
- Test invalid schemes, invalid currencies, and browser opening only after a click.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No price scraping, currency conversion, supplier accounts, or purchasing.

## W017 Track ordering arrival and installation

Status: Proposed. Milestone: Parts. Target: one focused PR.

Dependencies: W016.

Specification: sections 5, 6 in [specification.md](specification.md).

### Goal

See whether a required part has been ordered, received, or fitted.

### Scope

- Implement Needed, Ordered, Arrived, Installed, and Cancelled actions with milestone dates and transition events.
- Snapshot the selected supplier when ordering, allow an optional order reference, and extend the job closure summary with unresolved procurement.

### Acceptance criteria

- [ ] A part already on hand can start at Arrived. Installed remains separate.
- [ ] Ordering preserves the selected supplier details even if the option is edited later.
- [ ] Backward corrections and cancellation require a reason. Events preserve prior milestones.
- [ ] A direct installation confirms availability and records arrival and installation together. A lot is never displayed as partly received.
- [ ] Job completion with Needed or Ordered parts requires an explanation and leaves them unchanged.

### Verification

- Use a fixed clock for allowed transitions, corrections, and milestone cleanup.
- Test supplier snapshot immutability, event rollback, closed-job guards, and repeated pending actions.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No partial deliveries, order API integration, returns accounting, or automatic task completion.

## W018 Link waiting tasks to required parts

Status: Proposed. Milestone: Parts. Target: one focused PR.

Dependencies: W014, W017.

Specification: sections 5, 6 in [specification.md](specification.md).

### Goal

Explain what is blocking a task and show when its parts are available.

### Scope

- Add TaskPart links, same-job validation, part selection from task editing, and derived availability labels.
- Allow a waiting task to use unresolved parts as its reason. Recalculate labels after procurement changes.

### Acceptance criteria

- [ ] A task may link to several parts from its own job only.
- [ ] Needed and Ordered mean unresolved. Arrived and Installed mean available. Cancelled shows Needs review.
- [ ] When all linked parts arrive, the label changes to Parts available. The task remains Waiting.
- [ ] Removing the last unresolved link from a waiting task requires a reason or a chosen new status.

### Verification

- Test several parts, cross-job rejection, cancellation, and unlinking.
- Verify label refresh after a part save and confirm no automatic task or job transition.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No automatic scheduling, general dependency graph, or stock allocation.

## W019 Show the job activity timeline

Status: Proposed. Milestone: Overview. Target: one focused PR.

Dependencies: W007, W013, W017.

Specification: sections 4, 5, 6 in [specification.md](specification.md).

### Goal

Review what changed and what was learned during a repair.

### Scope

- Combine committed activity events and job notes in one dated timeline.
- Display prior and new values in plain language. Link entries to surviving source records. Handle removed child records through retained event summaries.

### Acceptance criteria

- [ ] Job, condition, task completion, and procurement transitions appear once.
- [ ] Notes use their occurred dates and are not copied into event rows.
- [ ] Equal timestamps have stable order. Editing a note does not create a duplicate timeline event.
- [ ] The timeline remains useful when a task is later removed. It does not claim to be a complete audit log.

### Verification

- Test stable ordering, note edits, deleted source records, and transaction rollback.
- Verify long event descriptions and navigation to source records.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No global audit system, immutable note revisions, or sync event stream.

## W020 Build the workshop overview

Status: Proposed. Milestone: Overview. Target: one focused PR.

Dependencies: W014, W018, W019, W010.

Specification: sections 3, 4, 6 in [specification.md](specification.md).

### Goal

See active work, waiting reasons, and unfinished work in one place.

### Scope

- Add observed open-job queries and Workshop groups for Planned, In progress, Waiting, and Ready.
- Show watch and job labels, available thumbnail, progress, waiting reason, and unresolved part count. Add text and stage filters.

### Acceptance criteria

- [ ] An update to a task, part, or job refreshes the relevant row after commit.
- [ ] Closed jobs leave the open view and remain in watch history.
- [ ] The default ordering is most recently updated. Filters do not hide the selected record without a clear empty state.
- [ ] Opening a row selects the correct watch and job. No duplicate rows arise from joining tasks and parts.

### Verification

- Test aggregation with several tasks and parts, zero tasks, and all job stages.
- Verify live updates, filters, navigation, and empty results.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No charts, revenue metrics, deadline scheduling, or drag-based job transitions.

## W021 Show parts across open jobs

Status: Proposed. Milestone: Overview. Target: one focused PR.

Dependencies: W017, W020.

Specification: sections 4 in [specification.md](specification.md).

### Goal

See what needs buying and what has arrived without opening each repair.

### Scope

- Add the global Parts section and status filters with watch and job context.
- Provide navigation to the part in its job. Use the existing services for any exposed status action.

### Acceptance criteria

- [ ] The default view contains parts from open jobs only.
- [ ] Every row identifies its watch and job. Status filters return exact matching records.
- [ ] A procurement change updates this view and the job's list consistently.
- [ ] No supplier link opens merely by selecting a row.

### Verification

- Test several watches with similar part descriptions and different stages.
- Verify correct navigation and committed updates across both views.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No purchasing dashboard, bulk orders, stock quantities, or customer totals.

## W022 Search repair records and shared knowledge

Status: Proposed. Milestone: Overview. Target: one focused PR.

Dependencies: W010, W011, W018, W020, W021.

Specification: sections 11 in [specification.md](specification.md).

### Goal

Find a watch, finding, reference, or part from its text or identifiers.

### Scope

- Add the defined normalized search fields, global grouped search, local list filters, and exact-result navigation.
- Update normalization in write transactions. Add archive-aware queries for the later archive UI.

### Acceptance criteria

- [ ] Search covers every field listed in specification section 11.
- [ ] Case-insensitive Unicode text works consistently. Leading zeros and punctuation in references remain searchable.
- [ ] Results show record kind and watch or job context. Selecting one opens the exact result.
- [ ] An edit or removal updates search. Archived content is excluded unless the filter is enabled.

### Verification

- Test Unicode, punctuation, quotes, duplicate labels, no matches, and special SQL characters.
- Test search-key refresh and result navigation. Confirm PDFs and images are not falsely advertised as text-indexed.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No OCR, PDF text indexing, online search, fuzzy matching, or new search engine.

## W023 Archive records and remove child items safely

Status: Proposed. Milestone: Overview. Target: one focused PR.

Dependencies: W010, W011, W019, W022.

Specification: sections 10, 11 in [specification.md](specification.md).

### Goal

Keep normal views clear while preserving repair history and file consistency.

### Scope

- Add archive and unarchive actions for watches and calibers, the Archive section, and the archive search filter.
- Finish child-item removal for tasks, supplier options, notes, and library items. Coordinate cover references, open viewers, search keys, and unreferenced asset cleanup.

### Acceptance criteria

- [ ] A watch with an open job cannot be archived. Unarchive restores list visibility without changing history.
- [ ] An archived caliber remains usable through existing watch links.
- [ ] Child removal shows a confirmation and clears dependent selections safely. Part requirements are cancelled rather than deleted.
- [ ] Database removal commits before unreferenced files are removed. Failed cleanup is retried safely.
- [ ] Archived or closed-job content obeys the closed-job edit guard. No top-level watch or job deletion is exposed.

### Verification

- Test archive restrictions, search inclusion, and existing caliber links.
- Test removal of a pinned photo or cover, retained activity summaries, cleanup failure, and restart.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No permanent watch deletion, data-retention policy, tombstones for future sync, or trash with expiry.

## W026 Export a complete library backup

Status: Proposed. Milestone: Recovery. Target: one focused PR.

Dependencies: W023.

Specification: sections 9, 10 in [specification.md](specification.md).

### Goal

Make a portable copy of all records and originals.

### Scope

- Expose the W002 snapshot service through Settings with a .watchbackup package and versioned manifest.
- Include the SQLite snapshot, all referenced photo and technical PDF originals, hashes, counts, and export metadata. Add progress, cancellation, and last-successful-export information.

### Acceptance criteria

- [ ] Mutations and imports pause while the snapshot and files are copied. Reading remains available.
- [ ] The package contains every referenced file and no required cache data.
- [ ] A staged export is published only after validation. An existing destination is not damaged by a failed or cancelled export.
- [ ] The database snapshot contains recent committed writes, including those still represented in WAL.
- [ ] The UI reports success only after the whole package has been written and checked.

### Verification

- Open the exported database independently and compare referenced hashes and counts.
- Test a queued concurrent mutation, cancellation, disk-full behavior, existing target protection, and a missing original.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No cloud upload, scheduled backup, archive compression dependency, or promise that a local copy protects against device loss.

## W027 Validate and stage library restore packages

Status: Proposed. Milestone: Recovery. Target: one focused PR.

Dependencies: W026.

Specification: sections 10 in [specification.md](specification.md).

### Goal

Reject damaged backups before they can affect the current library.

### Scope

- Add restore manifest parsing, safe path validation, file hash checks, database integrity and relationship checks, and supported staging migrations.
- Return a validated staging generation and a summary for the activation step. This is an internal infrastructure PR.

### Acceptance criteria

- [ ] A valid backup stages independently of the current library.
- [ ] A missing asset, wrong hash, invalid foreign key, unsupported version, traversal path, or symlink rejects the package.
- [ ] Malformed input cannot cause a write outside staging. Enforce declared-size and available-disk checks during copying.
- [ ] A failed staging migration leaves the active library unchanged.
- [ ] Validation errors identify the failed item without exposing or modifying unrelated files.

### Verification

- Use valid, older-version, future-version, corrupt, truncated, traversal, and symlink package fixtures.
- Verify the active database and originals remain byte-for-byte unchanged after each rejection.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No active-library switch, merge import, or visible Restore action before W028.

## W028 Activate a restore with recovery after interruption

Status: Proposed. Milestone: Recovery. Target: one focused PR.

Dependencies: W027.

Specification: sections 9, 10 in [specification.md](specification.md).

### Goal

Replace the library only after review and keep a complete recovery path.

### Scope

- Add Restore in Settings with validated summary, replacement consequence, and explicit confirmation.
- Make a current-library recovery snapshot, drain operations, close database readers and writers, atomically switch the active pointer, and reload all feature state. Retain the old generation until the new one opens successfully.

### Acceptance criteria

- [ ] Cancelling before confirmation does not change the current library.
- [ ] Failure to create the recovery snapshot prevents the switch.
- [ ] All screens and reference windows reload or close after activation. No write can reach the old generation afterward.
- [ ] A process interruption around the pointer switch reopens either complete library. A failed new-generation open restores the retained generation.
- [ ] The user sees a useful outcome and can find the recovery copy.

### Verification

- Inject interruption before and after the pointer switch and on first open.
- Test restore with unsaved drafts, open references, a queued write, insufficient disk space, and rollback failure handling.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No record merge, several active libraries, or automatic sync.

## W029 Verify recovery across upgrades imports and restore

Status: Proposed. Milestone: Release. Target: one focused PR.

Dependencies: W028.

Specification: sections 7, 9, 10, 12 in [specification.md](specification.md).

### Goal

Prove that the complete storage system preserves a usable library at its failure boundaries.

### Scope

- Add a small process-level integration harness for forced interruption during file import, backup, schema upgrade, and restore.
- Test upgrades from retained earlier schema fixtures with records, originals, and technical PDF files. Fix only failures found by these scenarios.

### Acceptance criteria

- [ ] Relaunch never silently replaces a damaged library with an empty one.
- [ ] Every visible file item points to a complete original after recovery.
- [ ] Interrupted exports do not appear as successful backups. Interrupted restores retain a complete generation.
- [ ] Re-running migrations or cleanup is safe and does not duplicate data.
- [ ] Failures already covered by unit tests remain tested at the actual file and process boundary.

### Verification

- Run the documented interruption matrix using isolated libraries.
- Compare record counts, stable IDs, original hashes, and technical PDF bytes before and after recovery.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No generic chaos-testing platform or broad refactoring unrelated to a reproduced failure.

## W030 Verify keyboard access and native window behavior

Status: Proposed. Milestone: Release. Target: one focused PR.

Dependencies: W023, W028.

Specification: sections 4, 11, 12 in [specification.md](specification.md).

### Goal

Complete the bench workflow comfortably with standard Mac input and accessibility.

### Scope

- Audit all implemented screens for keyboard focus, native menu actions, VoiceOver labels, contrast, and unsaved-draft handling.
- Fix verified gaps in resizing, light and dark appearance, reduced motion, and the read-only reference window. Accessibility remains required within earlier issues too.

### Acceptance criteria

- [ ] The primary create, edit, task, parts, reference, backup, and restore flows work without a pointing device.
- [ ] Every status has a text label. Task progress is understandable through VoiceOver.
- [ ] The minimum window has no inaccessible controls or clipped save actions.
- [ ] Save, Discard, and Stay work for navigation, window close, and quit. A failed save keeps the draft.
- [ ] Selecting and editing records with long names or large text does not break focus.

### Verification

- Run a keyboard journey and a VoiceOver pass on the development Mac.
- Inspect both appearances and minimum and large window sizes. Capture evidence under the user's test-assets path only when needed.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No custom design system, decorative animation project, or visual redesign.

## W031 Measure and fix library browsing performance

Status: Proposed. Milestone: Release. Target: one focused PR.

Dependencies: W022, W028.

Specification: sections 12 in [specification.md](specification.md).

### Goal

Keep a realistic library responsive while viewing large originals.

### Scope

- Create the synthetic dataset specified in section 12 and record hardware, build mode, launch, search, list, and thumbnail timings.
- Fix measured bottlenecks with scoped query, indexing, paging, or image decoding changes. Add a focused regression check for each actual fix.

### Acceptance criteria

- [ ] The recorded warm list and search target is under 300 ms on the documented development Mac.
- [ ] The recorded initial usable-window target is under 3 seconds.
- [ ] Opening or scrolling photos does not load all originals or block task input.
- [ ] Search and overview counts stay correct after optimization.
- [ ] Any target still missed is reported with measured values rather than marked passed.

### Verification

- Measure before and after each optimization using the same fixture and build mode.
- Re-run affected behavioral tests. Observe memory while repeatedly opening and closing large images.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No speculative cache layers, server services, or performance claim based on an empty library.

## W032 Run first-release acceptance and write the handover guide

Status: Proposed. Milestone: Release. Target: one focused PR.

Dependencies: W029, W030, W031.

Specification: sections 12, 13 in [specification.md](specification.md).

### Goal

Deliver a verified local app that the user can run and recover.

### Scope

- Run the complete first-release journeys against a fresh library and an upgraded fixture. Record actual results and unresolved gates.
- Write concise instructions for local build and launch, entering a repair, locating the library, and exporting and restoring backups. Commit the accepted specification and issue links in the repository.

### Acceptance criteria

- [ ] All defined journeys have evidence. Any missing minimum-OS test is listed as pending.
- [ ] The app works offline for saved records and imported files.
- [ ] A fresh checkout can build and run using the guide, without private credentials embedded in the repository.
- [ ] The user can restore a backup into an isolated library and verify the restored records and originals.
- [ ] No release is called complete while a failing required check or untested required OS gate is hidden.

### Verification

- Run the documented build, test, formatter, and configured lint commands.
- Run the acceptance checklist on the development OS and minimum OS. Review backup and restore instructions against actual behavior.
- Run the common completion checks in the issue catalog. Report what actually ran.

### Outside this issue

No App Store submission, notarization account changes, automatic updater, or cloud backend.
