# Follow-up Items for PR #12

Triaged against `main` on 2026-04-26. Single CLAUDE_REVIEW; verdict
"Nothing blocking". Six findings, all preexisting or polish.

## Fixed (Phase 2 sweep on this branch)

- **#1** `CategoryFormLive` pays for file-grid queries it never renders —
  `mount_attachments/2` triggers `assign_files_state/1` →
  `compute_files_list/1` → DB query, but the category form has no files
  grid. Phase 2 C6 adds an opt-out flag (`files_grid: false`) to
  `mount_attachments/2`; CategoryFormLive sets it. Free win on every
  category form mount.

## Skipped (with rationale)

- **#2** Iron Law: DB queries in `mount/3` (preexisting, amplified) —
  cross-cutting LV refactor (move DB work to `handle_params/3`). All
  three form LVs would need the same change. Out of scope for the
  catalogue sweep — the Iron Law refactor wants a workspace-wide
  pattern decision (handled in core phoenix_kit's own sweep, not
  per-module). Documented as a known pattern; no change here.
- **#3** `metadata_add_options/2` rebuilds on every render — micro-perf.
  The 5–7 `Gettext.gettext/2` calls are negligible (lookup is a hash
  on the compiled .po). `assign_new` memoization would add complexity
  for sub-millisecond gain.
- **#4** `render_legacy_metadata_row` uses disabled `<.input>` — style
  preference. The disabled-input renders consistently with other
  inputs; switching to a `<span>` would lose the visual alignment with
  the active rows. The "Legacy" pill already signals archival status.
- **#5** `@files_grid_limit = 200` silently truncates — pre-existing
  from PR #11. Adding a "+N more" indicator is feature work, not a
  defect. Tracked as a future polish item; not pinned here.
- **#6** Metadata add-picker sits inside the outer form — verified
  harmless behaviour (the inner `phx-change="add_meta_field"` fires the
  picker's handler, not the form's; the save handler reads only
  `params["catalogue"]` / `params["meta"]`). Reviewer flagged for
  documentation; the existing component @moduledoc covers it.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/attachments.ex` | #1 add `files_grid: false` opt to `mount_attachments/2`; short-circuit `compute_files_list/1` when set |
| `lib/phoenix_kit_catalogue/web/category_form_live.ex` | #1 pass `files_grid: false` |

(Lands in the Phase 2 C6 commit, anchored here for the audit trail.)

## Verification

- Category form mount no longer issues the
  `list_files_in_folder/1` query (verified by mounting under tracing
  in `mix test`).

## Open

None.
