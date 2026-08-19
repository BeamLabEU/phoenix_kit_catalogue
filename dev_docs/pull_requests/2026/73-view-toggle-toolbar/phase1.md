# Phase 1 Review — phoenix_kit_catalogue #73

**PR:** "Catalogues: move the view-mode toggle into the toolbar's view-tools cluster"
**Author:** Tymofii Shapovalov (timujinne)
**Opened:** 2026-08-18 22:36 UTC
**Reviewer:** Pincer 🦀
**Review date:** 2026-08-18 22:45 UTC

## Summary

Two files changed:
- `lib/phoenix_kit_catalogue/web/catalogues_live.ex` (+41/−38) — moves `catalogues_view_toggle` from the trash-tabs conditional row into `table_toolbar` via a new optional `:view_toggle` slot
- `dev_docs/2026-08-18-l029-folders-ux-followup.md` (+211/0) — working log for this branch (investigation + code rationale)

## Red Flag Check

| Check | Result |
|---|---|
| Build artifacts / secrets | ✅ None |
| Suspicious `mix.exs` changes | ✅ No `mix.exs` touched |
| Unrelated files | ✅ Dev doc is on-topic working log |
| Bad/swap/archive files | ✅ None |
| Scope creep | ✅ Code change is surgical (+41/−38, one component) |

## Code Assessment

The toggle was sitting in a `<div class="flex flex-wrap ...">` row that conditionally renders only when trash holds something (`@deleted_catalogue_count + @deleted_folder_count > 0`). That tied an always-relevant "how am I viewing this list" control to a trash-specific condition — visible UX inconsistency.

The fix:
1. Adds an optional `:view_toggle` slot to `table_toolbar`'s call site for the `:catalogues` scope
2. Renders the toggle next to "Columns" in the view-tools cluster — correct grouping
3. Three other `table_toolbar` call sites (manufacturers, suppliers, attribute_groups) don't pass the slot → `render_slot` no-ops → unaffected
4. Trash tabs keep their own conditional row, just without the toggle

The dev_docs file is a legitimate investigation log (includes a confirmed whitespace-collapse bug in the "Move to folder" dropdown — noted as a future issue, not part of this PR).

Tests: 1580 tests, 0 failures (per PR description).

## Verdict

✅ **No red flags. Clean, focused UX fix. Recommend merge.**
