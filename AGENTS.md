# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

PhoenixKit Catalogue — an Elixir module for product catalogue management, built as a pluggable module for the PhoenixKit framework. Manages manufacturers, suppliers, catalogues, categories, and items with soft-delete cascading, multilingual support, and move operations. Designed for manufacturing companies (e.g. kitchen/furniture producers) that need to organize materials and components.

## Common Commands

### Setup & Dependencies

```bash
mix deps.get                # Install dependencies
```

### Testing

```bash
mix test                        # Run all tests (integration excluded if no DB)
mix test test/file_test.exs     # Run single test file
mix test test/file_test.exs:42  # Run specific test by line
```

### Code Quality

```bash
mix format                  # Format code
mix credo --strict          # Lint / code quality (strict mode)
mix dialyzer                # Static type checking
mix precommit               # compile + format + credo --strict + dialyzer
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
```

## Dependencies

This is a **library**, not a standalone app. It requires a sibling `../phoenix_kit` directory (path dependency). The full dependency chain:

- `phoenix_kit` (path: `"../phoenix_kit"`) — provides Module behaviour, Settings, RepoHelper, Dashboard tabs, Multilang
- `phoenix_live_view` — web framework (LiveView UI)

## Architecture

This is a **PhoenixKit module** that implements the `PhoenixKit.Module` behaviour. It depends on the host PhoenixKit app for Repo, Endpoint, and Settings.

### Core Schemas (all use UUIDv7 primary keys)

- **Catalogue** (`phoenix_kit_cat_catalogues`) — top-level groupings with name, description, markup_percentage (default 0%), status (active/archived/deleted)
- **Category** (`phoenix_kit_cat_categories`) — subdivisions within a catalogue with position ordering, status (active/deleted)
- **Item** (`phoenix_kit_cat_items`) — individual products with SKU, base_price, unit of measure, manufacturer link, status (active/deleted). **Belongs directly to a catalogue via `catalogue_uuid`** (required), with an optional `category_uuid` for grouping. Items without a category are "uncategorized within a catalogue" — still scoped to that catalogue. Sale price computed via catalogue's `markup_percentage` unless the item has its own `markup_percentage` override (nullable column, V97): `NULL` inherits from the catalogue, any Decimal (including `0`) overrides it. `Item.sale_price(item, catalogue_markup)` and `Item.effective_markup(item, catalogue_markup)` both honor the override transparently
- **Manufacturer** (`phoenix_kit_cat_manufacturers`) — company directory with name, website, logo, status (active/inactive)
- **Supplier** (`phoenix_kit_cat_suppliers`) — delivery companies with name, website, status (active/inactive)
- **ManufacturerSupplier** (`phoenix_kit_cat_manufacturer_suppliers`) — many-to-many join table

### Items and catalogue scoping

- Every item has `catalogue_uuid` (required). The category is the single source of truth for an item's catalogue: whenever `create_item/2` or `update_item/3` receives a `category_uuid`, the private `derive_catalogue_uuid/2` helper sets `catalogue_uuid` from that category's `catalogue_uuid`, **overriding any stale value the caller passed**. This guarantees an item's category and catalogue can never drift out of sync via the context API
- For `update_item/3`, derivation is evaluated against the *resulting* state: if attrs don't mention `category_uuid`, the item's existing category is used. An update that only changes the item's price/name/etc. leaves `catalogue_uuid` alone
- An empty-string `category_uuid` from form params is normalized to `nil` (treated as "clear the category")
- `move_item_to_category/3` updates `catalogue_uuid` when the target category is in a different catalogue. Passing `nil` detaches the item from its category but keeps it in the current catalogue (making it uncategorized *within* that catalogue). Returns `{:error, :category_not_found}` if the target category UUID doesn't exist
- `move_category_to_catalogue/3` cascades the new `catalogue_uuid` to all items in the moved category (wrapped in a transaction) and logs the cascade count in the `category.moved` activity metadata (`items_cascaded`)
- `list_uncategorized_items/2` takes a `catalogue_uuid` (no more global pool) and returns items where `category_uuid IS NULL AND catalogue_uuid = ?`
- All per-catalogue queries (`list_items_for_catalogue`, `item_count_for_catalogue`, `item_counts_by_catalogue`, `deleted_item_count_for_catalogue`, `search_items_in_catalogue`) filter on `items.catalogue_uuid` and include both categorized and uncategorized items
- Import executor passes `skip_derive: true` to `create_item/2` because it guarantees attrs consistency by construction (it owns the target catalogue and creates or constrains categories within it) — this avoids a per-item category lookup during bulk imports

