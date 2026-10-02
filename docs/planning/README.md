# Ure planning

The repository holds the product specification and verification evidence. [GitHub issues](https://github.com/jorgerodrigues/ure/issues) hold the remaining story descriptions, acceptance criteria, discussions, and current status. The [roadmap](issues.md) maps stable planning IDs to GitHub issues and records dependency order.

## Start here

1. Read [specification.md](specification.md).
2. Select a story from [issues.md](issues.md).
3. Read the GitHub issue and its dependencies with `gh issue view`.
4. Settle proposed product choices that affect the selected story.
5. Follow the roadmap's [common completion rules](issues.md#common-completion-rules).

For W006, which adds job stages and watch condition:

```sh
gh issue view 4 --repo jorgerodrigues/ure
```

## Sources and updates

| Source | Owns |
| --- | --- |
| [specification.md](specification.md) | Product decisions, behavior, model, architecture, and release acceptance |
| [GitHub issues](https://github.com/jorgerodrigues/ure/issues) | Story scope, acceptance checklists, discussion, and current status |
| [issues.md](issues.md) | Planning IDs, issue links, dependency order, and common completion rules |
| [setup-verification.md](setup-verification.md) | W001 implementation evidence and remaining checks |
| [library-verification.md](library-verification.md) | W002 implementation evidence and remaining checks |
| [watch-verification.md](watch-verification.md) | W003 implementation evidence and pending native UI acceptance |
| [caliber-verification.md](caliber-verification.md) | W004 implementation evidence and deferred native acceptance |
| [job-verification.md](job-verification.md) | W005 implementation evidence and deferred native acceptance |
| [job-stage-verification.md](job-stage-verification.md) | W006 implementation evidence and deferred acceptance |

Change product decisions in the specification, then update the affected GitHub issues. Keep story bodies and status on GitHub. Record actual build, test, and acceptance results in the repository.

## Product choices

The current-platform direction and W002's SQLite/GRDB storage design were approved on 1 October 2026. Shared caliber knowledge and several repair jobs per watch, with at most one open job, were approved on 2 October 2026. W003 to W005 use explicit Save and Cancel editing. Other defaults marked proposed in specification section 1 still need approval before affected implementation. Creating a GitHub issue does not approve those choices.

W001 through W005 are merged. W006 is implemented on `w006-job-stages`. The user agreed to defer native UI and device checks to release acceptance. Their remaining verification gates are recorded in the linked reports. GitHub holds the 28 published stories and their current status. PDF report creation remains deferred.

On 2 October 2026, the user reduced CI to `make lint` and `make build` for rapid implementation. Keep test sources current and compile affected tests when needed. Restore CI unit execution and Release builds in W032 before first-release acceptance. Native UI and device automation stays off CI. Release builds are not required for each story during this phase.
