# PR #11: Nested categories, attachments, item metadata, and item picker

**Author**: @mdon (Max Don)
**Reviewer**: @fotkin (Dmitri)
**Status**: Merged
**Merge commit**: `7c111e4` (content: `406ff4a` on mdon/main)
**Date**: 2026-04-22
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/11

## Goal

Consumes core phoenix_kit V103 (self-FK `parent_uuid` on categories) and ships three adjacent features on top of it:

1. **Nested categories** — recursive-CTE tree helpers, subtree cascades (trash / restore / permanent-delete), `move_category_under/3`, `list_category_tree/2`, `include_descendants` search expansion. Position scoping moves from `catalogue_uuid` to `(catalogue_uuid, parent_uuid)`.
2. **Attachments** — new `PhoenixKitCatalogue.Attachments` module shared by item + catalogue forms. Folder-per-resource, featured-image pointer, inline files dropzone, pending-folder rename on first save.
3. **Item metadata** — global opt-in fields stored under `item.data["meta"]`. Legacy keys surface as "Legacy" rows so dropping a definition from code never wipes stored data.
4. **Item picker** — `PhoenixKitCatalogue.Web.Components.ItemPicker`, a combobox LiveComponent with server-side search, `:include_descendants` scoping, and a colocated keyboard hook.

## What Was Changed

