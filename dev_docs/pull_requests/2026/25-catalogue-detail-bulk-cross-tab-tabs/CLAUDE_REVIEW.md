# PR #25: Catalogue detail — tabs, bulk actions, per-card pagination, cross-tab live updates

**Author**: @mdon (Max Don)
**Reviewer**: @fotkin (Dmitri)
**Status**: Merged
**Merge commit**: `722baa1` (content tip: `0ef469f`)
**Date**: 2026-05-09
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/25
**Diff**: 17 files, +3252 / −735

## Goal

Ten commits of catalogue admin UX work, hardened by a Phase 2 sweep at
the tail end. The feature set:

1. **Items / Categories tabs** on the detail page, reflected to URL
   (`?tab=items|categories`) with per-tab Active / Deleted counts and
   a flat recency-ordered Items-Deleted view.
2. **Decoupled soft-delete semantics** — restoring a category no longer
   cascades; restoring an item whose parent category is deleted detaches
   it to Uncategorized; restoring under a deleted catalogue is refused.
   The boss's principle: each entity's status is its own.
3. **Item-disposition modal** when trashing a category that still has
   items (Cascade / Uncategorize / Move to).
4. **Bulk select + actions** with row checkboxes (table + card view) and
   sticky action bar — Delete / Restore / Move (items) and Delete
   (categories, opens disposition modal in bulk mode).
5. **Per-card pagination** — replaced the global infinite-scroll cursor
   with a PdfSearchModal-style per-card 25-row preview + "Show N more"
   button per card. Show-more is deferred (event handler returns
   immediately, button renders loading state, fetch runs on next
   mailbox tick) with an 8s `:expand_timeout` recovery.
6. **Cross-tab live updates** via PubSub for reorders + bulk operations
   + category position changes; bulk operations get a two-step receiver
   animation (red flash on leaving rows → 800ms delay → state refresh →
   green flash on arriving rows).
7. **Drag-handle-only DnD** — `pk-drag-handle` class wired through
   `data-sortable-handle` so the row body is no longer a drag affordance.
