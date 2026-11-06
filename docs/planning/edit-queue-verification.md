# Edit queue verification

Recorded on 6 November 2026 for the edit queue, a structural change between W040 and W041 with no GitHub issue. On 6 November the user asked to "fix the root cause" of the save-order and Undo bugs that Codex found in every Rework story, instead of patching them one by one. The branch started at `aebd6c2` on `w002-recoverable-library`, which includes W033 to W040. The latest migration there is `v26-parts`. This change adds no migration and changes nothing on screen.

## The root cause

Before this change each of 16 autosave fields ran its own pause and its own save task, each of 12 `ChangeUndo` queues ordered only one kind of change, and about 30 `pendingWrites` and `isSaving` counters told quitting and restore whether to wait. The database ran SQL one write at a time, but each write started from its own task, so a later action could save before an earlier one, and other actions then read stored values behind the screen. Undo was registered with a field or a state object as its target, which the window's undo manager does not keep alive, and which could by then belong to another record.

## What changed

- `LibraryEdit` in `Ure/Features/Edits/LibraryEdit.swift` is a value that says what to change, one case per feature. `LibraryEditor` applies one edit through one service call, so one transaction, and returns what the library now holds and the edit that undoes it. The services now return what a row held before the change, read in the same transaction, such as `Revision<PartRecord>` from `PartService.update`.
- `EditQueue` in `Ure/Features/Edits/EditQueue.swift` is one per library session. The app submits each edit at the moment you act. Before any edit, typing on screen submits first. The queue applies one edit at a time, in that order, keeps each inverse under the change's number, and tells the states what the library holds.
- Undo and Redo register on the window's undo manager when you act, with the queue as the target and the change's number as the value. Nothing on the undo stack refers to a field, a view, a state object or a row. ⌘Z goes first to the change's owner, the field or checklist that made it, when it is still on screen. The owner puts back its own text at once and submits that through the queue, under the way back's number, so typing after ⌘Z builds on the undone text, as the old fields did. When the owner is gone, such as a deleted part's fields, ⌘Z submits the stored inverse as a new edit, which runs after everything before it. When a new action clears the Redo list, the queue and the owners let go of what they kept for those steps. Typing on a job's add line, which saves nowhere, keeps its own Undo steps on a target the queue owns.
- `AutosaveField`, `FactField` and `ChecklistEditor` only hold typing. They submit after the typing pause, when focus leaves, before any other edit, and when the app asks every field to save. Each burst of typing is still one Undo step, and so is the typing after a save that failed. Esc, the "not valid yet" rule and the last good value stay as they were.
- The checklist saves what the screen shows. Each save sends the difference between the steps on screen and what the library will hold, as operations that each name one step and only the properties that differ. A save that fails leaves the screen as it is, with Try Again, and the next save sends it too, as the whole list did before the queue. Each Undo step keeps what its action did on screen, so Undo and Redo put back the steps as they showed, and then save like any change.
- The queue reports each failure once: an action's in its scope, which is what each state's `saveError` now reads, and typing's to its field, which keeps the text with Try Again. Later edits still run in order. Try Again also runs an Undo that failed once more.
- Quit, window close, restore and backup export wait through one call, `WorkshopEditing.saveAllFields()`, which is `EditQueue.saveEverything()`. Quit and window close now wait instead of refusing while a change saves. Backup export now waits for typing and changes still saving, so the backup holds them.
- Deleted: `ChangeUndo`, every feature's own save task and `isSaving` flag, `PartChangeSide`, `PartStageUndo`, `PartUndoTarget`, `leftFacts`, `pendingWrites`, `MaterialState.pendingChanges` and `removals`, `JobFacts`' `stillWaits` wait, the picker's wait for every field before it discards a blank job, `AutosaveField.flush()` and every `discardUndo`, `saveFactsNow`, `saveAllFacts` and `hasUnsavedFacts` on the states.
- The specification's Editing row and the autosave section now describe the queue.
- `RestoreStagingTests`' file capture now resolves `/private` paths. On macOS 27.3 the enumerator gives `/private/var/...` while the temporary folder is `/var/...`, so three restore tests failed on the base branch too, before this change. That is a separate commit.

