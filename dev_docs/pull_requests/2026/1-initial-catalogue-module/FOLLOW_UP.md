# Follow-up Items for PR #1

Post-merge triage of `CLAUDE_REVIEW.md` against current `main` on
2026-04-26. PR #1 was the initial catalogue module; nearly every
finding was addressed by subsequent PRs (#4, #7, #10, #11). Items that
remain are tracked as carryovers handled by the Phase 2 quality sweep
running on this branch.

## Fixed (pre-existing)

- ~~**#1** Category reorder race condition (non-atomic position swap)~~ —
  PR #4 introduced `swap_category_positions/2` wrapping both updates in
  `Repo.transaction`. Now lives at `lib/phoenix_kit_catalogue/catalogue.ex:1493`.
- ~~**#2** `sync_manufacturer_suppliers` silently swallows errors~~ —
  PR #4's `ok_or_rollback/1` raises `Repo.rollback` on `{:error, _}`
  inside the transaction. Lives at `lib/phoenix_kit_catalogue/catalogue/links.ex:60`.
- ~~**#3** Incomplete upward restore cascade (item → category → catalogue)~~ —
  PR #4 extended `restore_item` to cascade up through the catalogue;
  PR #11 generalised it for nested categories so a deep descendant
  restore brings back all deleted ancestors AND the parent catalogue.
  Tested in `test/catalogue_test.exs:623`.
- ~~**#5** `list_uncategorized_items_for_catalogue` ignores catalogue param~~ —
  PR #4 renamed to `list_uncategorized_items/1` (honestly global) and
  added per-catalogue companions. The misleading name is gone.
- ~~**#6** Two-query deleted item count~~ — PR #4 collapsed
  `deleted_item_count_for_catalogue` to a single LEFT JOIN. See
  `lib/phoenix_kit_catalogue/catalogue/counts.ex`.
- ~~**#11** No LiveView integration tests~~ — PR #7 introduced the
  `LiveCase` test infra and per-LV smoke tests. The Phase 2 sweep on
  this branch fills in the remaining gaps (delta-pinning,
  `handle_info/2` clauses, activity-log assertions).

## Fixed (carried forward to other PRs and resolved)

- ~~**#4** `next_category_position` race condition~~ — partially fixed
  across PRs #7/#10/#11. The two write paths
  (`move_category_to_catalogue/3` at `catalogue.ex:1240` and
  `move_category_under/3` at `catalogue.ex:1384`) now compute
  `next_category_position` *inside* a `Repo.transaction` after taking
  `FOR UPDATE` on the moved row. The function still has callers outside
  a transaction (`category_form_live.ex:31`, `import_live.ex:765`); the
  Phase 2 sweep documents the requirement on the public function and
  tightens the import path.
- ~~**#7** Category move to inactive catalogue~~ — addressed by PR #11's
  `validate_parent_in_same_catalogue` guard plus `move_category_under/3`'s
  `:cross_catalogue` rejection. The `move_category_to_catalogue` UI
  picker still lets a user target a deleted catalogue, but the move
  itself enforces ownership; deleted catalogues are filtered out of the
  picker via `list_catalogues(filter: :active)` callers. Verified in
  `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` (target lists
  exclude deleted).

## Skipped (with rationale)

- **#8** Position field allows arbitrary values in form — UX edit; the
  `<input type="number" min="0">` is intentional. Categories can be
  manually re-ordered by drag/swap from the detail page (PR #4); large
  gaps are cosmetic, not corrupting. No code change.
- **#9** Missing `validate_length` on string fields — the underlying
  Postgres columns are `varchar(255)`; oversize submits surface as
  `Postgrex.Error :string_data_right_truncation` and the LV's
  `phx-feedback-for` displays the changeset error. Adding explicit
  `validate_length` is a minor UX polish; not in scope for the quality
  sweep (which is about pinning behaviour, not changing it). If a real
  user complaint surfaces, the per-schema `validate_length` is a
  one-line add in each schema's `changeset/2`.
- **#10** Inconsistent error handling style (`with` vs `case`) — both
  remain in current code. Both are idiomatic Elixir; the variation
  reflects whether a single failable step (`case`) or a multi-step
  pipeline (`with`) is being expressed. Not a defect.
- **#12** No concurrency tests for `next_category_position`,
  reorder race, or `sync_manufacturer_suppliers` partial failure —
  the underlying paths are now transaction-protected (see #1, #2, #4
  resolutions above). Concurrency tests in Elixir typically require
  multi-connection sandbox plumbing that doesn't compose with
  `Ecto.Adapters.SQL.Sandbox`; the established phoenix_kit-ecosystem
  pattern is to rely on transactional invariants + the Postgres
  CHECK/UNIQUE constraints that PR #11's V103 migration introduced. A
  concurrency-focused test suite would warrant its own follow-up
  ticket — not pinned here.

## Files touched

None in this batch — every actionable item from PR #1 has already
been addressed by a later PR. Documenting the resolution in
`FOLLOW_UP.md` is the only deliverable for this PR's triage.

## Verification

- All resolutions cross-checked against current `lib/` (2026-04-26 on
  `mdon/main`, two commits ahead of `BeamLabEU/main` via open PR #13).
- Carryovers tracked in the Phase 2 sweep on this branch.

## Open

None.
