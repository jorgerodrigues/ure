# Watch workshop planning package

This package defines a proposed first release of a native Mac app for watch repair and restoration. Version 0.3 includes a complete draft specification and 30 issue bodies for implementation. PDF report creation is deferred. Every part can retain one or more optional links.

## Start here

1. Read [specification.md](specification.md).
2. Settle the open product choices below.
3. Use /Users/jorge/Developer/ure/ as the implementation workspace. Its planning files live in docs/planning/.
4. Publish the approved issue bodies from [issues/](issues/) to its tracker.
5. Implement in the dependency order in [issues.md](issues.md).

The editable copies are [the specification](https://chatgpt.com/space/page_d041f67b87088191a77ed87354b407d5) and [the implementation issues](https://chatgpt.com/space/page_272e78f292b081918424c43beead1c17). These files started as a snapshot dated 1 October 2026. Local setup updates include the approved current-platform direction. The linked Pages and these local files do not update each other automatically. Use the local files for implementation.

## Open choices

| Choice | Draft default |
| --- | --- |
| Repair history | Separate jobs for a watch, with at most one open job |
| Shared knowledge | Reusable caliber records and references |

Other proposed defaults are listed in specification section 1. They include optional owner details, explicit Save actions, and written measurement notes. The approved platform is macOS 27 on Apple silicon, using Xcode 27, Swift 6.4, and SwiftUI Observation. The user approved W002's SQLite/GRDB storage design on 1 October 2026. The working name is Ure. Git is initialized. No remote is configured. No GitHub or Linear issues have been published. The W001 app foundation and W002 recoverable library are implemented locally. Their checks are recorded in [setup-verification.md](setup-verification.md) and [library-verification.md](library-verification.md).

## Package contents

| File | Purpose |
| --- | --- |
| specification.md | Product behavior, screens, model, architecture, data safety, and acceptance |
| issues.md | Milestones, common completion rules, dependency index, and all issue bodies |
| issues/W*.md | The 30 individual issue bodies |
| issues.json | Structured issue data and full bodies for a later tracker import |
| setup-verification.md | W001 checks and remaining native UI acceptance |
| library-verification.md | W002 checks and remaining release gates |
| README.md | This guide and handover prompt |

## Requirement coverage

| Requirement | Main issues |
| --- | --- |
| Watch identity and specifications | W003, W004, W005 |
| Technical links and shared research | W004, W007, W008 |
| Local photos and PDFs | W009, W010, W011 |
| Bench reference view | W012 |
| Tasks and visible progress | W013, W014 |
| Watch condition and job stage | W006, W019 |
| Parts and multiple supplier links | W015, W016, W017 |
| Waiting on parts | W018 |
| Work overview and search | W020, W021, W022 |
| Archive and removal | W023 |
| Customer information kept in the job | W005, W007 |
| Backup and restore | W002, W026, W027, W028, W029 |
| Native usability and acceptance | W001, W030, W031, W032 |
| Future sync preparation | W002, W009 and specification section 9 |

## Agent handover prompt

Replace W013 with the selected issue ID.

> Implement W013 from this planning package in the selected repository. Read the accepted specification, the issue body, and the common completion rules first. Confirm that dependency issues are merged. Inspect the repository's instructions and surrounding code. Implement the issue through every affected layer. Keep later features outside the PR. Run focused behavioral checks and the repository's build, formatting, and configured lint commands. Report what changed, what ran, and any unresolved gate. Do not treat unconfirmed product defaults as approved.

## Planning checks

The package contains 30 unique issues. Every dependency points to an earlier issue. Each issue includes scope, acceptance criteria, validation, and exclusions. Each user requirement maps to one or more issues. Existing issue IDs are stable.

The saved Page text was read back and compared with the authored content. Rendered Page layout has not been visually inspected. The W001 shell and W002 recoverable library are implemented locally. Their actual build and test results are recorded separately. Watch records, repair behavior, and full release checks remain future acceptance criteria.