## Design rules

On 6 November, after round nine, the user asked to fix the cause of each group of findings instead of its symptom. Every finding from rounds one to nine, and the regression that the window check found, breaks one of six rules. Each rule now has one place in the code that makes it true, and one test in `UreTests/EditRuleTests.swift` that checks it in more than one way.

1. The screen is what counts. A save that fails leaves the screen as it is, the next save, Try Again or quitting sends what the library still lacks, and an older change never saves over a later one.
   - Findings: the checklist's whole-list save overwrote a waiting Undo (round one). A field kept an old failed save after a newer one saved (round one). A removed material's title still counted as unsaved (round one). A tick sent properties that it did not change (round two). A failed checklist change was lost when a later one saved (round two). A field told its saves apart by their text (round four). Typing back the saved text kept the failure (round four). Try Again submitted the typing from the wrong list (round eight). Try Again replayed an older tick over a later untick (round nine).
   - The place: `AutosaveField.submit` always sends the text on screen, and the latest submission decides. `ChecklistEditor.save` sends the difference between the screen and what the library will hold. Before this, the checklist kept a list of its failed changes and replayed them later. Each replay used a list of steps that was out of date by then, and that was the cause of the checklist findings in this group. The list is gone.
   - The test: `theScreenIsWhatSavesAfterAFailedSave`.
2. Each Undo step keeps what its own action did on screen. Undo puts back the screen as it was before the action, and Redo as it was after, whatever the library did in between. One exception stays from before the queue: a field offers no Redo of text that it does not take, such as a blank name.
   - Findings: Undo could not take back a checklist change that failed (round one). Undo of a step you had emptied showed the step twice (round two). Undo of one failed checklist change took back others (round three). Redo was lost when Undo took back text that failed to save (round five). Redo of a blank name did nothing (round six). A field's Redo took the text on screen at ⌘Z instead of the text the step saved (window check). Redo after a change made on top of a failed one did nothing (round seven). Undo of checklist typing compared the steps as they save, so a space at the end gave an Undo that did nothing (round eight). Typing that saved as nothing lost its Undo after the typing pause (round nine).
   - The place: each owner's record of its steps. `AutosaveField` keeps the text before each step and the text the step saved. `ChecklistEditor` keeps each action's change of the screen and its inverse. A change without an owner, such as an archive, uses the inverse that `LibraryEditor` reads from the stored rows in the same transaction.
   - The test: `undoAndRedoPutBackWhatTheActionDidOnScreen`.
3. An Undo or Redo is an edit like any other. It shows at once and then always saves through the queue, after every edit before it.
   - Findings: a local Undo did not finish when the save before it failed (round three). An Undo that waited for the stored inverse did not show at once, so typing after it built on the old text (round five). A field's Undo saw nothing to save because the field thought the library held its text, while the Undo of Done before it changed that (window check). Undo of a failed checklist change did not save, though a later Undo had saved that change (round seven).
   - The place: `EditQueue.reverse` asks the owner first and otherwise queues the stored inverse. Each owner's Undo always submits: `AutosaveField.submit(always:)` and `ChecklistEditor.save`.
   - The test: `undoShowsAtOnceAndSavesAfterTheEditsBeforeIt`, and the regression test for two quick ⌘Z of a state and its waiting text.
4. One action is one Undo step, registered when you act, and a later action never reuses it.
   - Findings: Esc was not an Undo step of its own (round one). Try Again of a checklist change lost its Undo step (round three). Typing after a failed save reused that save's step (round six).
   - The place: `EditQueue.submit` and `EditQueue.registerStep`, which the commands, the fields and the checklist call at the moment you act. A field registers a step at the first key of each burst of typing.
   - The test: `eachActionIsItsOwnUndoStep`.
