## 0.1.12 - 2026-04-24

### Added
- **Catalogue form tabs** — `CatalogueFormLive` gains Details / Metadata / Files tabs (mirrors `ItemFormLive`). Featured image + attached files live under the Files tab; metadata under Metadata. Panels stay in the DOM (toggled via `hidden`) so multilang state and in-progress input survive tab switches. Save sits outside the tab panels and works from any tab.
- **Catalogue metadata** — `Metadata.definitions(:catalogue)` ships five opt-in fields (`brand`, `collection`, `season`, `region`, `vendor_ref`) stored under `catalogue.data["meta"]`.
- **Category featured image** — `CategoryFormLive` gains a featured-image card (no tabs, no file grid; a category is a taxonomy node). `Attachments.folder_name_for/1` picks up a `%Category{}` clause (`catalogue-category-<uuid>`). Folders are created lazily on first picker open, so categories without a featured image never materialize one.
- `Components.featured_image_card/1` — shared featured-image card (thumbnail + name + size, or dashed empty state with primary button) used by catalogue / category / item forms.
- `Components.metadata_editor/1` — shared metadata tab body (per-key text input + remove button + add-picker dropdown; legacy keys render disabled with a "Legacy" pill).

### Changed
- **`PhoenixKitCatalogue.ItemMetadata` → `PhoenixKitCatalogue.Metadata`** with resource-type-scoped `definitions/1`. Items keep `color / weight / width / height / depth / material / finish`; catalogues get the five new keys above. Upstream consumers of the `ItemMetadata` module (introduced in 0.1.11) need to update the alias and pass `:item` to `definitions/1`.
- Extracted the three-phase form helpers — `Metadata.build_state/2`, `absorb_params/2`, `inject_into_data/3` — out of `ItemFormLive` and into the shared module so `CatalogueFormLive` uses the same plumbing (~150 lines of duplication removed across the three form LVs).

### Notes
- No migrations. All three schemas (`Item`, `Catalogue`, `Category`) already carry JSONB `data`; `featured_image_uuid`, `files_folder_uuid`, and `meta` all live under that column.
- 27 unit tests for the pure `Metadata` helpers + 7 component-render tests for `featured_image_card/1` and `metadata_editor/1`.

## 0.1.11 - 2026-04-22

### Added
- **Nested categories** (requires phoenix_kit 1.7.103+ for the V103 `parent_uuid` self-FK migration). New `PhoenixKitCatalogue.Catalogue.Tree` module with recursive-CTE helpers (`subtree_uuids/1`, `descendant_uuids/1`, `ancestor_uuids/1`, `ancestors_in_order/1`) plus pure in-memory walkers (`build_children_index/1`, `walk_subtree/3`) for preloaded trees. CTEs use `UNION` (not `UNION ALL`) for defense-in-depth cycle safety.
- `Catalogue.move_category_under/3` — same-catalogue reparent with `:would_create_cycle` / `:cross_catalogue` / `:parent_not_found` rejection; `nil` promotes to root.
- `Catalogue.list_category_tree/2` returns `[{category, depth}]` with orphan promotion (deleted-ancestor children surface as roots) and an `:exclude_subtree_of` option for parent pickers.
- `Catalogue.list_category_ancestors/1` (delegates to `Tree.ancestors_in_order/1`) for breadcrumbs.
- `search_items/2` gains `:include_descendants` (default `true`) so a category-scoped search also matches items in descendant categories. Pass `false` for the literal-set semantics.
- **Attachments** — new `PhoenixKitCatalogue.Attachments` module shared by item + catalogue forms. Folder-per-resource, featured-image pointer, inline files dropzone (20 files / 100 MB / `auto_upload: true`), pending-folder rename on first save. Smart detach splits home-folder vs `FolderLink` files; `list_files_in_folder/1` capped at 200 rows. Save button disabled while uploads are in flight.
- **Item metadata** — new `PhoenixKitCatalogue.ItemMetadata` module with a global opt-in list of fields stored on `item.data["meta"]`. Labels are gettext-wrapped; legacy keys (dropped from code but still held by an item) surface as "Legacy" rows with a remove-only action so deleting a definition never wipes stored data.
- **Item picker** — new `PhoenixKitCatalogue.Web.Components.ItemPicker` combobox LiveComponent with server-side search, `:category_uuids` / `:catalogue_uuids` scoping, `:include_descendants` toggle, `:excluded_uuids` dim-and-disable, colocated keyboard hook (ArrowUp/Down, Home/End, Enter, Escape), `has_more` "type to refine" sentinel, and render-shape tests.

### Changed
- Category position scoping moved from `catalogue_uuid` to `(catalogue_uuid, parent_uuid)` — `next_category_position/2` now takes a `parent_uuid` arg (default `nil` for root).
- `swap_category_positions/3` refuses `{:error, :not_siblings}` when the two categories live under different parents or in different catalogues.
- `trash_category` / `restore_category` / `permanently_delete_category` walk the whole subtree in one transaction. `restore_category` also restores deleted ancestors + the parent catalogue so the restored node is reachable. Activity metadata carries `subtree_size` + `items_cascaded`.
- `move_category_to_catalogue` carries the subtree along in a transaction; takes `SELECT … FOR UPDATE` on the moved row and computes the target position *after* the subtree has moved — closes the stale-position race flagged in prior reviews.
- `list_all_categories/0` renders full breadcrumbs (`"Catalogue / Parent / Child"`) and loads in two queries instead of N+1 per catalogue.
- `Category.changeset` rejects self-parent; `create_category/2` and `update_category/3` additionally guard against cross-catalogue and descendant-as-parent (cycle) cases at the context level, so raw API / form callers can't bypass `move_category_under/3`.

### Fixed
- Catch-all `handle_info/2` on `CatalogueFormLive` and `ItemFormLive` — stray monitor signals used to crash these forms.
- `phx-disable-with` on every Move button (category-under-parent, category-to-catalogue, item-to-category, item-to-smart-catalogue).
- `Attachments.soft_trash_file/1` is inlined to avoid depending on the unreleased `PhoenixKit.Modules.Storage.trash_file/1`.
- Credo / dialyzer clean after refactors: nested-too-deep in meta handlers, cyclomatic-10 `file_type_from_mime`, opaque MapSet in `list_category_tree`, unreachable `read_string/2` fallback.

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
