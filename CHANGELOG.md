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
