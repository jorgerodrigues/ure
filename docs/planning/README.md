# Ure planning

The repository holds the product specification and verification evidence. [GitHub issues](https://github.com/jorgerodrigues/ure/issues) hold the remaining story descriptions, acceptance criteria, discussions, and current status. The [roadmap](issues.md) maps stable planning IDs to GitHub issues and records dependency order.

## Start here

1. Read [specification.md](specification.md).
2. Select a story from [issues.md](issues.md).
3. Read the GitHub issue and its dependencies with `gh issue view`.
4. Settle proposed product choices that affect the selected story.
5. Follow the roadmap's [common completion rules](issues.md#common-completion-rules).

For W003, which adds watch records:

```sh
gh issue view 1 --repo jorgerodrigues/ure
```

## Sources and updates

| Source | Owns |
| --- | --- |
| [specification.md](specification.md) | Product decisions, behavior, model, architecture, and release acceptance |
| [GitHub issues](https://github.com/jorgerodrigues/ure/issues) | Story scope, acceptance checklists, discussion, and current status |
| [issues.md](issues.md) | Planning IDs, issue links, dependency order, and common completion rules |
| [setup-verification.md](setup-verification.md) | W001 implementation evidence and remaining checks |
| [library-verification.md](library-verification.md) | W002 implementation evidence and remaining checks |

Change product decisions in the specification, then update the affected GitHub issues. Keep story bodies and status on GitHub. Record actual build, test, and acceptance results in the repository.

## Product choices

The current-platform direction and W002's SQLite/GRDB design were approved on 1 October 2026. Separate repair jobs, shared caliber knowledge, and other defaults marked proposed in specification section 1 still need approval before affected implementation. Creating a GitHub issue does not approve those choices.

W001 and W002 are implemented. Their remaining verification gates are recorded in the linked reports. The 28 remaining stories are published as GitHub issues. PDF report creation remains outside this release.