### Soft-Delete Cascade System

- **Downward on trash:** catalogue → categories + all items (categorized and uncategorized) in that catalogue
- **Upward on restore:** item → category → catalogue; category → catalogue + items
- **Permanent delete** follows same downward cascade but removes from DB; uncategorized items of the catalogue are removed too
- All cascading operations wrapped in `Repo.transaction/1`

### Activity Logging

Every mutating operation in `Catalogue` context is logged via `PhoenixKit.Activity.log/1`:

- **Pattern**: Private `log_activity/1` helper guarded by `Code.ensure_loaded?(PhoenixKit.Activity)` with rescue to `Logger.warning`. Activity logging failures never crash the primary operation.
- **Actor tracking**: All mutating functions accept `opts \\ []` keyword list. Pass `actor_uuid: user.uuid` to attribute the action.
- **Actions logged**: `manufacturer.created/updated/deleted`, `supplier.created/updated/deleted`, `catalogue.created/updated/deleted/trashed/restored/permanently_deleted`, `category.created/updated/deleted/trashed/restored/permanently_deleted/moved/positions_swapped`, `item.created/updated/deleted/trashed/restored/permanently_deleted/moved/bulk_trashed`, `manufacturer.suppliers_synced`, `supplier.manufacturers_synced`, `import.started`, `import.completed`
- **Mode**: `"manual"` for user actions, `"auto"` for import-created items/categories
- **LiveViews**: Extract actor UUID via `actor_opts(socket)` private helper reading `socket.assigns[:phoenix_kit_current_user]`

### Import System

Multi-step file import wizard for bulk item creation from XLSX/CSV files.

