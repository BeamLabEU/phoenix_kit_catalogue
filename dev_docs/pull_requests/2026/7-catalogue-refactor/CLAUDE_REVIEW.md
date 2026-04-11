# Code Review — PR #7: Catalogue Refactor

**Reviewer:** Claude (claude-sonnet-4-6)  
**Date:** 2026-04-11  
**Scope:** Correctness · Security · OTP/Phoenix best practices · Test coverage · API design

---

## Summary

This is a substantial, well-engineered refactor. The context module is thoroughly documented, transaction safety is generally sound, the new infinite-scroll architecture is clean, and the test suite covers a wide range of scenarios. The issues below range from real bugs to quality-of-life improvements. Nothing is a showstopper, but items 1 and 4 are genuine correctness bugs worth fixing before merge.

---

## 1. Correctness

### 1.1 `next_category_position/1` called outside the transaction — race condition (BUG)

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:1170`

```elixir
def move_category_to_catalogue(%Category{} = category, target_catalogue_uuid, opts \\ []) do
  source_catalogue_uuid = category.catalogue_uuid
  next_pos = next_category_position(target_catalogue_uuid)   # ← outside tx

  result =
    repo().transaction(fn ->
      repo().one!(from(c in Category, where: c.uuid == ^category.uuid, lock: "FOR UPDATE"))
      ...
```

`next_category_position/1` runs a `MAX(position)` query *before* the transaction opens. If two concurrent moves target the same catalogue, both can observe the same `max_position` and both compute the same `next_pos`, resulting in two categories at identical positions. The fix is to move the call inside the transaction:

```elixir
result =
  repo().transaction(fn ->
    repo().one!(from(c in Category, where: c.uuid == ^category.uuid, lock: "FOR UPDATE"))
    next_pos = next_category_position(target_catalogue_uuid)  # inside tx
    ...
```

### 1.2 `restore_catalogue` over-restores items deleted before the catalogue was trashed

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:672–701`

```elixir
from(i in Item,
  where: i.catalogue_uuid == ^catalogue.uuid and i.status == "deleted"
)
|> repo().update_all(set: [status: "active", updated_at: now])
```

This restores **all** deleted items in the catalogue — including ones the user had individually trashed before the catalogue itself was trashed. The intent of "restore catalogue" is presumably to undo the cascade, not resurrect items that were separately deleted. The same issue applies to `restore_category/2` at line 1108.

Consider storing a `deleted_at` timestamp or a `deleted_by_cascade` boolean so restore operations can distinguish cascade-deleted records from individually-deleted ones. At minimum, document the current behaviour explicitly so callers aren't surprised.

### 1.3 `move_item_to_category` missing `FOR SHARE` lock — inconsistent locking strategy

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:1797–1804`

```elixir
defp resolve_move_attrs(category_uuid) when is_binary(category_uuid) do
  case repo().get(Category, category_uuid) do          # ← plain read, no lock
    %Category{catalogue_uuid: cat_uuid} ->
      {:ok, %{category_uuid: category_uuid, catalogue_uuid: cat_uuid}}
    ...
```

`create_item/2` acquires a `FOR SHARE` lock on the category row to prevent reading a stale `catalogue_uuid` during a concurrent `move_category_to_catalogue`. `move_item_to_category/3` calls `resolve_move_attrs` outside any transaction and without a lock, so it can read a stale `catalogue_uuid` if the target category is being moved at the same time. The item ends up with the old catalogue UUID.

Fix: wrap `resolve_move_attrs` in a transaction and add `lock: "FOR SHARE"` to the category query, mirroring `create_item`.

### 1.4 `confirm_delete!` pattern-match crash in `handle_event`

**File:** `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:167, 251`

```elixir
def handle_event("permanently_delete_item", _params, socket) do
  {"item", uuid} = confirm_delete!(socket)     # raises MatchError if type != "item"
```

```elixir
def handle_event("permanently_delete_category", _params, socket) do
  {"category", uuid} = confirm_delete!(socket)  # raises MatchError if type != "category"
```

A `MatchError` raised inside `handle_event` crashes the LiveView process. LiveView will restart the process and reconnect the client, but the user sees an abrupt UI reset. This can be triggered by a timing issue (user clicks Confirm after a stale confirm state from a different entity type) or by a crafted WebSocket message. Prefer a case match that returns a safe error path:

```elixir
def handle_event("permanently_delete_item", _params, socket) do
  case socket.assigns.confirm_delete do
    {"item", uuid} -> do_permanent_delete_item(socket, uuid)
    _ -> {:noreply, assign(socket, confirm_delete: nil)}
  end
end
```

### 1.5 `deleted_count_for_catalogue` issues two sequential queries

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:2062–2065`

```elixir
def deleted_count_for_catalogue(catalogue_uuid) do
  deleted_item_count_for_catalogue(catalogue_uuid) +
    deleted_category_count_for_catalogue(catalogue_uuid)
end
```

Two round-trips for what could be a single query. This function is called on every `reset_and_load`, which already fires five queries. Low priority, but worth consolidating.

---

## 2. Security

### 2.1 No authorization enforcement at the context layer

**File:** `lib/phoenix_kit_catalogue/catalogue.ex` (all mutation functions)

`actor_uuid` is accepted for activity logging only — the context module itself never checks whether the actor is permitted to perform an operation. This is a common Phoenix pattern (authorization lives in the controller/LiveView layer), but it means:

- Any code path that reaches the context bypasses access control.
- Tests and IEx sessions can perform unrestricted mutations.
- If a new API route or background job calls `Catalogue.trash_catalogue/2` without going through the LiveView, there's no safety net.

This is acceptable for an admin-only interface, but it should be a conscious, documented decision. Consider adding a note to the module doc: "Authorization is the caller's responsibility; this module does not perform permission checks."

### 2.2 `log_activity` silently discards all errors

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:60–67`

```elixir
defp log_activity(attrs) do
  if Code.ensure_loaded?(PhoenixKit.Activity) do
    PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
  end
rescue
  e ->
    Logger.warning("[Catalogue] Failed to log activity: #{Exception.message(e)}")
end
```

If the activity module is broken (DB down, schema mismatch, missing fields), every mutation silently succeeds without an audit trail entry. The `rescue` keeps the application alive, which is good, but the caller never knows logging failed. For compliance use cases, this is a silent data-loss scenario. Consider returning a `{:ok, result, :logging_failed}` tuple or emitting a telemetry event so monitoring can detect it.

### 2.3 JSON data field searched as raw text — potential for unexpected matches and slow queries

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:1909, 1950`

```elixir
fragment("?::text ILIKE ?", i.data, ^pattern)
```

Casting a JSONB column to text and using ILIKE is correct Elixir/Ecto but will match JSON punctuation (curly braces, quotes, key names), not just user-visible values. It is also unindexable and will do a full sequential scan on large tables. Consider whether this is intentional and document it, or use `jsonb_to_tsvector` / GIN indexing for production-scale data.

---

## 3. OTP/Phoenix Best Practices

### 3.1 `load_filter_options` fetches up to 1000 rows to build dropdowns

**File:** `lib/phoenix_kit_catalogue/web/events_live.ex:93–112`

```elixir
defp load_filter_options(socket) do
  if Code.ensure_loaded?(PhoenixKit.Activity) do
    all = PhoenixKit.Activity.list(module: "catalogue", per_page: 1000, preload: [])

    action_types =
      all.entries |> Enum.map(& &1.action) |> Enum.uniq() |> Enum.sort()
    ...
```

Loading 1000 activity records to find unique action and resource_type values is O(N) when a `SELECT DISTINCT action FROM ... WHERE module = 'catalogue'` query would be O(1) (especially with an index on `module, action`). For an activity feed that could have millions of entries, this is a scalability problem. The filter dropdowns will also silently become incomplete once there are more than 1000 events of any one type.

### 3.2 `InfiniteScroll` hook inlined in HEEx — duplicated between two LiveViews

**File:** `lib/phoenix_kit_catalogue/web/events_live.ex:362–382`  
**Also:** `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` (likely contains the same or similar hook)

The `InfiniteScroll` hook is defined inline in the render function of `EventsLive`. If a similar definition exists in `CatalogueDetailLive`, this is duplicated application logic in two places. Inline `<script>` tags in LiveView templates are executed on mount but also each time a partial page update triggers a DOM diff that includes the script node. The `||` guard prevents double-registration, but the duplication is a maintenance risk. Move the hook to the shared JS assets bundle.

### 3.3 `reset_and_load` fires 5+ sequential DB queries on every structural mutation

**File:** `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:317–351`

```elixir
defp reset_and_load(socket) do
  uuid = socket.assigns.catalogue_uuid
  deleted_count = Catalogue.deleted_count_for_catalogue(uuid)         # query 1+2
  ...
  catalogue = Catalogue.fetch_catalogue!(uuid)                         # query 3
  category_list = Catalogue.list_categories_metadata_for_catalogue(uuid, ...)  # query 4
  category_counts = Catalogue.item_counts_by_category_for_catalogue(uuid, ...) # query 5
  uncategorized_total = Catalogue.uncategorized_count_for_catalogue(uuid, ...) # query 6
```

Six queries on every trash/restore/reorder. For a detail page with interactive controls, this triggers on nearly every user action. Consider a single context function `catalogue_detail_summary/2` that returns all of this in 2–3 queries (or even 1 with CTEs), or use `Task.async_stream` to fan them out concurrently over the connection pool.

### 3.4 `swap_category_positions` doesn't re-fetch stale positions from socket

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:1227–1253`  
**Caller:** `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` (`reorder_category/3`)

The swap uses `cat_a.position` and `cat_b.position` from the in-memory structs. If another client has already reordered the same categories since these structs were loaded, the swap will operate on stale positions. The transaction prevents partial writes but doesn't detect conflicts. Using `FOR UPDATE` locks on both rows inside the transaction would close this window.

---

## 4. Test Coverage

### 4.1 No concurrency/race-condition tests for locking strategy

**Files:** `test/catalogue_test.exs`

The `FOR SHARE` / `FOR UPDATE` locking strategy is the most novel and fragile part of this refactor. There are no tests that fire concurrent transactions to verify the locks actually prevent stale reads. A basic concurrent test:

```elixir
test "item creation and concurrent category move produce consistent catalogue_uuid" do
  cat1 = create_catalogue(%{name: "Source"})
  cat2 = create_catalogue(%{name: "Target"})
  category = create_category(cat1)

  task_create = Task.async(fn -> Catalogue.create_item(%{name: "Race Item", category_uuid: category.uuid}) end)
  task_move   = Task.async(fn -> Catalogue.move_category_to_catalogue(category, cat2.uuid) end)

  {:ok, item} = Task.await(task_create)
  {:ok, _}    = Task.await(task_move)

  reloaded = Catalogue.get_item(item.uuid)
  assert reloaded.catalogue_uuid == cat2.uuid
end
```

This test would fail without the locking and passes with it — exactly what you want for a correctness regression suite.

### 4.2 No test for `search_items` / `search_items_in_catalogue`

**Files:** `test/catalogue_test.exs`, `test/web/catalogue_detail_live_test.exs`

`search_items_in_catalogue/2` is called from `CatalogueDetailLive.handle_event("search", ...)` (catalogue_detail_live.ex:94) but doesn't appear in `catalogue_test.exs`. The search logic includes ILIKE on three columns plus the JSONB field — each of these branches should have a test.

### 4.3 `restore_catalogue` over-restore behaviour not tested

**File:** `test/catalogue_test.exs`

No test verifies whether items deleted *before* the catalogue was trashed are or are not restored when `restore_catalogue/2` is called. Given the ambiguity discussed in §1.2, a test documenting the current behaviour (whichever it is) is important.

### 4.4 `item_pricing` fallback path not covered

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:1842–1868`

`safe_markup_for_item` has a rescue block that falls back to 0% markup when the catalogue association can't be loaded. There's no test for this code path (it would require simulating a DB error or creating an item with a missing catalogue association). At minimum, the fallback should be tested by passing an item with an unloaded association.

### 4.5 `events_live` filter UI roundtrip coverage

**File:** `test/web/events_live_test.exs`

The filter form uses `phx-change` to push to `handle_event("filter", ...)`, which builds a query string and calls `push_patch`. There's no test that verifies the selected filter persists across a page reload (i.e. that `apply_params/2` correctly round-trips filter values from the URL).

---

## 5. API Design

### 5.1 `next_category_position/1` is public but unsafe to call without a transaction

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:1265–1275`

This function is part of the public context API, which implies it's safe for callers to use directly. But it returns a non-atomic position that could race with concurrent inserts. If external callers use it to pre-compute a position before calling `create_category`, they'll have a race condition. Either make it private (`defp`) or document the requirement to call it inside a transaction.

### 5.2 `list_categories_metadata_for_catalogue` in `:deleted` mode returns all categories

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:779–794`

```elixir
:deleted -> query  # no filter — returns deleted AND non-deleted categories
```

The option is named `:deleted` but returns all categories (deleted + active), not only deleted ones. This is because the deleted-items view still needs to show which category each item belongs to. The behaviour is intentional but the name and docs are misleading. Consider renaming the mode to `:all` or `:with_deleted` to avoid confusion.

### 5.3 `ok_or_rollback` relies on exception-based rollback — not immediately obvious

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:453–454`

```elixir
defp ok_or_rollback({:ok, _}), do: :ok
defp ok_or_rollback({:error, reason}), do: repo().rollback(reason)
```

`repo().rollback/1` raises `Ecto.Rollback`, which propagates through `Enum.each` and is caught by the `repo().transaction/1` wrapper. This is correct Ecto usage but is non-obvious to maintainers unfamiliar with Ecto's transaction internals. A brief comment explaining the mechanism would prevent future "why does this work?" confusion.

### 5.4 `item_pricing/1` silently falls back to 0% markup on failure

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:1832–1868`

A DB error during `load_catalogue_markup` returns `Decimal.new("0")` — the item's price appears correct but is actually the bare base price with no markup applied. In a pricing context, silently showing wrong prices is a business risk. The fallback is logged as a warning, but consider surfacing this in the return value so callers can decide whether to show a "price unavailable" state.

### 5.5 `set_translation/5` distinguishes 2-arity vs 3-arity update functions via opts check

**File:** `lib/phoenix_kit_catalogue/catalogue.ex:2099–2107`

```elixir
if opts == [] do
  update_fn.(record, %{data: new_data})
else
  update_fn.(record, %{data: new_data}, opts)
end
```

This pattern dispatches on `opts == []` to decide arity. It means a caller who passes `opts: []` explicitly gets 2-arity dispatch. The function should either require the caller to always provide 3 arguments (making the update function always 3-arity), or use a protocol/behaviour pattern. A simpler fix: always call `update_fn.(record, %{data: new_data}, opts)` and ensure all update functions default `opts` to `[]`.

---

## 6. Minor / Nitpicks

| Location | Issue |
|---|---|
| `catalogue.ex:58` | `defp repo, do: PhoenixKit.RepoHelper.repo()` — dynamic lookup couples the context to a runtime helper. Makes unit testing the context in isolation (without the full OTP tree) harder. |
| `events_live.ex:183–193` | `summarize_metadata/1` renders metadata values as `"#{k}: #{v}"` with no truncation on the server side, relying on a CSS `max-w-[200px] truncate`. Long values will still be in the DOM (just hidden), which could be large. |
| `catalogue.ex:1564` | `string_keyed?/1` calls `hd()` on the key list. The empty-map guard on line 1564 protects against `Enum.EmptyError`, but mixed-key maps (atom + string keys) would misclassify based on whichever key happens to be first. This is an edge case in practice. |
| `catalogue_detail_live.ex:27` | `per_page = 100` for the detail view vs `per_page = 20` in `events_live.ex`. This is intentional (items vs events have different densities) but worth a comment. |
| `catalogue.ex:1993–1998` | `sanitize_like/1` escapes `\`, `%`, and `_` — good. Verify the ESCAPE clause is passed through to PostgreSQL when using Ecto's `ilike/2`; by default Ecto does not send an `ESCAPE` clause and PostgreSQL's default escape character for LIKE is `\`, so this should work, but it's worth confirming with a test. |

---

## Priority Checklist

| # | Issue | Priority |
|---|---|---|
| 1.1 | `next_category_position` outside transaction | **High** — real race condition |
| 1.3 | `move_item_to_category` missing `FOR SHARE` | **High** — inconsistent locking |
| 1.4 | `confirm_delete!` MatchError crash | **Medium** — degrades UX, exploitable via WebSocket |
| 3.1 | `load_filter_options` fetching 1000 rows | **Medium** — scalability issue |
| 1.2 | `restore_catalogue` over-restores | **Medium** — correctness/UX, needs decision |
| 4.1 | No concurrency tests | **Medium** — locking strategy unverified |
| 4.2 | No `search_items` tests | **Medium** — untested branch |
| 2.2 | `log_activity` silent failure | **Low** — audit gap |
| 5.1 | `next_category_position` public/unsafe | **Low** — API footgun |
| 5.2 | `:deleted` mode misleading name | **Low** — documentation |
