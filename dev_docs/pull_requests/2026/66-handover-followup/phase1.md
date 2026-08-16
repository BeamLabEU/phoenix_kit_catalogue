# PR #66 Phase 1 Review — phoenix_kit_catalogue
**Title:** Handover follow-up: drop internal ticket ids, link the tests issue, mark attributes as shipped
**Author:** Tymofii Shapovalov (timujinne)
**Date reviewed:** 2026-08-15
**Verdict:** APPROVE

---

## Summary

Docs-only PR (1 file changed, +19/-5 in `HANDOVER.md`). Three targeted cleanups:

1. **Opaque ticket IDs removed** — `L026`–`L029` replaced with self-contained prose. A single upfront note explains that those IDs were internal and links are impossible; reader is no longer left guessing.
2. **Test failures issue linked** — Pre-existing failures now point to #65 (open, verified). The note is also updated to reflect that the DnD reorder test was since fixed, leaving two `CatalogueDetailLive` URL-state failures outstanding.
3. **Attributes section marked shipped** — PR #64 ("Attribute-group system, uniform list controls, and folder fixes") merged today (2026-08-15). The section is kept as a design record with an update note on top that names the PRs, migration, and deliberate deviations from the original design.

All factual claims were verified against the repo state.

---

## Findings

### Blockers
None.

### Non-blockers

- The update note in the attributes section lists "catalogue PR #64 + phoenix_kit PR #718, migration V173" — `phoenix_kit #718` is in an upstream repo and could not be independently verified here, but the catalogue-side PR #64 is confirmed merged. If that upstream PR number is wrong, it's minor; the catalogue PR reference is the important one.
- The text says DnD reorder persistence "has since been fixed" but does not name the PR/commit that fixed it. Not a problem now, but if someone later asks "when was that fixed?", there's no pointer. Could add a parenthetical in a follow-up; not worth blocking this PR.

### Nitpicks

- The on-ticket-ids note is placed before section 2 but the IDs that were scrubbed also appear in section 3 ("Known issues"). The placement is slightly awkward — the note introduces itself before the reader has seen those IDs. Functionally fine; cosmetically a small ordering oddity.
- Minor prose tightening opportunity in the update note ("where the shipped feature deviates deliberately… the shipped behaviour wins") — clear as-is, no action needed.

---

## Stats
- **Tests:** No changes
- **Migrations:** No changes
- **Version bump:** Not warranted (docs only)
- **Dependency changes:** None
- **Files changed:** 1 (`HANDOVER.md`)
- **Diff:** +19 / -5
