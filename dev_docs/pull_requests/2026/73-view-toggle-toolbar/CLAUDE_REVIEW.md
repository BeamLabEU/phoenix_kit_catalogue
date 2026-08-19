# PR #73 Review — move the catalogues view-mode toggle into the toolbar

**Author**: @timujinne (Tymofii Shapovalov)
**Reviewer**: Claude (Sonnet 5)
**Status**: Merged, reviewed post-merge
**Merge commit**: `dc261ad`
**Date**: 2026-08-19

## What landed

Two files, +41/−38 net in `catalogues_live.ex` plus a 211-line working-log
dev doc. Adds an optional `slot(:view_toggle)` to the shared private
`table_toolbar/1` component, rendered inside its existing "view tools"
cluster (next to sort + "Reorder all" + "Columns"). The `:catalogues` scope's
call site fills it with `<.catalogues_view_toggle view={cfg.view} />` (and
drops the now-unneeded `class="ml-auto"`); the Active/Deleted trash-tabs row
keeps its own conditional block, no longer paired with the toggle.

## Review method

Read the full `git show dc261ad -m --first-parent` diff plus the surrounding
`table_toolbar/1` and `simple_table/1` definitions to confirm the toggle
isn't duplicated for the flat-table view (`simple_table` already carries
`show_view_toggle={false}` for exactly this reason, pre-existing and
untouched) and that the other three `table_toolbar` call sites
(manufacturers, suppliers, attribute_groups) are unaffected by the new slot
(`render_slot` on an empty slot is a no-op).

## Verified as correct

- **Slot wiring is sound.** `:view_toggle` renders once, in one place,
  regardless of which of the three catalogue view modes (tree / card-level /
  flat table) is active, since `table_toolbar` renders unconditionally above
  that branch — matches the accompanying dev doc's own code-reading.
- **No duplicate toggle.** `simple_table`'s internal toggle stays suppressed
  via its pre-existing `show_view_toggle={false}` attr at this call site.
- **No scope creep.** The bundled dev doc (`2026-08-18-l029-folders-ux-followup.md`)
  is an on-topic working log for the same branch, not unrelated content.

## Findings

None. This is a small, surgical UI-organization change with no correctness
or convention issues.

## Gate

- `mix test test/web/catalogues_live_test.exs` — passes (covered as part of
  the combined PR #73 + #74 gate run; see
  [#74's review](/dev_docs/pull_requests/2026/74-attribute-sets-rework/CLAUDE_REVIEW.md)
  for the full-suite result on the current `main`).

## Related PRs

- Next: [#74](/dev_docs/pull_requests/2026/74-attribute-sets-rework)