5. The queue and the owners keep what an Undo step needs exactly as long as the undo manager holds the step.
   - Findings: a failed Undo stayed for Try Again after Redo had used it (round five). Texts and inverses stayed for steps that Undo had used up or a new action had dropped (round six). Saves that finished after their step was gone stored their inverse again (round eight).
   - The place: `EditQueue.retire` and `EditQueue.forget`, which run when Undo uses a step up, when a new action clears the Redo list, and before a restore. They tell the owners to forget the step too.
   - The test: `whatAStepNeedsGoesWithTheStep`.
6. An Undo that fails is reported like any failed edit, and Try Again runs it once more.
   - Findings: an Undo whose save failed lost its inverse (round one). Try Again in the notes did not run the notes Undo that failed (round four).
   - The place: the failure branch of `EditQueue.finish` keeps the failed Undo for its scope, and `EditQueue.retryUndo`, which every Try Again calls first, runs it.
   - The test: `anUndoThatFailsIsReportedAndCanBeTriedAgain`.

The rule tests also ran on the round nine commit, `79bbbc3`, where each finding had its own fix. Four of the six pass there. The tests of rules one and two fail. A failed tick that you then took back by hand still showed its failure and counted as unsaved. A failed tick did not save with the next change, as the checklist did before the queue. Redo of a space typed at the end of a step did nothing. Round ten of Codex had found nothing on that commit. All six pass on the rebuilt checklist.

## Executed checks

Development Mac: Apple silicon, macOS 27.3, Xcode 27.2. The SDK cache workaround `SDK_STAT_CACHE_ENABLE=NO` was passed explicitly.

| Check | Result |
| --- | --- |
| `make lint` | Passed |
| `make build` | Passed, unsigned Debug |
| `make check` | {{CHECK}} |
| `make release` | {{RELEASE}} |
| Isolated running app | {{APP}} |
| Local window checks | {{WINDOW}} |
| GitHub CI | Off since 6 November, as the user asked while the app is a prototype. The gate in its place is `make check` and `make release` on the final code |

## Tests

The existing behaviour tests were ported to the queue and all kept, except where a test checked a fake save closure's list of saved texts. Those now check the stored values in a real library, which is the behaviour they described. The field, notes and checklist editor tests now run against a real library and receive Undo results from the queue, as the screens do.

The queue tests in `UreTests/EditQueueTests.swift`:

1. `editsOfEveryKindRunInTheOrderTheyWereSubmitted` holds the library and submits seven edits of six kinds, each of which only works after the one before, such as a waiting text that needs the job to be Waiting. They finish in the order submitted and all save.
2. `undoAndRedoKeepTheOrderYouActedInWhileSavesWait` adds a part and renames it, then presses ⌘Z twice while the library is held. The rename's Undo runs first, then the addition's. Redo twice, also held, gives both back. Then the Undo steps can be forgotten, as before a restore.
3. `aFailedEditIsReportedOnceAndTheEditsAfterItStillRun` makes watch writes fail. An archive and a typed owner fail, and a caliber change and a part after them save. The failure shows once, the typed owner stays with its error, and Try Again and the next change clear it.
4. `savingEverythingWaitsAlsoForAChangeMadeWhileItWaits` starts quitting while the library is held and typing waits, adds a part after that, and checks that quitting goes ahead only once both saved.

The same file has one more test for each Codex finding below that changed code, {{QUEUETESTS}} in all.

One regression test for each bug class, in `EditQueueRegressionTests`. Each was also written against the old API and run on `aebd6c2`:

1. Typing went into the previous caliber after switching records: `typingStaysWithTheRecordItWasTypedOnAfterSwitching`. Passes on the old code, because the old bug was in the view's reuse of an AppKit field, fixed in W035. The window check below drives the real fields for it.
2. Two quick ⌘Z presses undid a job's state and its waiting text out of order: `twoQuickUndosOfAStateAndItsWaitingTextRunInOrder`, with the library held during both. Passes on the old code, which W037 patched.
3. A spare used after two typed parts took the second part's place: `aSpareUsedAfterTypedPartsKeepsItsPlace`, through the add line while the library is held. Passes on the old code, which W040 patched with one parts queue.
4. Quitting went ahead while a second change was still saving: `quittingWaitsForASecondChangeStillSaving`, two queued Undo steps of archives. Not run on the old code, because the old quit refused while a change saved instead of waiting, and its per-state flags had a gap between two queued changes that a test can't hit on purpose.
5. ⌘Z after an undone part deletion would likely crash: `undoAfterAnUndoneDeletionReachesTheTypingBeforeIt`, with no field kept alive. Passes on the old code, which W040 patched with `leftFacts`.
6. An action read a stored value behind the screen, such as Mark as Bought's stale price: `aChangeSeesWhatWasTypedJustBeforeIt`. Notes and a material title typed just before archiving a watch save before the archive, and a job being set up keeps a title typed just before a pick would discard it. **Fails on the old code**: the archive saved first, then the notes and the title failed with "This record is archived", and were left unsaved on a page that can't change.

So five of the six bug classes had been patched one by one before this change, and their tests pass on the old code. The sixth had not, and its test fails there. The queue now prevents all six in one place.

### Local window checks

This Mac gives sessions no Screen Recording or Accessibility permission. As accepted for the Rework stories on 5 November 2026, local-only tests hosted the app's real `LibraryRootView`, with every session environment and the bridged toolbar, in a window of the test host, and drove the real views. They were never committed and never run on CI. {{WINDOWRUN}}

A new check, `LocalEditQueueAppCheck`, drove the six bug cases through the real fields and the session's own commands:

1. It typed "Omega" in one caliber's maker field, switched to the second caliber before the typing pause, and typed "ETA" there. Each caliber held its own maker. ⌘Z took back "ETA" on the second caliber, and the next ⌘Z took back "Omega" on the first.
2. It set a job to Waiting, typed "a crystal" as the waiting text, and set the job to Done while the text was still being typed. With the library held, it pressed ⌘Z twice. Both ran in order once the library let go, which left the job Waiting with no waiting text and no failure. ⇧⌘Z twice gave Done back.
3. With the library held, it typed "Mainspring" and "Hairspring" on the job's add line, each with Return, and then used the spare "Crystal 30.0 mm" through "crys", the Down Arrow and Return. The stored order was Mainspring, Hairspring, Crystal 30.0 mm.
4. It renamed Mainspring to "Mainspring 1.10" and deleted the part. ⌘Z brought the part back with its new name, and the next ⌘Z reached the rename and gave back "Mainspring". ⇧⌘Z twice deleted it again with no failure.
5. It typed "Crown tube replaced." in a watch's notes and "Supplier page" as a link's title, and archived the watch before the typing pause. The notes and the title saved, the watch was archived, and nothing was left unsaved.
6. It typed a new job title, moved a part on to Fitted while the library was held, and closed the window. The window stayed open while the changes waited and closed once both had saved.

The W035 to W040 checks ran again against the queue, with their few calls that waited for a save changed to wait for the edit's ticket or for the queue. They cover the caliber, watch and job pages, the sidebar's jobs, the checklist and the parts, each as its story recorded. The renders and each check's `check-log.txt` are in `~/Developer/test-assets/jorge-edit-queue-ac6f77/`.

The limits are those of the earlier Rework records. The window ignores the mouse, so clicks were driven through what the buttons call. The test host turns off undo grouping by event, so each simulated key press opens and closes its own group. Registration is now synchronous, so a group around the call that acts is enough. VoiceOver did not run.

## Codex review

The review ran with `codex exec review --ignore-user-config`, which used Codex's default model and left `~/.codex/config.toml` unchanged. Each round read the whole diff against `aebd6c2`.

