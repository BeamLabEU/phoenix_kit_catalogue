# PR #9: Catalogue improvements — paged search, item markup override, import wizard expansion

**Author**: @mdon (Max Don)
**Reviewer**: @fotkin (Dmitri)
**Status**: In Review
**Commits**: `77f9c40..1fe4cd6`
**Date**: 2026-04-15
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/9

## Goal

Ship three coherent feature additions to the catalogue module:

1. **Paged search with infinite scroll + per-item markup override** (77f9c40)
2. **Import wizard improvements** — language-aware categories, inline
   category creation, upload race-condition fix, sample-data polish (9c0be24)
3. **Manufacturer + supplier pickers** in the import wizard (1fe4cd6)

Requires the V97 migration in core `phoenix_kit` (separate PR) for the
per-item `markup_percentage` column.

## What Was Changed

22 files, +3166 / -288. Key touch points:

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue.ex` | `:limit`/`:offset` opts on all three search functions; new `count_search_items*` companions; `item_pricing/1` now exposes `catalogue_markup`, `item_markup`, effective `markup_percentage` |
| `lib/phoenix_kit_catalogue/schemas/item.ex` | New nullable `markup_percentage`; `sale_price/2` transparently honors the override; new `effective_markup/2` helper |
| `lib/phoenix_kit_catalogue/import/executor.ex` | Three-phase executor (get-or-create → item insert → M:N link); manufacturer + supplier resolution; language-aware category get-or-create |
| `lib/phoenix_kit_catalogue/import/mapper.ex` | New `:markup_percentage` and `:supplier` targets; multilingual synonym detection |
| `lib/phoenix_kit_catalogue/import/parser.ex` | Strip fully-empty columns; keep columns with real headers but empty data |
| `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` | `start_async` search with query-equality guard; infinite-scroll sentinel; paged `load_next_search_batch` |
| `lib/phoenix_kit_catalogue/web/catalogues_live.ex` | Same async search pattern for global cross-catalogue search |
| `lib/phoenix_kit_catalogue/web/import_live.ex` | Generic `<.party_picker>` / `<.new_party_form>`; four-mode vocabulary (`:none`/`:column`/`:create`/`:existing`) for category, manufacturer, supplier; `Repo.transaction` wraps the three `:create`-mode resolutions; upload race guard |
| `test/support/postgres/migrations/20260415011000_add_item_markup_override.exs` | Local test-DB mirror of core V97 |

### Schema change

```elixir
# phoenix_kit_cat_items: new nullable column
field(:markup_percentage, :decimal)
# nil  = inherit catalogue.markup_percentage (pre-V97 behavior)
# 0    = sell at base_price even when catalogue has markup
# any  = override
```

## Review — Strengths

- **Search async race handling** (`catalogue_detail_live.ex:440-497`) is
  textbook-correct: `start_async` cancels the prior in-flight task;
  `handle_async(:search, {:ok, {query, _, _}})` guards with
  `socket.assigns.search_query == query`; `:exit` distinguishes
  `:shutdown`/`:killed`/`{:shutdown, _}` (expected cancellation → noop) from
  real crashes (→ flash + log). Most LiveView code gets this wrong.
- **Transaction scope** in `import_live:426-436` wraps exactly the three
  `:create`-mode resolutions — minimal scope so modes that don't create
  anything pay zero cost. A rollback surfaces the original error message
  back through the `with`.
- **Per-item markup semantics** (`schemas/item.ex`): `nil` inherits, `0`
  overrides to "no markup" — covered by `effective_markup/2` and worked
  examples in the docstring. `item_pricing/1` returns both markups so
  callers can render "item overrides catalogue 20% → 50%" UI.
- **M:N link idempotency** via unique-constraint catch in
  `Executor.attempt_link/2` + `unique_constraint_error?/1`.
- **`skip_derive: true`** on item insert (`executor.ex:278`) avoids one DB
  roundtrip per row and is justified by the call-site comment.
- **`mount/3` hygiene**: DB only runs under `if connected?(socket)`, so
  the dead HTTP mount doesn't duplicate queries.
- **Deterministic paging order** via `[asc: i.name, asc: i.uuid]` — avoids
  the "same row appears on two pages" bug that `ORDER BY name` alone hits
  on duplicate names.
- **Markup-match posture** (`mapper.ex:275`): two items only match for
  duplicate-detection when they share the same markup stance (both
  inheriting / both overriding to the same value). Without this, importing
  a price-list of overrides would silently collapse onto inheritance-only
  existing rows.

## Review — Issues

### Correctness / load

1. **`load_next_search_batch` is synchronous** (`catalogue_detail_live.ex:501`,
   and the twin in `catalogues_live.ex`). The initial search uses
   `start_async` but scroll-page is a blocking DB call inside
   `handle_event`. For a 50k-item catalogue with `ILIKE` on `data::text`,
   every scroll page freezes the socket — user can't type, can't click,
   other `handle_info` messages queue up behind it. Should also go through
   `start_async(:search_page, …)` with a guard on `(query, offset)`.
   **→ Addressed locally; see "Local fixes" below.**

2. **Executor phase 1 is not transactional** across entity types
   (`executor.ex:59-87`). `create_categories` → `create_manufacturers` →
   `create_suppliers` run as three independent loops. If the manufacturer
   loop raises (DB connection drop, a bug in Catalogue.create_*) midway,
   orphaned categories persist. The `:create`-mode transaction at the LV
   layer only covers user-picked single-entity resolution, not the
   column-mode get-or-create phase. Per-name changeset errors are logged
   + skipped (no rollback), so the only failure mode this affects is a
   raise — rare but worth the 0-cost wrapper.
   **→ Addressed locally; see "Local fixes" below.**

3. **`Mapper.detect_existing_duplicates/3`** (`mapper.ex:209-225`) loads
   every non-deleted item in the catalogue into memory, then nests
   `Enum.any?` inside `Enum.count` → **O(N × M)**. On a 20k-item catalogue
   with a 5k-row import that's 100M comparisons + 20k Ecto structs
   allocated. Candidate for a hashed-lookup map keyed on
   `{name, sku, price, markup, category_uuid, lang_name}` built once from
   `existing_items`, then per import-row lookup is O(1).

4. **Search against `i.data::text`** (`catalogue.ex:1939` and peers) —
   `fragment("?::text ILIKE ?", i.data, ^pattern)` forces a full JSON
   text scan with no index reachability, and matches internal keys like
   `_primary_language`. Works, but the "stream through catalogues with
   thousands of items" claim from the PR description won't hold at 100k+
   items without a GIN index or a narrower search surface (e.g., only
   indexed translations via `->> '_name'`).

### Polish / scale

5. **`Parser.reject_empty_columns`** (`parser.ex:190`) uses `Enum.at/3`
   in nested loops over lists — O(rows × cols × col_idx). Fine for 10k
   rows; won't scale to 100k. Easy fix: convert rows to tuples once, or
   transpose-then-filter.

6. **`file_binary` retained in socket assigns** (`import_live.ex:612`) —
   the full XLSX binary lives in LiveView process memory until
   `import_another`. For a 30MB XLSX that's 30MB per concurrent import
   session. Only used by `select_sheet` to re-parse. Could keep the temp
   file path and re-read on demand.

7. **Search query body duplication**: the six search/count functions
   (`catalogue.ex:1923..2118`) share nearly-identical WHERE clauses. A
   private `base_search_query/2` + `limit`/`offset`/`select(count)`
   composition would eat ~80 lines. Pure cleanup.

8. **`Parser.detect_csv_separator`** scores by first-line count, which
   misfires when quoted fields contain the separator (e.g.
   `"a,b";"c,d"`). Edge case, low priority.

9. **`Mapper.validate_item_attrs`** reports only the first error per row
   (`name` missing hides a concurrent `_price_error`). Minor UX — user
   fixes names, then sees price errors on the next run.

## Testing

- Clean `mix compile`.
- `mix format --check-formatted` passes.
- `mix credo --strict` reports zero issues across 45 files, 691 mods/funs.
- `mix test` not runnable in this sandbox (`psql` not installed). Test
  coverage added for Executor phases, Mapper target detection, Parser
  empty-column stripping, Catalogue search/count, component rendering.

## Local fixes (this reviewer)

Two followup commits land on top of Max's branch:

1. **Async scroll paging** — `load_next_search_batch` in both
   `catalogue_detail_live.ex` and `catalogues_live.ex` moved onto
   `start_async(:search_page, …)`. The `handle_async` guard checks
   `{query, offset}` so a newer search that supersedes a mid-flight page
   still drops cleanly. `search_loading` is cleared on completion or
   on a real crash; cancellation paths are no-ops just like `:search`.

2. **Phase 1 transaction wrap** — `Executor.execute/4` now runs the three
   get-or-create loops inside a single `Repo.transaction`. Per-name
   changeset errors still get logged + skipped (unchanged); what the wrap
   actually catches is a raise / DB drop mid-phase-1, rolling back any
   entities the earlier loops did persist. Cost on fixed-uuid-only
   imports is a single empty-transaction roundtrip.

## Notes for Max

Items 3–9 above are suggestions, not blockers — happy to ship #9 as-is
and file them as followups. The two correctness items (1, 2) we fixed
on the branch; review those commits and holler if the shape doesn't fit
your mental model of the LV.