16 files, +4238 / −330.

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue/tree.ex` | **New.** Recursive-CTE helpers (`subtree_uuids/1`, `descendant_uuids/1`, `ancestor_uuids/1`, `ancestors_in_order/1`) plus pure in-memory walkers (`build_children_index/1`, `walk_subtree/3`) for preloaded trees. `UNION` (not `UNION ALL`) makes the CTEs cycle-safe against corrupted data |
| `lib/phoenix_kit_catalogue/catalogue.ex` | `+563 / −81`. `move_category_under/3` with `:would_create_cycle` / `:cross_catalogue` / `:parent_not_found` rejection; `trash_category` / `restore_category` / `permanently_delete_category` cascade across the whole subtree in one transaction; `restore_category` also restores deleted ancestors + the parent catalogue; `move_category_to_catalogue` carries the subtree along under a `FOR UPDATE` lock; `swap_category_positions/3` refuses `:not_siblings`; `list_all_categories/0` renders full breadcrumbs in two queries instead of N+1; `validate_parent_in_same_catalogue` guards create + update against cross-catalogue + descendant-as-parent |
| `lib/phoenix_kit_catalogue/catalogue/search.ex` | `search_items/2` gains `:include_descendants` (default `true`) so category-scoped search also matches items in descendant categories. Expansion goes through `Tree.subtree_uuids_for/1` |
| `lib/phoenix_kit_catalogue/schemas/category.ex` | Adds `belongs_to :parent` / `has_many :children`; `changeset/2` rejects self-parent via `validate_not_self_parent/1` (cross-catalogue + cycle checks live in the context, since they need DB lookups) |
| `lib/phoenix_kit_catalogue/attachments.ex` | **New.** `mount_attachments/2` + `allow_attachment_upload/1` + per-event delegates (`trash_file/2`, `open_featured_image_picker/1`, `handle_media_selected/2`). Smart detach (home vs `FolderLink`), pending-folder rename, `file_type_from_mime/1` widened bucketing, `list_files_in_folder/1` capped at 200 rows |
| `lib/phoenix_kit_catalogue/item_metadata.ex` | **New.** Global opt-in fields list (`definitions/0`), gettext-wrapped labels, `cast_value/2` normalizer |
| `lib/phoenix_kit_catalogue/web/components/item_picker.ex` | **New.** Combobox LiveComponent with server-side search, `:include_descendants` scoping, colocated keyboard hook (ArrowUp/Down, Home/End, Enter, Escape), `has_more` sentinel, debounced input |
| `lib/phoenix_kit_catalogue/web/catalogue_form_live.ex` | `+278 / −9`. Delegates the whole attachments flow to `Attachments`; save button disabled while uploads are in flight; catch-all `handle_info/2` for stray monitor signals |
| `lib/phoenix_kit_catalogue/web/item_form_live.ex` | `+903 / −183`. Metadata UI, attachments integration, item-picker host wiring |
| `lib/phoenix_kit_catalogue/web/category_form_live.ex` | `+142 / −2`. Parent picker wired to `list_category_tree/2` with `:exclude_subtree_of` so a category can't be parented under itself or a descendant in the UI either |
| `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` | `+62 / −28`. Tree rendering uses in-memory walker; depth-aware indentation; sibling-only swap gates |
| `lib/phoenix_kit_catalogue/web/components.ex` | **New.** Helpers shared across the attachments + picker surface |
| `test/catalogue_test.exs` | `+309 lines`. Cross-catalogue parent rejection on create + update, cycle-on-update guard, `move_category_under/3` (7 scenarios), subtree trash/restore/permanent-delete, `list_category_tree/2` ordering + orphan promotion + subtree exclusion, `next_category_position/2` parent scoping, `include_descendants` search |
| `test/web/item_picker_test.exs` | **New.** `+239 lines`. Render-shape tests for the combobox |
| `AGENTS.md` / `README.md` | Document every new surface |

## PR-Specific Findings

### Solid

1. **Defense in depth on cycles.** Three layers, each catching the cases the others can't:
   - `Category.changeset` rejects self-parent (no DB lookup needed).
   - `validate_parent_in_same_catalogue` (in `catalogue.ex:912-938`) rejects cross-catalogue + descendant-as-parent on both `create_category/2` and `update_category/3`. A raw `update_category(cat, %{parent_uuid: descendant.uuid})` is correctly rejected — tested at `catalogue_test.exs:467`.
   - `move_category_under/3` short-circuits with `{:error, :would_create_cycle}` before the DB write.

2. **CTE cycle safety.** `Tree.subtree_uuids_for/1` uses `UNION` (not `UNION ALL`) so Postgres drops rows already in the working table before the next iteration — any corrupted-data cycle breaks by emptying the working set. Rationale documented in the moduledoc (`tree.ex:11-19`). Comes at a per-row dedupe cost over `UNION ALL`; the tree fan-out is small enough that this is free in practice.

3. **Concurrency where it matters.** `move_category_to_catalogue/3` takes `SELECT … FOR UPDATE` on the moved row (`catalogue.ex:1199`) *before* the items-update + categories-update. Concurrent `create_item` / `update_item` calls block on the same row via `FOR SHARE` in `put_catalogue_from_effective_category/2`, so no item can slip in with a stale `catalogue_uuid` between the items-update and the commit. Position is also computed inside the transaction — same race `move_catalogue_to_catalogue` historically had, now closed for this path.

4. **`permanently_delete_category` handles V103's self-FK correctly.** V103 has no `ON DELETE CASCADE` on `parent_uuid`, so a straight `delete_all` on the subtree would reject any parent row while its children still reference it. The implementation NULLs `parent_uuid` across the subtree first, then deletes in one shot (`catalogue.ex:1138-1143`). Commented inline so the reason isn't lost.

5. **`restore_category` cascades both directions.** Upward: deleted ancestors + parent catalogue are restored so the restored node is reachable. Downward: subtree + items in the subtree come back. Semantics documented on the function and exercised by `catalogue_test.exs:623`.

6. **Activity metadata carries `subtree_size` + `items_cascaded`.** Every cascade logs how big the blast radius was — audit + debugging both benefit.

7. **Attachments extraction is coherent.** `mount_attachments/2` + `allow_attachment_upload/1` + event delegates keep LVs one-liner-thin. `detach_home` vs `detach_link` correctly handles the three cases (single-owner trash, shared-promote, link-only delete). The featured-file-surfaced-from-another-folder case in `compute_files_list/1` means a cross-resource duplicate-move doesn't leave a ghost pointer in the form grid.

8. **Pending-folder rename.** New resources lazy-create a random-named folder; `maybe_rename_pending_folder/2` renames it after the `:new` save once the resource has a UUID. Non-fatal — rename failures log and return `:ok` instead of blocking the save path.

9. **ItemPicker a11y + ergonomics.** Proper combobox pattern (`role="combobox"`, `aria-expanded`, `aria-activedescendant`, `role="listbox"` + `role="option"`), `phx-debounce="300"`, `has_more` sentinel so the dropdown tells the user "type to refine" when results exceed `page_size`, and — critically — `update/2` only rewrites `:query` when the selected UUID actually changes (`item_picker.ex:110-132`). A mid-typing user isn't clobbered by unrelated parent re-renders.

10. **Test coverage of the dangerous paths.** Cross-catalogue parent rejection on *both* create and update, cycle on update, orphan promotion in `list_category_tree/2`, `next_category_position/2` scoping by parent, descendant expansion in search. ~20 meaningful new tests.

### Minor concerns

1. **TOCTOU in `move_category_under/3`.** The cycle check (`Tree.subtree_uuids/1`) runs outside a transaction, then the update runs (`catalogue.ex:1319-1331`). Two concurrent `move_category_under` calls on different nodes could each pass their individual cycle check and then jointly create a cycle. `move_category_to_catalogue` locks its row explicitly — `move_category_under` should do the same, or wrap the check + update in a single transaction with `FOR UPDATE` on the moved row. Low-impact (two racing admins on the same tree), but cheap to fix. **Follow-up candidate.**

2. **`swap_category_positions/3` is also racy.** Two concurrent swaps with overlapping siblings could interleave between the two `update!` calls and leave position duplicates (`catalogue.ex:1395-1403`). A `SELECT … FOR UPDATE` on both rows inside the transaction would fix it. Same severity as #1.

3. **`validate_parent_in_same_catalogue` always does a DB lookup on update.** It runs `Tree.subtree_uuids(own_uuid)` + a `repo.get` on every `create_category` / `update_category`, including the common case where `parent_uuid` wasn't in `attrs` at all. Could early-return when `Ecto.Changeset.get_change(:parent_uuid)` is absent. Pure optimization — not urgent.

4. **`restore_category` auto-restores all deleted ancestors.** By design (documented in the moduledoc) — without it, the restored node wouldn't be reachable in the active tree. But if an admin deliberately trashed a parent and then later restores a deep descendant, the intentionally-deleted ancestors come back without a confirmation. Consider surfacing a "this will also restore N ancestor categories and the parent catalogue" confirmation in the LV before calling. Backend behavior is fine; the UX is what surprises.

5. **`Attachments.soft_trash_file/1` is a deliberate duplication.** The comment at `attachments.ex:295-300` explains: `PhoenixKit.Modules.Storage.trash_file/1` wasn't released at the time this plugin pins against. Worth a grep-able TODO so this gets ripped out when the next phoenix_kit release is adopted — otherwise this drifts.

6. **JSONB search is a sequential scan.** `fragment("?::text ILIKE ?", i.data, ^pattern)` in `Search.search_items_base/2` does `to_jsonb_text(data) ILIKE '%…%'` — no index helps. Acceptable today, but the ItemPicker hammers this on every keystroke (300ms debounced). When the item table grows, add a GIN `pg_trgm` index on `(name || description || sku || data::text)` or pre-extract a `search_text` column. Flag for when `count_search_items` starts showing up in slow-query logs. Not introduced by this PR, but the picker makes it more visible.

7. **`Tree.build_children_index/1` has a redundant `Map.new`.** `Enum.group_by(& &1.parent_uuid)` already returns the map shape you want; the subsequent `|> Map.new(fn {k, v} -> {k, v} end)` is a no-op (`tree.ex:149-153`). Dead line.

8. **`find_folder_by_name` collision surface.** Folder names `catalogue-item-<uuid>` / `catalogue-<uuid>` are scoped to `is_nil(parent_uuid)`. Safe today because UUIDs are unique and Storage folders are app-global, but if another plugin ever creates a colliding name at the root the lookup wins the wrong folder. The prefix choice is defensive; worth a one-line inline comment that this is *why* the prefixes exist.

## General Module Review (Elixir / Phoenix / Ecto skill lens)

Skills invoked: `elixir-thinking`, `phoenix-thinking`, `ecto-thinking`.

### Elixir-thinking

- **Iron Law (no process without a runtime reason)** — ✅ No new `use GenServer`, `use Agent`, `use Task`, or supervision introduced. `Attachments` is a plain module; `ItemMetadata` is a plain module; `Tree` is a plain module. All concurrency is Ecto transactions + LV-scoped upload tasks.
- **`raise` only on the `!` path and inside transactions** — `repo().update!/1` / `repo().one!/1` inside `Repo.transaction/1` blocks (raises trigger rollback — intended). `get_category!/1` is the documented raising variant. No surprise throws.
- **Pattern matching on function heads** — heavily used for cascade behavior (`move_category_under(%Category{parent_uuid: same} = category, same, _opts)` for the no-op case, `detach_home` / `detach_link` split in `Attachments`). Good.
- **`with` chains** — `maybe_rename_pending_folder/2` uses `with` cleanly with an `else` branch that collapses all failure modes to `:ok` (non-fatal semantics). Appropriate.

### Phoenix-thinking

- **Iron Law (no DB queries in `mount/3`)** — `Attachments.mount_attachments/2` hits the DB (`assign_files_folder/1`, `assign_featured_image_state/1`) unconditionally. This runs in both the dead render and the connected render — the duplicate-query gotcha. Acceptable for now because the queries are narrow (`get_file/1`, single folder lookup), but the guard-on-`connected?(socket)` pattern from the admin LVs would halve the load on first paint. Worth noting as a follow-up.
- **Catch-all `handle_info/2`** added to `CatalogueFormLive` and `ItemFormLive` (PR note). ✅ Closes the "stray monitor signal crashes the form" class of bug.
- **`phx-disable-with` on destructive buttons** — category-under-parent, category-to-catalogue, item-to-category, item-to-smart-catalogue all covered. ✅
- **Save-while-uploading race** — save button is disabled while uploads are in flight so `handle_progress` can't race the save path. ✅
- **LiveComponent `update/2` selectivity** — ItemPicker only mirrors `selected_item.uuid` into `:query` when the UUID actually changes. This is exactly the right call: a parent re-render that passes the same `selected_item` won't clobber a mid-typing user.
- **Colocated hook** — ItemPicker's keyboard hook is colocated via `<script :type={Phoenix.LiveView.ColocatedHook}>`. Cleanup in `destroyed()` removes the keydown listener. ✅

### Ecto-thinking

- **Recursive CTE composition** — `Tree.subtree_uuids_for/1` and `ancestor_uuids/1` are textbook recursive-CTE Ecto. The use of a *map* projection (`select: %{uuid: c.uuid}`) across the initial + recursion queries is the required shape for `with_cte`.
- **`UNION` vs `UNION ALL`** — deliberately chose `UNION` for cycle safety (moduledoc comment). ✅
- **Preload vs join** — search preloads `[:catalogue, category: :catalogue, manufacturer: []]` (separate queries for has-one-like FK chains) but uses `join: cat in Catalogue` inside `search_items_base` for the `WHERE` filter. Correct split.
- **Transaction boundaries** — every cascade is a single `Repo.transaction/1`. Activity-log writes happen *outside* the transaction (correct — activity log shouldn't fail the primary op, and the context's `log_activity/1` already rescues).
- **`FOR UPDATE` + `FOR SHARE` interplay** — documented inline in `move_category_to_catalogue/3`. ✅
- **CHECK constraints** — V103 (core phoenix_kit) owns the `parent_uuid` FK. No new app-level CHECKs needed.
- **N+1 avoidance** — `list_all_categories/0` explicitly loads catalogues + categories in two queries and does the tree walk + breadcrumb rewrite in memory. `catalogue_detail_live.ex` uses `Tree.build_children_index/1` + `walk_subtree/3` to render the tree without per-node DB trips.

### Idioms

- Structs over maps for known shapes (`%Category{}`, `%Item{}`, `%File{}`, `%FolderLink{}`). ✅
- Gettext for every user-facing string in the new surface. ✅
- `maybe_put/3` keyword-list builder in ItemPicker — idiomatic keyword-option composition.

## Carryover from PR #10 Review

From `dev_docs/pull_requests/2026/10-smart-catalogues/REVIEW.md` (itself carried from PR #7):

1. **`next_category_position/1` outside the transaction** in `move_category_to_catalogue/3`. Still addressed in this PR — position is now computed inside the transaction *after* the subtree has moved (`catalogue.ex:1218`). ✅ **Closed.**
2. **`move_item_to_category/3` lacks the `FOR SHARE` lock.** Not touched by this PR. Still open.
3. **`actor_opts/1` duplicated across 8 LiveViews.** Not touched. Still open.

## Precommit & Static Analysis

Ran against the merged state (local main at `7c111e4`):

- **format** — ✅
- **credo --strict** — ✅ 1047 mods/funs across 62 files, 0 issues
- **dialyzer** — ✅ 0 errors, 0 skipped warnings (1 unnecessary skip carried from PR #10, worth cleaning up separately)

## Verdict

✅ **Approved & merged.** Careful, self-consistent PR. Cycle handling is belt-and-braces and well-tested; V103's self-FK is used correctly (including the `parent_uuid`-NULL-then-delete dance in `permanently_delete_category`); `move_category_to_catalogue`'s `FOR UPDATE` lock closes the long-standing race from PR #7. The three feature threads (attachments / metadata / picker) are cleanly isolated — no feature leaks into a sibling's concerns.

Two low-severity follow-ups to open as tickets:

1. Transactional cycle check in `move_category_under/3` + row lock.
2. Row-locked `swap_category_positions/3`.

Both are low-probability data-integrity issues under concurrent load; neither is a release blocker.

## Release

No version bump in this PR — still on `0.1.10` (set in PR #10). A `0.1.11` bump + CHANGELOG entry for the nested-categories / attachments / metadata / item-picker surface is the natural next step before publishing to Hex.
