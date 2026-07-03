# Review — PR #40: Catalogue table stack + PRO100 import/export rework

Merged as `f8cb518` (fork sync from `timujinne/main`). Reviewed against the
Phoenix/LiveView thinking skill, cross-checked line-by-line against the two
design docs this PR itself added (`dev_docs/2026-06-27-catalogue-table-stack-design.md`,
`dev_docs/2026-06-28-catalogue-import-rework-design.md`).

**Scope note:** this PR bundles four earlier "fix N code-review findings"
commits (`2a40cac`, `d5af275`, `e5e40fe`, `960330c`) from a prior review pass
on the same branch. This review does not re-report what those already fixed
(verified each is present and correct — see inline notes below) and instead
covers the rest of the ~6,660-line diff: the new table-config/view-config
toolkit, `CataloguesLive`'s near-total rewrite, the PRO100 import pipeline,
`ImportLive`'s new Source/Format wizard branch, and the `PdfLibraryLive` /
`CatalogueDetailLive` changes.

**Overall:** ambitious, well-designed change — the self-contained table
toolkit avoids a host-app dependency exactly as the design doc requires, and
the PRO100 sync flow (parse → match → plan → preview → apply → report) is a
clean pipeline with good separation of pure logic from the LiveView. The
findings below are real bugs the size of the diff let slip through, not
design objections — nothing here contradicts the architecture.

---

## 1. Per-user view-config writes for one tab silently revert another tab's earlier save in the same session — **high**

`CataloguesLive.put_cfg/3` persists via `ViewConfig.save/3`, which writes the
**entire** `custom_fields` column (a plain Ecto `cast`, not a JSONB merge —
confirmed in `PhoenixKit.Users.Auth.update_user_custom_fields/3`) built from
whatever `user.custom_fields` snapshot it's handed:

```elixir
defp put_cfg(socket, scope, cfg) do
  user = socket.assigns[:phoenix_kit_current_user]
  _ = PhoenixKitCatalogue.Web.ViewConfig.save(user, scope, cfg)
  assign(socket, :view_configs, Map.put(socket.assigns.view_configs, scope, cfg))
end
```

`put_cfg` discarded the `{:ok, updated_user}` result and never refreshed
`phoenix_kit_current_user` in the socket. So: change sort on the Catalogues
tab (persists fine) → switch to Suppliers, toggle a filter → that second save
rebuilds `custom_fields` from the **mount-time** snapshot, silently reverting
the first tab's change. Deterministic within a single session, not just a
multi-tab race — defeats the PR's headline feature (durable per-scope
persistence). No test exercises `put_cfg` across scopes, so it shipped
unnoticed. The correct pattern already exists in `phoenix_kit` core
(`phoenix_kit_web/live/users/users.ex`): reassign the socket from the save's
return value.

**Fix applied** — `put_cfg/3` now assigns `:phoenix_kit_current_user` from
`ViewConfig.save/3`'s `{:ok, updated_user}` before writing the next scope.

---

## 2. "Apply" on the Columns modal silently resets sort away from the default — **high**

