# C0 Visual + Test Baseline (2026-04-26)

Captured before the Phase 2 quality sweep starts. Diff against these
in the final browser-verification step.

## Visual baselines

Captured via Playwright MCP at 1280×800 viewport, full-page mode,
phoenix_kit_parent on `localhost:4000`, locale `ja`, logged in as
`max@don.ee`. Fixture data is the local dev DB (3 catalogues — Smart
Test (1 item), Test 1 (310 items), Test 2 (74 items); 2 manufacturers;
3 suppliers; 107 activity events).

| # | Page | URL | Screenshot |
|---|------|-----|------------|
| 01 | Catalogues list | `/phoenix_kit/ja/admin/catalogue` | `catalogue_baseline_01_catalogues.png` |
| 02 | Manufacturers list | `/phoenix_kit/ja/admin/catalogue/manufacturers` | `catalogue_baseline_02_manufacturers.png` |
| 03 | Suppliers list | `/phoenix_kit/ja/admin/catalogue/suppliers` | `catalogue_baseline_03_suppliers.png` |
| 04 | Import wizard | `/phoenix_kit/ja/admin/catalogue/import` | `catalogue_baseline_04_import.png` |
| 05 | Events feed | `/phoenix_kit/ja/admin/catalogue/events` | `catalogue_baseline_05_events.png` |
| 06 | New catalogue form | `/phoenix_kit/ja/admin/catalogue/new` | `catalogue_baseline_06_new_catalogue.png` |
| 07 | Catalogue detail (Test 1, 310 items, nested categories) | `/phoenix_kit/ja/admin/catalogue/019d1330-c5e0-7caf-b84b-91a4418f67f2` | `catalogue_baseline_07_catalogue_detail.png` |
| 08 | Smart catalogue detail | `/phoenix_kit/ja/admin/catalogue/019dc83f-2351-78be-90e8-da56caaa51cd` | `catalogue_baseline_08_smart_catalogue_detail.png` |
| 09 | New manufacturer form | `/phoenix_kit/ja/admin/catalogue/manufacturers/new` | `catalogue_baseline_09_new_manufacturer.png` |

What to look for during the post-sweep diff:

- Sidebar present, Catalogue subtabs visible (Catalogues / Manufacturers
  / Suppliers / Import / Events)
- Header bar with avatar, theme switcher, csrf token
- Card-vs-table view toggle on list pages
- Form tabs (Details / Metadata / Files) on catalogue and item forms;
  category form is tabless (featured image only)
- Status badges coloured (green Active, red Deleted, yellow Archived)
- Status text **English** ("Active", "Deleted") even on `/ja/` pages
  — this is the `String.capitalize(status)` bug from the catalogue
  hand-off notes; **the post-sweep screenshots should show translated
  status labels** ("有効" or whatever the gettext catalog provides),
  which is a structural diff to verify.
- Activity feed displays action atoms as coloured pill badges
  (`item.created`, `catalogue.updated`, `import.completed`, etc.)
- New catalogue form: tabs visible, language strip with `EN-US ★` +
  41 other locale chips, kind dropdown, markup/discount + status
  selects, footer buttons (Cancel, Create Catalogue)
- Manufacturer form: linked-suppliers chip strip, "Click to toggle
  supplier associations." hint text below

## Test baseline

```
mix test
598 tests, 324 failures
```

All 324 failures are the same family: `Postgrex.Error 42703
(undefined_column) column "kind" of relation "phoenix_kit_cat_catalogues"
does not exist`. The V102 smart-catalogues migration
(`test/support/postgres/migrations/20260420000000_add_v102_smart_catalogues.exs`)
exists in the test/support/postgres/migrations/ directory but the
`test_helper.exs` does NOT call `Ecto.Migrator.run/3`, so the test DB
sits at the V87/V96 schema and any schema operation that touches
`kind` / `discount_percentage` / `markup_percentage` / `parent_uuid`
fails.

C7 (test infra) fixes this by either:

1. Calling `Ecto.Migrator.run(Test.Repo, "test/support/postgres/migrations", :up, all: true)`
   from `test_helper.exs`, OR
2. Folding all the post-V87 changes (V96, V97, V102, V103, attachments,
   metadata) into the base `20260318172858_catalogue_setup.exs` so a
   fresh `mix test.setup` produces the right schema in one shot.

Until C7, **all 324 failures are pre-existing** and the C0 floor is
"598 tests, 324 failures (all schema-mismatch)". The Phase 2 sweep
should bring this to **0 failures** with the new infra.

Pre-existing warnings (compile, not test):

- None observed in `mix compile` or `mix test` output.

## Post-sweep browser diff (2026-04-26)

Captured `catalogue_after_*.png` for the four most-deformable surfaces
(catalogues list, smart catalogue detail, events feed, new catalogue
form) and diffed visually against the baselines:

| # | Page | Diff |
|---|------|------|
| 01 | Catalogues list | **Structurally identical** to `catalogue_baseline_01_catalogues.png`. Sidebar present, header present, tabs render, status badges colored, table rows present. |
| 05 | Events feed | **Structurally identical**. Activity rows + filter dropdowns + colored action pills + relative timestamps all rendering. |
| 06 | New catalogue form | **Structurally identical**. Tabs (Details/Metadata/Files), language strip, Name/Description, Kind/Markup/Discount/Status dropdowns, Cancel/Create buttons all present. |
| 08 | Smart catalogue detail | **Structurally identical**. Add Category / Add Item buttons, search input, Services category header, items table, "All items loaded" sentinel. |

Status labels still render in English ("Active") in the `ja` locale —
expected: the `gettext("Active")` call resolves to the source string
when the `.po` catalog has no `ja` translation for that key. Pre-sweep
code did `String.capitalize("active") = "Active"` (English-pinned at
the source); post-sweep does `gettext("Active")` (translatable —
emits the key for `mix gettext.extract` to pick up). The visible
result is the same in this locale today; the structural fix means a
future `.po` update will make it translate without any code change.

No structural regressions observed: no missing sidebar, no missing
header, no broken layout grid, no Tailwind classes that didn't apply,
no modal/dropdown that doesn't open, no form sections that
disappeared, no status badges that lost color.
