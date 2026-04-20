## 0.1.10 - 2026-04-20

### Added
- **Smart catalogues** (`kind: "smart"`) — catalogues whose items are priced as a rule-driven function of other catalogues. New `CatalogueRule` schema (`phoenix_kit_cat_item_catalogue_rules`) and `put_catalogue_rules/3` replace-all API with duplicate detection, per-leg `value`/`unit` inheritance via `CatalogueRule.effective/2`, and `smart_rules.synced` activity logging (added/updated/removed counts). Requires phoenix_kit 1.7.102+ for the V102 migration.
- **Per-item discount override** — nullable `Item.discount_percentage` (`nil` inherits the catalogue's discount, any value including `0` overrides). Pricing chain is now `base → markup → discount`, exposed via `Item.final_price/3`, `Item.effective_discount/2`, `Item.discount_amount/3`, and the expanded `Catalogue.item_pricing/1`.
- **Smart-item defaults** — `Item.default_value` / `Item.default_unit` as fallbacks when a `CatalogueRule` row has `nil` value/unit (lets a user set "5% across everything" once and override specific catalogues).
- `list_items_referencing_catalogue/1` + `catalogue_reference_count/1` for warn-before-delete flows; `permanently_delete_catalogue/2` now refuses with `{:error, {:referenced_by_smart_items, count}}` when smart items still reference the catalogue, unless `force: true` is passed.
- `list_catalogues(kind: :smart)` filter; `Catalogue.move_item_to_catalogue/3` for moving smart items across catalogues (categories don't apply to smart items).
- Scoped search: `search_items/2` accepts `:catalogue_uuids` / `:category_uuids` filters composed via `where dynamic`; new `scope_selector` component pairs with it.
- `category_counts_by_catalogue/0` grouped-query helper.

### Changed
- **Context split** — extracted the monolithic `catalogue.ex` into 10 focused submodules (`Rules`, `Search`, `Manufacturers`, `Suppliers`, `Links`, `Counts`, `PubSub`, `Translations`, `Helpers`, `ActivityLog`). Public surface is unchanged — every caller still goes through `Catalogue.*` via `defdelegate`.
- All form LiveViews (catalogue / category / item / manufacturer / supplier) migrated to Phoenix 1.7 component-style `<.input>` / `<.select>` / `<.textarea>` / `<.checkbox>` bindings. The multilang wrapper now scopes only translatable fields (name / description) — pricing, classification, and actions render as siblings so a language switch doesn't re-mount them.

### Fixed
- Replace raising `confirm_delete!/1` with a safe `case`-match + `unexpected_confirm_event/2` fallback across all 5 delete handlers (item / category / catalogue / manufacturer / supplier). Malformed push events flash + log instead of crashing the LV.
- `Catalogue.ActivityLog.log/1` now rescues — activity-logging failures no longer crash the primary mutation, matching the AGENTS.md contract.
- New `log_operation_error/3` helper in both admin LVs — structured logs carrying `actor_uuid`, `entity_type`, `entity_uuid`, and `Ecto.Changeset.traverse_errors`-expanded field/message pairs so production incidents can be debugged from the log alone.
- Search task-exit logs now include query, offset, and `catalogue_uuid`.
- `phx-disable-with` on 9 destructive-action buttons (trash / restore on catalogue + category + item tables and cards) to prevent double-mutation on slow networks.

## 0.1.9 - 2026-04-15

### Added
- Paged search with infinite scroll across global, per-catalogue, and per-category views (`:limit`/`:offset` on all three search functions; `count_search_items*` companions for "X of Y" totals)
- Per-item markup override — nullable `markup_percentage` on items (`nil` inherits the catalogue's markup, any value including `0` overrides it); requires phoenix_kit 1.7.96+ for the V97 migration
- `Item.effective_markup/2` and `Catalogue.item_pricing/1` expose which markup applies (catalogue vs item) for pricing UI
- Import wizard: markup override column with multilingual synonym detection (markup/margin/naceenka/juurdehindlus/aufschlag/...)
- Import wizard: manufacturer and supplier pickers (four-mode vocabulary `:none`/`:column`/`:create`/`:existing`), shared `<.party_picker>` and `<.new_party_form>` components
- Import wizard: language-aware category get-or-create with "match across all languages" toggle; inline category creation in `:create` mode
- Import wizard: empty-pool warning when a picker column is exhausted by a sibling picker's mapping

### Changed
- Search uses `start_async` with a query-equality guard in `handle_async`, so out-of-order or superseded responses are dropped; scroll paging also runs off the LV process via `start_async(:search_page, …)` guarded on `{query, offset}`
- Import executor phase 1 (get-or-create categories / manufacturers / suppliers) wrapped in a single `Repo.transaction` so a mid-phase crash rolls back any entities earlier loops persisted
- Three `:create`-mode resolutions in the wizard wrap in `Repo.transaction` at the LV layer so a failure on the second/third doesn't leave the first as an orphan
- `Catalogue.item_pricing/1` now returns `catalogue_markup`, `item_markup`, and effective `markup_percentage` so callers stay internally consistent
- `IntersectionObserver` hook re-fires on `updated()` — fixes the "loads forever" bug on tall viewports / Page Down

### Fixed
- Upload button stays disabled while the upload XHR is in flight (server-side guard in `parse_file`) — fixes the "click during upload erases the file" race
- Parser strips fully-empty columns (blank header AND every data cell blank) — fixes phantom mapping cards on FENIX-style spreadsheets with leading/trailing empty columns
- Catalogue picker loads on first HTTP mount (no empty-dropdown flash); options show counts (`Kitchen · 5 categories · 47 items`)
- Sample data table: `#` row-number column, truncation tooltips, stable collapse `id` so morphdom preserves open state

## 0.1.8 - 2026-04-12

### Fixed
- Add routing anti-pattern warning to AGENTS.md

## 0.1.7 - 2026-04-11

### Added
- Items belong directly to catalogues via catalogue_uuid FK (requires phoenix_kit 1.7.95+)
- Infinite scroll on catalogue detail page with cursor-based pagination
- Activity logging with Events tab (actor tracking on all mutations)
- Item counts on catalogue list view
- Clickable entity names (manufacturers, suppliers)
- Comprehensive test suite: LiveCase, LiveView tests, schema tests

### Changed
- Removed safe_nested_assoc/2 in favour of direct catalogue association on items
- Category and item mutations now accept actor_uuid for activity logging

## 0.1.6 - 2026-04-09

### Added
- Dynamic file import system (CSV/Excel with multi-sheet support)
- Auto-detect column→field mappings
- Unit normalization and duplicate detection
- Full import LiveView (upload → parse → map → confirm → execute)

### Changed
- Updated phoenix_kit dependency to 1.7.93

## 0.1.5 - 2026-04-08

### Added
- **Dynamic file import** — upload XLSX or CSV files, auto-detect column mappings, map columns to item fields via drag-down UI
- **Import language support** — select which language the file data is in, stored in multilang JSONB
- **Import category support** — import into existing category, create categories from column values, or import without category
- **Unit mapping** — auto-detect and map file unit values (TK, KMPL, LEHT, PAAR) to system units (piece, set, pair, sheet, m2, running_meter)
- **Duplicate detection** — detect identical rows within file and items already in catalogue, with skip/import choice
- **New unit types** — added `set`, `pair`, `sheet` to allowed item units
- **Multilang search** — search now matches translated content in JSONB `data` field across all languages

### Changed
- Removed unique constraint on item SKU field to allow duplicate article codes
- Item edit form now detects imported items with non-primary language and shows rekey warning

### Fixed
- Search across translated content in `data` JSONB field

## 0.1.4 - 2026-04-06

### Changed
- Wrap all user-visible strings in Gettext for i18n

## 0.1.3 - 2026-03-31

### Added
- **Pricing system** — rename `price` to `base_price` on items, add `markup_percentage` to catalogues (default 0%), computed sale price via `Item.sale_price/2` and `Catalogue.item_pricing/1`
- **Search** — `search_items/2` for global cross-catalogue search, `search_items_in_catalogue/3` for catalogue-scoped search, `search_items_in_category/3` for category-scoped search; matches name, description, SKU via case-insensitive ILIKE with special character sanitization
- **Reusable components** (`PhoenixKitCatalogue.Web.Components`):
  - `item_table/1` — configurable data-driven table with selectable columns, opt-in actions, card view toggle
  - `search_input/1` — search bar with debounce and clear button
  - `search_results_summary/1` — result count display
  - `empty_state/1` — centered empty state card
  - `view_mode_toggle/1` — global table/card toggle syncing multiple tables via shared storage key
- **Card view** — all tables (catalogues, manufacturers, suppliers, items) support table/card view toggle with localStorage persistence; card titles are clickable links
- **Inline actions** — table row actions render as inline buttons on desktop, collapse to dropdown menu on mobile (via `table_row_menu` `mode="auto"`)
- `Catalogue.swap_category_positions/2` — atomic position swap in a transaction
- `Catalogue.list_items/1` — global item listing with status filter and limit
- `Catalogue.item_count_for_catalogue/1` and `category_count_for_catalogue/1` — active counts
- **Gettext localization** — all component text (column headers, actions, tooltips, result counts) localizable via PhoenixKit's Gettext backend
- **Graceful error handling** — components never crash; unknown columns, unloaded associations, nil values, and bad path functions produce "—" placeholders and Logger warnings
- All item list/search functions now consistently preload `category: :catalogue` and `:manufacturer`

### Fixed
- Category reorder now atomic (wrapped in transaction instead of two separate updates)
- `sync_manufacturer_suppliers/2` and `sync_supplier_manufacturers/2` now return `{:ok, :synced}` or `{:error, reason}` instead of silently swallowing errors
- `restore_item/1` now cascades upward to both parent category AND parent catalogue (was only restoring category)
- `deleted_item_count_for_catalogue/1` uses single JOIN query instead of two separate queries
- Removed misleading `list_uncategorized_items_for_catalogue/2` (ignored catalogue param), replaced with `list_uncategorized_items/1`
- Confirm-delete flows use modal dialogs instead of broken inline two-step pattern
- Forms use `action="#"` to prevent HTTP POST fallback before LiveView connects
- Added `:phoenix_kit` to `extra_applications` for module discovery

### Changed
- All LiveViews migrated to use PhoenixKit core components (`table_default`, `table_row_menu`, `status_badge`, `admin_page_header`, `confirm_modal`, `icon`)
- Removed all inline HTML tables, SVG icons, and local badge/format helpers in favour of shared components
- Manufacturer/supplier form save flows now handle sync errors with warning flash messages

## 0.1.2 - 2026-03-27

### Changed
- Bump Elixir requirement from ~> 1.15 to ~> 1.18 (align with sibling modules)
- Bump ex_doc from ~> 0.34 to ~> 0.39
- Update AGENTS.md: reorganize commands, add critical conventions, commit message rules, external dependencies section, and PR docs templates

## 0.1.1 - 2026-03-25

### Changed
- Remove all migration references — database and migrations are managed by the parent `phoenix_kit` project
- Add "Database & Migrations" section to README and AGENTS.md explaining where DB lives
- Remove `test.setup` and `test.reset` mix aliases (no longer needed)
- Remove test-only migration file and migration runner from test helper

## 0.1.0 - 2026-03-25

### Added
- Extract Catalogue module from PhoenixKit into standalone `phoenix_kit_catalogue` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add `Catalogue`, `Category`, `Item`, `Manufacturer`, `Supplier`, and `ManufacturerSupplier` schemas with UUIDv7 primary keys
- Add `PhoenixKitCatalogue.Catalogue` context with full CRUD for all schemas
- Add soft-delete system with cascading trash/restore for catalogues, categories, and items
- Add move operations for categories (between catalogues) and items (between categories)
- Add multilingual support for translatable fields via PhoenixKit's multilang system
- Add admin LiveViews: catalogues, categories, items, manufacturers, suppliers with forms
- Add centralized `Paths` module for route generation
- Add `css_sources/0` for Tailwind CSS scanning support
- Add behaviour compliance and catalogue context test suites