`"name"` is `managed?: false` in `TableConfig.columns/1` for all three scopes
(it's always shown, never hideable) — which means it's structurally excluded
from `managed_columns/1` and therefore from `validate_columns/2`'s output.
`apply_columns` used that same list to decide whether to keep the current
sort:

```elixir
cfg = if cfg.sort_by in ids, do: cfg, else: %{cfg | sort_by: List.first(ids)}
```

Since the documented default sort is `name asc` and `"name"` can never be a
member of `ids`, **the very first Apply click** any user makes (even with no
edits) silently rewrites `sort_by` to whatever column happens to be first
(e.g. `"folder"`) and persists it. Compounding this: `table_toolbar`'s sort
dropdown builds its options from `TableConfig.sortable_visible(scope,
cfg.columns)` — also `"name"`-excluded — so **"Name" never appears as a sort
option at all**, even though it's fully sortable via the table header. In
card view there's no header to fall back on, so there was no UI path back to
sorting by name once it was reset.

**Fix applied** — `apply_columns`'s membership check now includes `"name"`
(`cfg.sort_by in ["name" | ids]`), and the toolbar's `selected` list is
`["name" | @cfg.columns]` so "Name" is a selectable sort option.

---

## 3. Switching Source/Format mid-wizard after a file is already parsed silently runs the wrong import path — **high**

`continue_or_parse/1` routes to `:map` (the Universal mapping step) whenever
`socket.assigns.filename` is set, regardless of the currently selected
Source:

```elixir
defp continue_or_parse(socket) do
  if socket.assigns.filename do
    ...
    {:noreply, assign(socket, step: :map, ...)}
  else
    parse_uploaded_file(socket)
  end
end
```

`apply_source_format/2` only reset `selected_format` on a source change — it
never touched `filename`/`ets_table`/`column_mappings`. Reproduction: upload
a Universal spreadsheet, reach `:map`, `go_back` to `:upload` (which doesn't
clear `filename`; the template still shows the "already parsed" panel and the
Source/Format selects stay live) → switch Source to PRO100 + Format Furniture
→ click Continue. `continue_or_parse` sees `filename` still set and jumps
straight into the **old Universal `:map` UI with the stale spreadsheet's
headers/mappings** — `Pro100Parser`/`Matcher`/`Pro100Plan` are never invoked.
Completing the wizard from there silently runs the Universal create-item path
instead of the PRO100 update-only sync the user explicitly picked. Untested —
`import_live_pro100_test.exs` only exercises freshly-mounted views.

**Fix applied** — `apply_source_format/2` now resets every parsed-file assign
(mirroring `clear_file`'s reset, factored into a shared `reset_parsed_file/1`)
whenever the source changes OR the format actually changes on an
already-parsed file. Left alone on unrelated param changes (e.g. picking a
catalogue) so it doesn't clobber an in-progress upload for no reason.

---

## 4. Mobile card view shows the wrong price — raw `base_price`, not the marked-up sale price — **high**

`CatalogueDetailLive`'s new active-items mobile card renders:

```elixir
{if item.base_price, do: Decimal.to_string(item.base_price, :normal), else: "—"}
```

under a "Price" label. The desktop table for the identical row uses
`<.item_pricing_cell>`, which renders `Catalogue.item_pricing(item).sale_price`
— `base_price` with the item's/catalogue's effective markup % applied
(`Item.sale_price/2`). Markup is a core, documented pricing feature
(AGENTS.md § Pricing). Any item/catalogue with a non-zero markup shows a
**different, lower** number on mobile than on desktop for the same row —
directly misleading on a commerce catalogue, and `Catalogue` was already
aliased in this file.

**Fix applied** — the card now renders
`Catalogue.item_pricing(item).sale_price`, matching the desktop cell.

---

## 5. Folder filter never offers "Unfiled (root)", and even a naive fix would collide with the "clear filter" sentinel — **medium**

The design doc calls for "All folders / Unfiled (root) / each folder."
`TableQuery.enum_options/3`'s folder clause explicitly rejects rows with a
nil/blank `folder_uuid`, so no "Unfiled" option was ever generated. Separately,
`to_string(nil) == ""` in Elixir, and `filter/2` already treats an empty
string as "no filter set" — so a naive fix that reused `""` as the unfiled
value would be silently swallowed by the existing "clear filter" branch
rather than filtering to unfiled rows.

**Fix applied** — added a dedicated sentinel
(`TableQuery.unfiled_folder_value/0`, `"__unfiled__"`), a `filter_match?`
clause matching `is_nil(row[:folder_uuid])`, and a LiveView-side
`folder_filter_options/1` that prepends a localized "Unfiled (root)" option
(only when at least one row is actually unfiled, matching how every other
option is pruned to values that occur). Covered by a new
`table_query_test.exs` case.

---

## 6. PRO100 duplicate-item merge (the just-fixed `960330c` bug) was still incomplete — a revert-to-original row could lose to an earlier row's stale change — **medium**

`960330c` fixed the "two different values" collision (multiple PRO100 rows
resolving to the same catalogue item) by folding per-row `changes` maps with
`Map.merge/2`, last-row-wins. But each row's diff was computed independently
against the **pristine pre-import `item`**, not the running state. A row
whose raw value happens to equal the *original* DB value produces an **empty**
diff — so it contributes no key to the `Map.merge` and can't overwrite an
earlier row's real change, even when it's the authoritative last row:

- `item.base_price = 80`. Row 1 (earlier in file): `100` → recorded
  `{80, 100}`. Row 2 (later, same item via a digits-only collision): `80`
  (same as the true original) → looks like "no change" against the pristine
  item, contributes nothing.
- `Map.merge` keeps row 1's `80 → 100`. The plan applies price `100`, even
  though the last (authoritative) row said the price should stay `80`.

Not caught by `960330c`'s own regression test, which only exercised two
*different, non-reverting* values.

**Fix applied** — reworked `Pro100Plan.build/2` to group rows by item UUID
and diff only the **last row in file order** against the true original
`item` (mathematically equivalent to a correctly-threaded running-baseline
diff, since every row unconditionally asserts a value when present — see the
in-code comment for the full argument). Earlier rows' diagnostic flags (e.g.
`:unit_unrecognized`) are still unioned in, since they're informational and
non-exclusive, not per-item state. This also simplified the module — the old
`merge_changes/2` helper is gone. Added a regression test for the
revert-to-baseline case; the existing `960330c` regression test still passes
unchanged.

---

## 7. Ambiguous PRO100 matches reported no actionable detail — **low/improvement**

`Matcher.resolve/2` returns `{:ambiguous, items}` with the actual colliding
items, but `Pro100Plan.build/2` discarded them, so the report said only "Row
X: multiple items match" — no SKU/name to act on. Cheap fix while already
touching this code path.

**Fix applied** — the skip entry now carries `items`, and
`ImportLive.sync_skip_reason/1` lists their SKU/name in the message. Covered
by a new `Pro100PlanTest` case.

---

## 8. Desktop card/table toggle on the active items list exposes a card view missing bulk-select and drag-reorder — **low/improvement**

The new mobile card fallback (`a853660`) passed `toggleable={true}` without
`show_toggle={false}` on `CatalogueDetailLive`'s active-items `table_default`.
`show_toggle` defaults to `true`, so — unlike the commit's stated "desktop
keeps the existing table… unchanged" — a desktop admin gets a manual toggle
button into card view. But `bulk_select_header_cell` (select-all) and
`sortable_tbody`'s drag handles only exist in the table branch; the card has
neither. The file's own established pattern (the deleted-items list two
lines below) already solves this correctly via `show_toggle={false}` plus a
separate `<.view_mode_toggle>`.