1. Round one found six things, and all were fixed. A checklist change submitted as the whole list could overwrite an Undo still waiting. An Undo whose save failed lost its inverse, so it could not be tried again. Undo could not take back a checklist change that failed to save. Esc was not an Undo step of its own. A field kept an old failed change after a newer save succeeded. A material's title that did not save stayed counted as unsaved after the material was removed.
2. Round two found three things, and all were fixed. Undo of a step you had emptied showed the step twice. A tick submitted the whole list, so it could overwrite a waiting change of another property, and checklist changes are now step operations with only the properties that changed. A failed checklist change was lost when a later one saved.
3. Round three found three things, and all were fixed. Try Again of a checklist change lost its Undo step, an Undo that waited behind a failed save did not finish, and Undo of one failed checklist change took back others.
4. Round four found three things, and all were fixed. Try Again in the notes did not run the notes Undo that failed, a field told its saves apart by their text instead of by their order, and typing back the saved text did not clear the failure.
5. Round five found three things, and all were fixed. An Undo that waited for the stored inverse did not show at once, so typing after ⌘Z built on the text before it. Fields and the checklist now put back their own text at once, as the old fields did. Also, Redo was lost when Undo took back text that failed to save, and a failed Undo stayed for Try Again after Redo had used it.
6. Round six found two things and one small thing, and all three were fixed. Typing after a save that failed reused that save's Undo step, so ⌘Z could skip it. The queue and the fields kept the texts of Undo steps that the undo manager no longer holds. Undo of text that a field does not take, such as a blank name, offered a Redo that did nothing.
7. Between rounds six and seven, the window check found a regression from round five's change. Two quick ⌘Z presses of a job's Done and its waiting text left "a crystal" as the waiting text. When the job went Done, the waiting field lost the cursor and showed the stored empty text. Its own Undo then put back "" and saw nothing to save, but the Undo of Done, which ran first, brought back "a crystal". A field's Undo now always saves through the queue, and its Redo brings back the text that the step saved. The unit test for that bug class now ends the field's editing as the window does, and it failed before the fix.
8. Round seven found two things in the checklist, and both were fixed. Undo of a tick that failed took it back only on screen, though a later Undo could have saved that tick, which left the library ticked. Such an Undo now saves what the library needs for the steps it changes. Also, Redo after the Undo of a change made on top of a failed one did nothing, because its operations came from the list with the failed change on top instead of from the screen.
9. Round eight found three things, and all were fixed. Undo of checklist typing that had not saved compared the steps as they save, so a space typed at the end, or "# " typed in the row that adds a step, gave an Undo that changed nothing. Undo now puts back the step as it showed when the typing began. Try Again on the checklist submitted the typing on screen from a list without the change that failed, so the typing's Undo also took back the retried tick. The typing now goes first, on top of the changes that did not save. Also, a save that finished after its Undo step was used up or dropped stored its inverse again. The queue now keeps no inverse for such a step. Each of the three new tests fails on the commit before the fix.
10. Round nine found two more things in the checklist, and both were fixed. Try Again replayed a tick that failed after a later untick of the same step had saved, so the library ended ticked while the screen showed the step unticked. Try Again now saves only what the screen still shows of each change that did not save. Also, typing that saved as nothing, such as a space at the end, lost its Undo once the typing pause had passed. The checklist now keeps such typing's Undo on screen too. Both new tests fail on the commit before the fix.
11. Round ten, on the round nine commit `79bbbc3`, found no defects. The user then asked to fix the cause of each group of findings instead of its symptom, so the checklist was rebuilt on the field's rules, as "Design rules" above says. That changed code after a clean round, so one more round ran on the final code.
{{CODEX}}

## Design rules that changed

Two of the brief's rules were changed as the work went on.

1. The brief said that Undo comes from the stored data. That holds when the field or checklist that made the change is gone. While it is on screen, its Undo puts back its own text at once instead. An Undo that waits for the stored inverse can't show at once, so typing after ⌘Z built on the old text, which the old fields never did (round five). The text that the owner puts back still saves through the queue, in order.
2. Checklist edits are operations on single steps instead of the whole list. A whole list submitted by one change overwrote an Undo or a change that was still waiting (rounds one and two). The operations are worked out from the screen at each save, so a failed change is never replayed from an old list.

## Remaining gates

- Native UI tests were not run, as the repository rules require during story work. They compile. W042 runs them.
- W041's options, rates and Mark as Bought are not on the queue yet. W041 is paused on its own branch. `edit-queue-handover.md` in the hand-over folder says how to add them.
