# Retained recovery fixtures

`v10-documents.sql` and `v15-part-procurement.sql` are frozen SQLite dumps. They retain the schema prefixes used at the PDF milestone (`df90fe8`) and procurement milestone (`4de11c2`). They were materialized once with the pinned GRDB migration prefix on W029's base `2d65359`. The matrix loads these dumps directly. It does not regenerate them from the current migrations.

Each contains stable UUIDs, a watch with a cover photo, a linked caliber, an open job, Unicode research text, a photo, a technical PDF, and a caliber source link. The v15 fixture also has a task, part requirement, and selected supplier option with an exact decimal price and leading-zero codes. Migration timestamps include fractions of a second. The fixtures contain no personal data or external downloads.

`manifest.json` matches the stored library metadata. `photo.base64` and `technical.pdf.base64` retain the exact original bytes. The driver decodes them into generated managed storage keys and local source files. The PDF has one page and a non-sensitive technical-sheet label. Import tests append valid PDF comment lines to create more than two 1 MiB copy chunks. Their expected bytes include that padding.

Keep these fixtures when migrations change. Add a new retained fixture only when a new schema needs its own upgrade regression. Do not update an older dump to make a migration pass.