**Fix applied** — added `show_toggle={false}` to the active-items
`table_default`; mobile still gets the card automatically via the responsive
default, desktop keeps only the table. Updated an adjacent comment that had
gone stale ("the active list is table-only").

---

## Verified correct — prior-pass fixes and other hunted issues

- **`2a40cac`, `d5af275`, `e5e40fe`** (CataloguesLive stale-search cleanup +
  Enter-key search submit + formatter dedup; ImportLive JSON-detection +
  ETS-reset + changeset-error dedup; ViewConfig stale-filter-key stripping) —
  all present, correct, and (for `e5e40fe`) covers every `ViewConfig.load/2`
  read path. Swept the whole `catalogues_live.ex` template for orphaned
  `phx-click`/`phx-change`/`phx-submit` beyond the three named findings —
  none found (one intentionally-unreachable `clear_filter` handler remains;
  harmless, the `enum_filter` prompt option already achieves the same UX via
  `set_filter`, left as-is rather than churning a working no-op).
- **`mount/3` vs `handle_params/3`** — swept `CataloguesLive`, `ImportLive`,
  `PdfLibraryLive`: no DB/context query sits in `mount/3` anywhere touched by
  this PR; all data loading is `connected?`-gated in `handle_params/3` or an
  event handler.
- **Per-tab state isolation** in `CataloguesLive` — every column/sort/filter/
  view event resolves `active_scope(socket.assigns)` before touching
  `@view_configs`; no cross-tab bleed.
