# Review of PR #161

Reviewed head `c4194cff` against `aa84d5d6`.

- **BUG - MEDIUM** — Incremental edits elected primaries across the whole list. After a legacy clear, even deleting an unknown UUID could repopulate the supplier's contact summary and expose a previously demoted email to consumers.
- **BUG - MEDIUM** — The equality check ignored contact UUIDs. Reordering two identical secondary contacts reported success but left them in the original order.
- **BUG - MEDIUM** — Contact editing read part of its return value after releasing the supplier lock. A concurrent edit could give the caller a summary and contacts from different revisions.
- **BUG - MEDIUM** — The importer silently mapped the Russian year option label and French plural “années” to “piece”.
- **IMPROVEMENT - MEDIUM** — The no-extension form fixture omitted the dimensions section already shipped on main and differed on a core admin layout attribute.