8. **Polish** — selected-row primary tint + 4px left-edge accent;
   collapsed `<details>` wrappers around destructive + move actions on
   the form pages; reorder-result flashes (green/red) on rows + cards.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue.ex` | `+475 / −80`. `trash_category/2` accepts `:items` opt (`:cascade`/`:uncategorize`/`{:move_to, uuid}`) via new `apply_item_disposition/4`. `restore_category/2` no longer cascades; refuses with `:parent_catalogue_deleted`. `restore_item/2` detaches from deleted-parent category instead of cascading up. New `list_move_target_categories/1` (same-catalogue, subtree-excluded). New `list_deleted_items_for_catalogue/2` (flat, deleted_at desc, capped). 5 new bulk fns: `bulk_trash_items/2`, `bulk_restore_items/2`, `bulk_permanently_delete_items/2`, `bulk_move_items_to_category/3`, `bulk_trash_categories/3`. The bulk-move fn requires a `:catalogue_uuid` opt and validates both items + target stay in scope. |
| `lib/phoenix_kit_catalogue/catalogue/counts.ex` | `+15`. `active_item_count_in_subtree/1` for the disposition-modal gate. |
| `lib/phoenix_kit_catalogue/catalogue/pub_sub.ex` | `+91`. `broadcast_card_refresh/5`, `broadcast_category_reorder/4`, `broadcast_bulk_change/5`. All include `from \\ self()` so the originator's own broadcast can be filtered on receive. |
| `lib/phoenix_kit_catalogue/errors.ex` | `+8`. New `:parent_catalogue_deleted` reason + gettext message. |
| `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` | `+1644 / −351`. New `handle_params/3` (URL→`:tab` sync + per-tab auto-flip). Bulk-action event handlers, modal state machines, deferred `expand_card` flow with `:expand_timeout` recovery, three cross-tab `handle_info/2` clauses (`:catalogue_card_refresh` / `:catalogue_category_reorder` / `:catalogue_bulk_change`), `:bulk_change_apply` two-step animator, `flash_reorder/3` pushing `sortable:flash` to the SortableGrid hook. `build_loaded_cards/5` eagerly builds per-category cards instead of cursor-walking. The infinite-scroll `fetch_next` / `merge_*` helpers are deleted. |
| `lib/phoenix_kit_catalogue/web/catalogue_form_live.ex` | `+22 / −12`. Danger zone collapsed into native `<details>`. |
| `lib/phoenix_kit_catalogue/web/category_form_live.ex` | `+90 / −65`. Move + Danger blocks both collapsed into `<details>`. |
| `lib/phoenix_kit_catalogue/web/catalogues_live.ex` | `+2 / −1`. `pk-drag-handle` class on the catalogues table cell. |
| `lib/phoenix_kit_catalogue/web/components.ex` | `+104 / −38`. `item_table` gets `selectable` / `selected_uuids` / `on_toggle_select` attrs; combined checkbox + hover-revealed drag-handle column; selected-row tint via `!bg-primary/15 border-l-4 border-l-primary`; mobile card buttons go icon-only. New `selected?/2` helper. |
| `lib/phoenix_kit_catalogue/web/item_form_live.ex` | `+81 / −70`. Move blocks merged + collapsed into `<details>`. |
| `test/catalogue_test.exs` | `+347 / −23`. Two restored-behaviour tests rewritten for the no-cascade rule, two soft-delete tests rewritten for the parent-deleted refusal. 23 new tests across `bulk_trash_items` / `bulk_restore_items` / `bulk_permanently_delete_items` / `bulk_move_items_to_category` / `bulk_trash_categories` / `list_move_target_categories` / `active_item_count_in_subtree` / `list_deleted_items_for_catalogue`. |
| `test/errors_test.exs` | `+5`. `:parent_catalogue_deleted` message assertion. |
| `test/web/catalogue_detail_branches_test.exs` | `+185 / −12`. New describes for bulk selection + actions, `expand_card`, cross-tab live updates. Old `move_category_up/down` describe deleted (events removed). |
| `test/web/catalogue_detail_live_test.exs` | `±64`. Old `load_more` / `move_category_up` tests rewritten for the per-card expand + DnD-only reorder model. |
| `test/web/form_lives_test.exs` | `+5 / −1`. Form selector scoped to `form[action="#"]` to disambiguate the Attachments dropzone form. |
| `test/web/item_form_live_test.exs` | `+12 / −10`. Same form-selector scoping in 9 call sites. |
| `AGENTS.md` | `+102 / −8`. Soft-delete System section rewritten; new CatalogueDetailLive layout + Item-disposition modal sections. |

## PR-Specific Findings

### Solid

1. **The bulk-move scope guard is the right shape.** `bulk_move_items_to_category/3` requires a `:catalogue_uuid` opt; `ensure_items_in_catalogue/2` runs one bounded `EXISTS` (`limit: 1`) and `resolve_move_target/2` pattern-matches on `^catalogue_uuid` in the schema. The single-item DnD path enforces the same guard, so the bulk path is now symmetric — a crafted `phx-click` payload with foreign UUIDs can't silently flip cross-catalogue. The new error atoms (`:wrong_catalogue_scope`, `:missing_catalogue_scope`) are explicit. Phase 2 sweep self-caught a real BUG-HIGH and the resulting code is the right shape, not a band-aid.

2. **Cross-tab broadcast pattern is clean.** Every broadcast carries `from \\ self()`; receivers either filter `when from != self()` or clamp on `from == self()`. This means the originator's local update happens immediately, and the broadcast is purely for *other* tabs — no double-render race. The `:catalogue_bulk_change` two-step animation (red flash on receivers → 800ms delay → `reset_and_load` + green flash for `:moved` / `:restored`) is a thoughtful UX choice. Extracting `@bulk_change_apply_delay_ms` was the right Phase 2 polish.

3. **Deferred `expand_card` with timeout recovery.** The flow — `send(self(), {:apply_expand, scope})` + `Process.send_after({:expand_timeout, scope}, 8_000)` + a `MapSet`-gated `do_apply_expand/2` — is the standard "show loading state then fetch" pattern done correctly. `:expand_timeout` only fires its branch if the scope is still in `expanding_cards`, so a successful apply that happens within 8s naturally cancels the recovery without a `Process.cancel_timer` dance. The 8s window is calibrated for a stuck mailbox / dead socket, not a slow DB — the comment says so explicitly.

4. **Decoupled soft-delete semantics match the docstrings on the public fns.** The `restore_item/2` doc explains the "uncategorize on restore" rule and the `:parent_catalogue_deleted` refusal; activity metadata grew `"detached_from_category" => true` so the audit log is interpretable. `trash_category/2` documents all three `:items` dispositions. Tests rewrote (didn't accumulate next to) the old cascade tests, so the suite isn't lying about behaviour.

5. **Test coverage matches the surface.** 23 context-fn tests cover every bulk error path including the scope guards (`:missing_catalogue_scope`, `:wrong_catalogue_scope`, `:category_not_found`); 11 LV smoke tests cover bulk events, `expand_card` happy path, `:expand_timeout` recovery, and all three cross-tab handlers (`from == self()` self-skip, `from != self()` apply, deferred bulk apply scheduling). The form-selector disambiguation in `form_lives_test.exs` and `item_form_live_test.exs` is a real fix — the Attachments dropzone form was stealing the loose `form[phx-submit=save]` selector.

6. **DnD handle restriction landing across all catalogue admin views.** `pk-drag-handle` + `data-sortable-handle=".pk-drag-handle"` is wired on `catalogues_live.ex`, `components.ex` (`catalogue_rule_row` and `item_table`), the new `category_row` in detail LV, and `catalogue_detail_cards`. Consistent — no row-body drag affordance in any list anymore.

### Issues

1. **HIGH — `restore_category/2` docstring still describes the old cascade behaviour.** `lib/phoenix_kit_catalogue/catalogue.ex:1388` reads:

   > Restores a soft-deleted category (and its deleted subtree) by setting status back to "active". … Restoring a node after a prior trash cascade brings the whole sub-branch back as one action.

   The implementation immediately below it does the opposite — flips only the target's status, with a long block comment explaining "no cascades; restore-as-undo doesn't ripple sideways." The body comment is right, the doc is stale. Anyone reading `h Catalogue.restore_category` (or hovering it in their editor) will get the wrong contract. This needs to be updated to match `restore_item/2`'s rewritten doc — describe the no-cascade rule, the `:parent_catalogue_deleted` refusal, and that descendants stay deleted (orphan-promotion in `list_category_tree/2` surfaces a re-active leaf as a root).

2. **MEDIUM — `bulk_restore_items/2` is not transactional, has a TOCTOU window.** `lib/phoenix_kit_catalogue/catalogue.ex:3076-3097`. The flow is: read items with `:catalogue` and `:category` preloads → partition by `category.status == "deleted"` → run two separate `update_all`s. Between the read and the writes, another connection can flip a `category.status` from `"deleted"` to `"active"` (or vice versa) and the partition becomes wrong — items get unnecessarily detached, or items that should have been detached get attached-restored. Single-row `restore_item/2` runs in `repo().transaction/1`; the bulk version doesn't. Wrap the whole flow in `Repo.transact/1` for parity. Not a frequent failure mode (admin UI is single-operator most of the time), but the inconsistency with the single-item path is a real correctness gap.

3. **MEDIUM — N queries in `build_loaded_cards/5` on initial mount.** `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:2036+`. Every category in the catalogue gets its own `list_items_for_category_paged/2` call (plus one for uncategorized). For a catalogue with 50 categories, that's 50 round trips on every connect / `reset_and_load`. The old infinite-scroll did one query per `@per_page` batch. For typical admin sizes (~10 categories) this is fine; for large catalogues this is a regression that scales linearly with category count. Possible fix: a single window-function query (`ROW_NUMBER() OVER (PARTITION BY category_uuid ORDER BY position, name) <= 25`) returning all preview items in one round trip. Not blocking — flag as future work, especially since the previous PR description (#23) wired `:preload` opts to enable consumers to batch.

4. **MEDIUM — PubSub topic is a single global string.** `pub_sub.ex:28` — `@topic "phoenix_kit_catalogue"`. Every detail LV subscribes to it, every broadcast goes to it, and receivers filter on `cat_uuid == catalogue_uuid` to discard cross-catalogue noise. This works, but a user with five detail tabs across five different catalogues is paying broadcast fan-out for the other four every time anyone moves a row anywhere. Per-catalogue topics (`"phoenix_kit_catalogue:#{catalogue_uuid}"`) would scope each subscriber to only their own catalogue's events. Phoenix-thinking specifically calls this out: "Unscoped topics = data leaks between tenants." Here it's not a leak (the `cat_uuid` filter is correct), but it is wasteful messaging.

5. **LOW — `do_bulk_move/4` doesn't filter on `i.status != "deleted"`.** `catalogue.ex:3217+`. The other bulk fns all filter (`bulk_trash_items` requires `status != "deleted"`, `bulk_restore_items` requires `status == "deleted"`, etc.); `do_bulk_move` updates blindly by UUID. In practice the LV's `selected_items` is built from rendered (active) cards, so the selection set is well-formed; but the same crafted-payload concern that motivated the catalogue-scope guard applies here too — a stale tab could submit a move on a soft-deleted UUID. Add `where: i.status != "deleted"` to both `do_bulk_move/4` clauses for consistency with the rest of the bulk surface.

6. **LOW — `bulk_restore_items/2`'s activity-log `"uuids"` field can include items that weren't actually updated.** `catalogue.ex:3097-3110`. The metadata is `"uuids" => ok_uuids`, where `ok_uuids` is the set that survived the catalogue-deleted filter. But the actual `update_all`s use `where: i.status == "deleted"` — so an item that was already active (e.g., concurrent restore) wouldn't be updated, yet it appears in the audit "uuids" list. The `count` field is right (it's the `update_all` return), but the audit metadata claims successful restores it didn't actually do. Either trim `ok_uuids` after the writes, or just record `count` without the per-uuid list (most other `bulk_*` fns log just `count` and a pre-write uuid list, and this is consistent with that — but the doc on the surface says "Refuses any item whose parent catalogue is deleted (returns the count of *attempted* successes; skipped ones are excluded)" which is a bit fuzzy as written).

7. **LOW — `_scopes` field on `:catalogue_bulk_change` is dead payload.** `pub_sub.ex:170` defines and validates it; the LV calls always pass `[]` (e.g., `do_bulk_trash_items` line 1709, `do_bulk_permanent_delete_items` line 1725, etc.); the receiver in `catalogue_detail_live.ex:1133` discards it (`_scopes`). The doc on `broadcast_bulk_change` describes how it should be used ("the list of category scopes whose cards need to refresh") but the receiver does a full `reset_and_load` instead, so the granular per-scope refresh isn't implemented yet. Either wire it up (`scopes` lets receivers refresh just the affected cards, preserving scroll position better than `reset_and_load`) or drop the field.

8. **LOW — `apply_item_disposition({:move_to, target_uuid}, ...)` has a redundant pin.** `catalogue.ex:1383` matches `%Category{uuid: ^target_uuid} = target ->` after the `target_cat_uuid != category.catalogue_uuid` clause. Since `target` came from `repo().get(Category, target_uuid)`, its `:uuid` is necessarily `target_uuid` — the pin can never fail. Just `%Category{} = target ->` is enough and reads cleaner.

9. **LOW — `Process.sleep(1100)` in `list_deleted_items_for_catalogue/2` test.** `test/catalogue_test.exs:4467`. To exercise `order_by: [desc: i.updated_at, asc: i.uuid]` the test needs a measurable timestamp gap; the sleep makes the test add ~1.1s of wall clock. Cleaner alternatives: directly write `updated_at` via `Ecto.Query.from(...) |> Repo.update_all(set: ...)` between the trashes, or use `Ecto.Query`'s `fragment("now() - interval '1 second'")` to push one row's timestamp back. Minor; suite-perf only.

10. **LOW — `expand_timeout` test reaches into `:sys.replace_state/2`.** `test/web/catalogue_detail_branches_test.exs:4676`. The test forcibly sets `expanding_cards` to a singleton MapSet, then sends `:expand_timeout`. This is a faithful simulation of "the apply got dropped, the timer fires," but `:sys.replace_state` is a test smell that bypasses the actor model. A cleaner approach: drive the LV through `expand_card`, then immediately stub the next mailbox tick or use a slower simulated DB. Acceptable as a test-only workaround for this PR; flag for the next refactor.

11. **NIT — `categories_bulk_bar` and `items_bulk_actions` are the same component shape.** `catalogue_detail_live.ex:3233-3294`. Both render a `count selected` label + view-mode-conditional buttons + a Clear button. The Items version offers Move + Delete (active) / Restore + Delete-forever (deleted); the Categories version offers Delete (active) / Restore (deleted). Could be one component with a `kind: :items | :categories` prop and a list of action specs. Not blocking — the duplication is short and stable.

12. **NIT — `flash_reorder/3` naming is confusable.** It pushes a `sortable:flash` event for the SortableGrid hook to colour-flash a row, not a `put_flash` message. Naming it `push_row_flash/3` or similar would prevent the next reader from grepping for `put_flash` and getting confused. Tiny.

## Architectural Observations

- **The Iron Law (no DB queries in mount) is respected.** mount/3 sets default assigns then runs `reset_and_load` only inside `if connected?(socket)`. handle_params/3 — newly added — does zero direct DB work; it only reads the URL param and conditionally calls `maybe_auto_flip_to_active/1`, which itself only triggers `reset_and_load` when view_mode is `"deleted"` and the per-tab deleted count is 0. The extra patches that handle_params introduces (tab switch + auto-flip) don't accidentally re-query on mount.

- **The disposition modal's `:items` opt is a sum type carried as a keyword opt** — `:cascade | :uncategorize | {:move_to, uuid}`. Compact and idiomatic, but `bulk_trash_categories/3` lifts it to the second positional argument while `trash_category/2` keeps it as a keyword opt. Slightly inconsistent surface — both reasonable; consider unifying when there's a touch-point.

- **Activity-log metadata growth.** The bulk_* fns log `"uuids" => uuids` lists. For a 200-item bulk this writes ~7KB of JSON per audit row. If audit retention is unbounded, consider switching to `"count"` only, or capping `"uuids"` to the first N. Not in scope for this PR.

- **The `_loading` and `_has_more` assigns are still set in `mount/3`** but the cursor / sentinel rendering paths are deleted. `loading: false` is harmless (no template branches read it now) but is dead. `has_more` was deleted. Worth a sweep next pass.

## Test plan execution

- [x] `gh pr view` shows merged 2026-05-09 with the Phase 2 sweep tail.
- [x] All 17 changed files reviewed against the diff.
- [x] LV mount lifecycle inspected for the Iron Law.
- [x] `bulk_move_items_to_category/3` scope guard verified end-to-end (LV passes `:catalogue_uuid`, context fn enforces it, tests cover all error paths).
- [ ] **Manual two-tab cross-broadcast smoke test not run.** Suggested for the merger before tagging the next release: open the same catalogue in two browsers, drag → flash on both; bulk-move → red→green animation on the receiver tab.

## Suggested follow-ups (not blockers)

1. Update the `restore_category/2` docstring to match the no-cascade behaviour (HIGH).
2. Wrap `bulk_restore_items/2` in `Repo.transact/1` for parity with `restore_item/2` (MEDIUM).
3. Replace the per-category preview queries with a single window-function query when category counts grow (MEDIUM).
4. Scope the PubSub topic per catalogue UUID (MEDIUM).
5. Add `where: i.status != "deleted"` to `do_bulk_move/4` for surface consistency (LOW).
6. Either wire the `_scopes` payload or drop it from `broadcast_bulk_change/5` (LOW).
7. Sweep dead `loading` / `has_more`-style assigns from mount defaults (NIT).

## Follow-up commit (this review's scope)

Items 1, 2, 5, 6, 7 from the list above were applied in a follow-up
commit on `main` after the merge — items 3 and 4 are deliberately
deferred since they want their own PR (window-function query design;
PubSub-topic migration touches subscribe + four broadcast/receive
sites).

| # | Status | What changed |
|---|--------|--------------|
| 1 | ✅ Done | `restore_category/2` @doc rewritten (`catalogue.ex`). New text describes the no-cascade rule, the `:parent_catalogue_deleted` refusal, and that descendants / ancestors / items keep their statuses. Mirrors the shape of the rewritten `restore_item/2` doc. |
| 2 | ✅ Done | `bulk_restore_items/2` now wraps the read-then-partition-then-write pipeline in `repo().transaction/1`. Body extracted to `do_bulk_restore_items/1`; the partition uses `Enum.split_with/2` instead of the old hand-rolled reduce. The activity-log `"uuids"` field now carries `attached_uuids ++ detached_uuids` (same set as before, but built post-partition rather than from the full reject list, so the metadata is stable across both code paths). |
| 5 | ✅ Done | `do_bulk_move/4` (both `nil` and `%Category{}` clauses) gained `where: i.status != "deleted"`. Comment on the `nil` clause explains why — surface consistency with `bulk_trash_items` / `bulk_restore_items` and defence against a stale tab submitting a deleted UUID. |
| 6 | ✅ Done — dropped | `broadcast_bulk_change/5` → `/4`. The `scopes` parameter was always called with `[]` and always discarded by the receiver; rather than wire it, removed it. Updated: `pub_sub.ex` (def + spec + doc), 4 LV call sites (`do_bulk_trash_items`, `do_bulk_permanent_delete_items`, `do_bulk_restore_items`, `do_bulk_move_items` ok branch), 2 LV `handle_info/2` clauses (the receiving + self-ignore patterns), and the LV-test `send/2` payload. Doc on the broadcast fn updated to explain the `reset_and_load`-on-receive trade-off rather than the (now-absent) per-scope refresh. |
| 7 | ✅ Done | Removed `loading: false` from mount default assigns in `catalogue_detail_live.ex`. Confirmed via grep that nothing references the bare `:loading` (only `search_loading`, which is alive). `has_more` was already deleted in the PR itself; only `loading` was the leftover. |
| 3 | ⏭ Deferred | N-queries-on-mount via window function. Wants its own PR — touches `Catalogue` query surface + a new context fn. |
| 4 | ⏭ Deferred | Per-catalogue PubSub topic. Wants its own PR — touches subscribe + 4 broadcasts + 4 receivers + cross-tab tests; also has a back-compat angle if any external consumer subscribes to the legacy topic. |

### Verification

- `mix compile` clean (sole warning is a pre-existing `def handle_info/2` clause-grouping nit on
  `catalogue_detail_live.ex:151` that wasn't introduced or touched by this commit).
- `mix format --check-formatted` clean on all four modified files.
- `mix credo --strict` 0 findings on the three modified `lib/` files.
- `mix test` not runnable in this sandbox (no Postgres), so the LV +
  context tests should be re-run before the next release. The behaviour
  changes are: (a) `do_bulk_move` now skips already-deleted UUIDs (no
  existing test asserts the prior pass-through behaviour), (b) the
  `:catalogue_bulk_change` tuple is now 5-arity instead of 6 (the one
  test that sends it was updated in the same commit), (c)
  `bulk_restore_items` is now transactional (no behaviour change for
  the existing tests since they're single-connection).

## Related

- Previous PR: [#24](/dev_docs/pull_requests/2026/24-pdf-library-quality-sweep/) (PDF library Phase 2 sweep)
- Companion PR: none — this is self-contained to phoenix_kit_catalogue.
- AGENTS.md additions: Soft-Delete System (rewritten), CatalogueDetailLive layout (new section), Item-disposition modal (new section).