- **Folder modal** — full parity with the removed inline tree (create/rename/
  move/trash/restore/active-trash-toggle), matching the design doc's explicit
  regression check.
- **PRO100 pipeline** — column mapping traced byte-for-byte against both
  fixtures; BOM/CRLF/bare-LF/truncated/empty-file handling; `digits_only`
  genuinely shared (not duplicated) between import and export;
  `data["pro100"]` merge scoped to that one subkey (doesn't clobber
  `featured_image_uuid`/other `item.data` keys); unit-alias fallback can't
  null an existing valid unit; `Export.Pro100`'s constant fallback applies
  per-column, not per-row, so a partial `data["pro100"]` still round-trips
  correctly; per-row `update_item` failures (no enclosing transaction) don't
  abort the batch, matching the design.
- **No N+1** — `ImportLive`'s PRO100 sync loads all catalogue items once and
  builds an in-memory match index, per the design.
- **PdfLibraryLive** — event sweep clean, PubSub subscription/handler
  untouched by the migration, no query in `mount`. It has no `TableConfig`
  scope of its own (hand-rolled fixed columns, no per-user persistence) —
  consistent with the design doc's non-goal (only catalogues/suppliers/
  manufacturers are in scope), not a defect, but worth a follow-up if the PDF
  library is expected to reach parity later.

## Noted but not fixed (test-coverage / UX gaps, not correctness bugs)

- **Malformed PRO100 price is silently dropped**, not flagged — a
  non-numeric `c4` parses to `nil`, which `price_change/2`'s catch-all treats
  as "no change," so a bad price is invisibly ignored rather than surfaced in
  the report. Low-frequency (would require a hand-corrupted file); flagging
  for a future pass rather than fixing now to keep this review's diff
  reviewable.
- **BOM-stripping is dead code from the test suite's perspective** — neither
  fixture (`furniture_8.txt`, `materials_3.txt`) actually contains a leading
  BOM despite a test named after it; bare-LF tolerance is only covered
  incidentally. Worth a dedicated unit test, not a code fix.
- **PRO100 "Apply" runs fully synchronously** inside `handle_event`, blocking
  the LiveView process for the whole batch with only a static "Applying…"
  button — no `start_async`, unlike the Universal import path. A UX gap for
  large files, not a correctness issue; no duplicate-`start_async`-name race
  exists here since there's no async step at all for this action.

---

## Verification

`mix format` clean. `mix compile --warnings-as-errors` clean. `mix credo
--strict`: baseline `main` (before this review's changes) already exits
non-zero with 14 pre-existing Design/Readability/Refactor-level suggestions
unrelated to this PR's diff; this review's changes add two more of the same
already-pervasive "nested module could be aliased" suggestion (matching 12
existing instances of the identical pattern in the same files) and otherwise
net-fewer findings than baseline (a nesting-depth suggestion was resolved as
a side effect of splitting up `apply_source_format/2`) — confirmed via a
before/after diff, not just eyeballing the count. `mix dialyzer`: see below.
`mix test` could not run in this sandbox (`test_helper.exs` shells out to
`psql` to probe for a local Postgres; the binary isn't installed here) — new
tests were added for every fix that's expressible as pure logic
(`Pro100PlanTest`, `TableQueryTest`) and reviewed by manual trace against the
fixtures/design docs; the LiveView-level fixes (findings 1–4, 8) could not be
covered by a new automated test in this environment and should get a
DB-backed regression test in a follow-up pass.
