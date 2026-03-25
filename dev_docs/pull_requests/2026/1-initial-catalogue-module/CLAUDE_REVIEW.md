# Code Review: PR #1 — Initial Catalogue module with soft-delete, multilang, and full test coverage

**Reviewed:** 2026-03-23
**Reviewer:** Claude (claude-opus-4-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/1
**Author:** Max Don (mdon)
**Head SHA:** aa1839fe39c93d7b5f33e2495baab2619ced25e6
**Status:** Merged

## Summary

Initial implementation of the PhoenixKit Catalogue module — product catalogue management with manufacturers, suppliers, categories, and items. Includes soft-delete with cascading trash/restore, multilingual form support, DaisyUI-styled LiveViews, move operations, and 83 tests covering CRUD, cascade, restore, move, counts, and schema validations. 32 files changed, +5,812 lines.

## Issues Found

### 1. [BUG - CRITICAL] Category reordering race condition — non-atomic position swap
**File:** `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` lines 178-196
The position swap updates two rows sequentially without a transaction:
```elixir
Catalogue.update_category(cat_a, %{position: cat_b.position})
Catalogue.update_category(cat_b, %{position: cat_a.position})
```
If a concurrent request fires between these two updates, both categories can end up at the same position. A crash after the first update leaves positions in an inconsistent state.
**Fix:** Wrap in `Repo.transaction/1` with a temporary sentinel position, or use a single raw SQL `UPDATE ... CASE` statement.
**Confidence:** 90/100

### 2. [BUG - CRITICAL] `sync_manufacturer_suppliers` silently swallows errors
**File:** `lib/phoenix_kit_catalogue/catalogue.ex` lines 285-316
`link_manufacturer_supplier` and `unlink_manufacturer_supplier` return `{:ok, _}` or `{:error, _}`, but the sync function uses `Enum.each/2` which discards all return values and always returns `:ok`. A partial failure leaves the link state inconsistent with no signal to the caller or UI.
```elixir
Enum.each(to_add, &link_manufacturer_supplier(manufacturer_uuid, &1))
Enum.each(to_remove, &unlink_manufacturer_supplier(manufacturer_uuid, &1))
:ok
```
**Fix:** Use `Ecto.Multi` or collect results with `Enum.map` and check for errors. Return `{:ok, :synced}` or `{:error, failed_ops}`.
**Confidence:** 95/100

### 3. [BUG - HIGH] Incomplete upward cascade on item restore
**File:** `lib/phoenix_kit_catalogue/catalogue.ex` lines 858-873
`restore_item` restores the parent category if it's deleted, but doesn't check whether that category's parent catalogue is also deleted. If all three levels are trashed, restoring an item restores the category but leaves the catalogue in deleted state — the restored item and category are invisible in the active view.
**Fix:** After restoring the category, check `category.catalogue_uuid` and restore the catalogue if its status is `"deleted"`.
**Confidence:** 85/100

### 4. [BUG - HIGH] `next_category_position` race condition
**File:** `lib/phoenix_kit_catalogue/catalogue.ex` lines 698-707
```elixir
def next_category_position(catalogue_uuid) do
  query = from(c in Category, where: c.catalogue_uuid == ^catalogue_uuid, select: max(c.position))
  case repo().one(query) do
    nil -> 0
    max_pos -> max_pos + 1
  end
end
```
Two concurrent requests creating categories in the same catalogue will both read the same `max(position)` and produce duplicates. No unique constraint on `(catalogue_uuid, position)` to catch this.
**Fix:** Add a unique index on `(catalogue_uuid, position)` in a migration, and retry on conflict. Or use `SELECT ... FOR UPDATE` within the creation transaction.
**Confidence:** 85/100

### 5. [BUG - HIGH] `list_uncategorized_items_for_catalogue` ignores catalogue parameter
**File:** `lib/phoenix_kit_catalogue/catalogue.ex` lines 745-779
The first parameter is `_catalogue_uuid` (underscored — explicitly ignored). The function returns all uncategorized items globally, not scoped to the given catalogue. The public API promises per-catalogue filtering it doesn't deliver. Callers in `catalogue_detail_live.ex` pass a catalogue UUID expecting scoped results.
**Fix:** Items don't have a direct `catalogue_uuid` FK, so this requires either: (a) a subquery through categories to exclude items belonging to *other* catalogues, or (b) adding a denormalized `catalogue_uuid` to items. At minimum, rename to `list_uncategorized_items/1` and document the global scope.
**Confidence:** 95/100

### 6. [BUG - MEDIUM] Deleted item count uses two queries instead of one
**File:** `lib/phoenix_kit_catalogue/catalogue.ex` lines 931-945
`deleted_item_count_for_catalogue` makes two separate `repo().aggregate(:count)` calls (categorized + uncategorized) then sums them in Elixir. Could be a single query with `LEFT JOIN` or `UNION ALL`.
**Confidence:** 90/100

### 7. [BUG - MEDIUM] Category move doesn't validate target catalogue is active
**File:** `lib/phoenix_kit_catalogue/web/category_form_live.ex` lines 131-136
When moving a category to another catalogue, the form doesn't verify the target catalogue's status. A category could be moved into a deleted or archived catalogue, making it invisible.
**Fix:** Filter catalogue dropdown to active catalogues only, or validate in the context.
**Confidence:** 80/100

### 8. [NITPICK] Position field allows arbitrary values in form
**File:** `lib/phoenix_kit_catalogue/web/category_form_live.ex` line 253
The `<input type="number" min="0">` allows a user to enter position `9999` in a catalogue with 2 categories, creating large gaps in the sort order.
**Confidence:** 70/100

### 9. [NITPICK] Missing `validate_length` on string fields in schemas
**Files:** `lib/phoenix_kit_catalogue/schemas/*.ex`
Database columns have size constraints (e.g., `varchar(255)`) but schema changesets don't call `validate_length/3`. Errors surface as raw Postgres constraint violations instead of friendly changeset errors.
**Confidence:** 75/100

### 10. [NITPICK] Inconsistent error handling style
**File:** `lib/phoenix_kit_catalogue/web/catalogues_live.ex` lines 96-150
Manufacturer/supplier deletion uses `with`, while catalogue deletion uses `case`. Both are fine, but inconsistency makes the code harder to follow at a glance.
**Confidence:** 60/100

### 11. [OBSERVATION] No LiveView integration tests
Only context-level tests exist. No tests for mount, handle_event, or handle_params in any of the 7 LiveViews. Form submissions, view mode toggling, reordering, and move operations are untested at the web layer.

### 12. [OBSERVATION] No concurrency tests
No tests for `next_category_position` under concurrent load, category reordering race, or `sync_manufacturer_suppliers` partial failure. These are the areas most likely to surface bugs in production.

## What Was Done Well

- **Soft-delete cascade design** — the downward-trash / upward-restore pattern with transactions is well thought out and covers the common cases
- **Comprehensive context documentation** — every public function in `Catalogue` has `@doc` with type specs and IEx examples
- **83 tests** for context logic covering CRUD, cascade, restore, move, counts, and validations — solid foundation
- **Two-step permanent delete confirmation** — good UX safety pattern in all form LiveViews
- **Centralized `Paths` module** — no hardcoded URLs anywhere in the LiveViews
- **Clean module boundary** — single context module with data-only schemas, follows PhoenixKit conventions
- **Defensive test setup** — automatically skips integration tests when DB unavailable

## Verdict

**Approved with fixes** — solid first implementation with good architecture and test coverage. The three critical/high issues (reorder race, silent sync errors, incomplete restore cascade, misleading uncategorized API) should be addressed before high-concurrency production use. None are blockers for initial merge since the module is new and these are edge cases unlikely to hit during early development, but they should be tracked as follow-up work.