- **Parser** (`import/parser.ex`): Format detection, XLSX via `XlsxReader`, CSV with auto-separator detection, BOM stripping
- **Mapper** (`import/mapper.ex`): Auto-detect column mappings, unit normalization, import plan builder with validation
- **Executor** (`import/executor.ex`): Three-phase execution (1: get-or-create categories + manufacturers + suppliers in column mode; 2: insert items resolving category/manufacturer per row; 3: create manufacturer↔supplier M:N links from per-row pairs and/or fixed supplier→all-touched-manufacturers), progress reporting, language support, actor_uuid threading for activity logs. Items get `manufacturer_uuid` directly; suppliers attach via the M:N join because items don't have a supplier FK
- **ImportLive** (`web/import_live.ex`): Upload → sheet select → column mapping → confirm → importing → results. ETS buffering for large files, duplicate detection, multilang support. Three pickers (category / manufacturer / supplier) share a four-mode vocabulary — `:none` / `:column` (per-row from a CSV column) / `:create` (inline form, persisted at execute time so cancelling the confirm step doesn't leave orphans) / `:existing` (pick from active records). The `available_picker_columns/2` filter prevents a picker from silently clobbering a sibling's column mapping; switching sheets / replacing the file calls `reset_picker_state/1` so picker assigns can never reference stale column indices

### Search API

Three search functions, each paired with an unbounded count function. Results page through the same `InfiniteScroll` sentinel that drives the category walk in `CatalogueDetailLive`.

| List function | Count function | Scope |
|---------------|---------------|-------|
| `search_items/2` | `count_search_items/1` | All non-deleted catalogues |
| `search_items_in_catalogue/3` | `count_search_items_in_catalogue/2` | One catalogue |
| `search_items_in_category/3` | `count_search_items_in_category/2` | One category |

All list functions take `:limit` (default 50) and `:offset` (default 0) in `opts`. Sort order is deterministic for paging — each query appends `asc: i.uuid` as the final tie-breaker. Count functions run the same `where` clauses but with `select: count(i.uuid)` and no `:limit`/`:offset`/`:order_by`/`:preload`, so they return the full matching total regardless of the current page.

**LiveView usage pattern** (see `CatalogueDetailLive.run_search/2` and `load_next_search_batch/1`): fetch first page + total on search, render a sentinel while `search_has_more = loaded < total`, append pages via the shared `InfiniteScroll` hook. `search_results_summary` accepts an optional `loaded` attr to render "Showing X of Y" while paging.

**Async + loading state** (same LiveView): searches run inside `start_async(:search, …)` so a newer query cancels a pending one and stale responses are dropped by a query-equality guard in `handle_async(:search, {:ok, …})`. While a search is in flight, the template shows a "Searching for …" status line (first search) or dims the prior results with `opacity-50` and shows a small spinner next to the summary (subsequent searches). Unexpected task exits log a warning and surface a user-visible flash; expected cancellation reasons (`:shutdown` / `:killed`) are no-ops.

### Web Layer

- **Admin** (9 LiveViews): CataloguesLive (index for catalogues/manufacturers/suppliers), CatalogueDetailLive, CatalogueFormLive, CategoryFormLive, ItemFormLive, ManufacturerFormLive, SupplierFormLive, ImportLive (multi-step import wizard), EventsLive (activity log with infinite scroll)
- **Components** (`PhoenixKitCatalogue.Web.Components`): Reusable components — `item_table`, `search_input`, `search_results_summary`, `empty_state`, `view_mode_toggle`. All features opt-in via attrs. All text localized via `Gettext.gettext(PhoenixKitWeb.Gettext, ...)`. Components never crash — unknown columns, unloaded associations, nil values, and bad function arguments produce "—" placeholders and Logger warnings.
- **Routes**: Admin routes auto-generated from `admin_tabs/0`
- **Paths**: Centralized path helpers in `Paths` module — always use these instead of hardcoding URLs

### Settings Keys

`catalogue_enabled`

### File Layout

```
lib/phoenix_kit_catalogue.ex                    # Main module (PhoenixKit.Module behaviour)
lib/phoenix_kit_catalogue/
├── catalogue.ex                               # Context module (all CRUD, soft-delete, move ops, activity logging)
├── paths.ex                                   # Centralized URL path helpers
├── schemas/
│   ├── cat_catalogue.ex                       # Catalogue schema + changeset
│   ├── category.ex                            # Category schema + changeset
│   ├── item.ex                                # Item schema + changeset
│   ├── manufacturer.ex                        # Manufacturer schema + changeset
│   ├── manufacturer_supplier.ex               # Join table schema
│   └── supplier.ex                            # Supplier schema + changeset
├── import/
│   ├── parser.ex                              # XLSX/CSV file parsing
│   ├── mapper.ex                              # Column mapping + auto-detection
│   └── executor.ex                            # Import execution with progress reporting
└── web/
    ├── components.ex                          # Reusable components (item_table, search_input, etc.)
    ├── catalogues_live.ex                     # Index page (catalogues/manufacturers/suppliers)
    ├── catalogue_detail_live.ex               # Catalogue detail with categories + items
    ├── catalogue_form_live.ex                 # Create/edit catalogue
    ├── category_form_live.ex                  # Create/edit/move category
    ├── item_form_live.ex                      # Create/edit/move item
    ├── manufacturer_form_live.ex              # Create/edit manufacturer + supplier links
    ├── supplier_form_live.ex                  # Create/edit supplier + manufacturer links
    ├── import_live.ex                         # Multi-step import wizard
    └── events_live.ex                         # Activity events feed (infinite scroll)
```

## Critical Conventions

- **Module key**: `"catalogue"` — MUST be consistent across all callbacks (`module_key/0`, `admin_tabs/0`, settings keys, tab IDs)
- **Tab ID prefix**: all admin tabs MUST use `:admin_catalogue_` prefix (e.g., `:admin_catalogue_catalogues`)
- **UUIDv7 primary keys** — all schemas MUST use `@primary_key {:uuid, UUIDv7, autogenerate: true}`
- **Centralized paths via `Paths` module** — NEVER hardcode URLs or route paths in LiveViews; always use `Paths` helpers
- **URL paths use hyphens** — route segments use hyphens (e.g., `/catalogue-items`), never underscores
- **Admin routes from `admin_tabs/0`** — all admin navigation is auto-generated by PhoenixKit Dashboard from the tabs returned by `admin_tabs/0`; do not manually add admin routes elsewhere. See `phoenix_kit/guides/custom-admin-pages.md` for the authoritative reference (including why parent apps must never hand-register plugin LiveView routes)
- **Navigation paths** — always use `PhoenixKit.Utils.Routes.path/1` for navigation within the PhoenixKit ecosystem
- **LiveViews use `Phoenix.LiveView` directly** — do not use `PhoenixKitWeb` macros (`use PhoenixKitWeb, :live_view`) in this standalone package; import helpers explicitly
- **`enabled?/0` MUST rescue** — the function must rescue all errors and return `false` as fallback (DB may not be available at boot)
- **Single context module** — all business logic lives in `PhoenixKitCatalogue.Catalogue`; schemas are data-only with changesets
- **Multilang fields** — name and description fields use PhoenixKit's `Multilang` module for i18n support
- **Soft-delete via status field** — catalogues, categories, and items use `status: "deleted"` for soft-delete; manufacturers and suppliers use hard-delete only

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

## Database & Migrations

This repo contains **no database migrations**. All database tables and migrations live in the parent [phoenix_kit](https://github.com/BeamLabEU/phoenix_kit) project. This module only defines Ecto schemas that map to tables created by PhoenixKit core.

## Testing

### Setup

The test database is created and migrated by the parent `phoenix_kit` project. This repo assumes the DB already exists with the correct schema.

The critical config wiring is in `config/test.exs`:

```elixir
config :phoenix_kit, repo: PhoenixKitCatalogue.Test.Repo
```

Without this, all DB calls through `PhoenixKit.RepoHelper` crash with "No repository configured".

### Structure

```
test/
├── test_helper.exs                  # DB detection, sandbox setup
├── support/
│   ├── test_repo.ex                 # PhoenixKitCatalogue.Test.Repo
│   └── data_case.ex                 # DataCase (sandbox + :integration tag)
├── phoenix_kit_catalogue_test.exs   # Module behaviour compliance tests
├── catalogue_test.exs               # Context integration tests (CRUD, cascade, move)
└── import/
    ├── parser_test.exs              # File format detection and parsing
    ├── mapper_test.exs              # Column mapping and normalization
    └── executor_test.exs            # Import execution and progress
```

Integration tests are automatically excluded when the database is unavailable.

### Running tests

```bash
mix test                             # All tests (excludes integration if no DB)
mix test test/catalogue_test.exs     # Context tests only
mix test test/catalogue_test.exs:42  # Specific test by line
```

## Versioning & Releases

This project follows [Semantic Versioning](https://semver.org/).

### Version locations

The version must be updated in **three places** when bumping:

1. `mix.exs` — `@version` module attribute (used by Hex, `mix.exs` metadata, and docs)
2. `lib/phoenix_kit_catalogue.ex` — `def version, do: "x.y.z"` (PhoenixKit.Module callback, runtime-accessible)
3. `test/phoenix_kit_catalogue_test.exs` — `assert PhoenixKitCatalogue.version() == "x.y.z"` (version compliance test)

### Changelog

Update `CHANGELOG.md` before releasing. Each version gets a section:

```markdown
## x.y.z - YYYY-MM-DD

### Added / Changed / Fixed / Removed
- Description of change
```

Use [Keep a Changelog](https://keepachangelog.com/) categories: `Added`, `Changed`, `Fixed`, `Removed`.

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.1
git push origin 0.1.1
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.1 \
  --title "0.1.1 - 2026-03-25" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs`, `lib/phoenix_kit_catalogue.ex`, and the version test
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`). See `dev_docs/pull_requests/README.md` for the detailed template and conventions.

## Pre-commit Commands

Always run before git commit:

```bash
mix precommit               # compile + format + credo --strict + dialyzer
```

## External Dependencies

- **PhoenixKit** (`~> 1.7`) — Module behaviour, Settings API, RepoHelper, Dashboard tabs, Multilang, Activity
- **Phoenix LiveView** (`~> 1.1`) — Admin LiveViews
- **xlsx_reader** (`~> 0.8`) — Excel file parsing for import system
- **ex_doc** (`~> 0.39`, dev only) — Documentation generation
- **credo** (`~> 1.7`, dev/test) — Static analysis / code quality
- **dialyxir** (`~> 1.4`, dev/test) — Static type checking
