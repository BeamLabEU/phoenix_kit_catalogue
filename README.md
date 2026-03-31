# PhoenixKitCatalogue

Catalogue module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) — product catalogue management with manufacturers, suppliers, categories, and items.

Designed for manufacturing companies (e.g. kitchen/furniture producers) that need to organize materials and components from multiple manufacturers and suppliers.

## Features

- **Catalogues** — top-level groupings with configurable markup percentage for pricing
- **Categories** — subdivisions within a catalogue with manual position ordering
- **Items** — individual products with SKU, base price, computed sale price, unit of measure
- **Manufacturers** — company directory with many-to-many supplier linking
- **Suppliers** — delivery companies linked to manufacturers
- **Pricing** — base price per item + markup percentage per catalogue = computed sale price
- **Search** — case-insensitive search by name, description, or SKU (per-category, per-catalogue, and global)
- **Soft-delete** — catalogues, categories, and items support trash/restore with cascading
- **Multilingual** — all translatable fields use PhoenixKit's multilang system
- **Move operations** — move categories between catalogues, items between categories
- **Card/table views** — all tables support card view toggle, persisted per user in localStorage
- **Reusable components** — `item_table`, `search_input`, `view_mode_toggle`, `empty_state` with gettext localization and graceful error handling
- **Zero-config discovery** — auto-discovered by PhoenixKit via beam scanning

## Installation

Add to your parent app's `mix.exs`:

```elixir
{:phoenix_kit_catalogue, "~> 0.2.0"}
```

Then:

```bash
mix deps.get
```

> **Development:** During local development, you can use a path dependency instead:
> `{:phoenix_kit_catalogue, path: "../phoenix_kit_catalogue"}`

The module auto-discovers via beam scanning. Enable it in **Admin > Modules**.

## Data Model

```
Manufacturer (1) ──< ManufacturerSupplier >── (1) Supplier
     │                    (many-to-many)
     │
     └──────────────────────────────┐
                                    │
Catalogue (1) ──> Category (many) ──> Item (many)
                   │                   ├── belongs_to Category (optional)
                   │                   └── belongs_to Manufacturer (optional)
                   └── position-ordered, soft-deletable
```

All tables use UUIDv7 primary keys and are prefixed with `phoenix_kit_cat_*`.

### Status Values

| Entity       | Statuses                                  |
|-------------|-------------------------------------------|
| Catalogue   | `active`, `archived`, `deleted`           |
| Category    | `active`, `deleted`                       |
| Item        | `active`, `inactive`, `discontinued`, `deleted` |
| Manufacturer| `active`, `inactive`                      |
| Supplier    | `active`, `inactive`                      |

## Soft-Delete System

First delete sets status to `"deleted"` (recoverable). Permanent delete removes from DB.

### Cascade Behaviour

**Downward on trash/permanent-delete:**
- Trash catalogue -> trashes all categories + all items
- Trash category -> trashes all items
- Permanently delete follows the same cascade

**Upward on restore:**
- Restore item -> restores its deleted parent category + parent catalogue
- Restore category -> restores its deleted parent catalogue + all items

All cascading operations run in database transactions.

## API

The public API lives in `PhoenixKitCatalogue.Catalogue`. Every function has `@doc` documentation — use `h/1` in IEx to explore.

### Quick Reference

```elixir
alias PhoenixKitCatalogue.Catalogue

# ── Catalogues ────────────────────────────────────────
Catalogue.list_catalogues()                        # excludes deleted
Catalogue.list_catalogues(status: "deleted")       # only deleted
Catalogue.create_catalogue(%{name: "Kitchen"})
Catalogue.update_catalogue(cat, %{name: "New Name"})
Catalogue.trash_catalogue(cat)                     # soft-delete (cascades down)
Catalogue.restore_catalogue(cat)                   # restore (cascades down)
Catalogue.permanently_delete_catalogue(cat)        # hard-delete (cascades down)

# ── Categories ────────────────────────────────────────
Catalogue.list_categories_for_catalogue(cat_uuid)  # excludes deleted
Catalogue.list_all_categories()                    # "Catalogue / Category" format
Catalogue.create_category(%{name: "Frames", catalogue_uuid: cat.uuid})
Catalogue.trash_category(category)                 # cascades to items
Catalogue.restore_category(category)               # cascades up + down
Catalogue.permanently_delete_category(category)    # cascades to items
Catalogue.move_category_to_catalogue(category, target_uuid)
Catalogue.next_category_position(cat_uuid)

# ── Items ─────────────────────────────────────────────
Catalogue.list_items()                             # all non-deleted, preloads all
Catalogue.list_items(status: "active", limit: 100) # with filters
Catalogue.list_items_for_category(cat_uuid)        # excludes deleted
Catalogue.list_items_for_catalogue(cat_uuid)       # excludes deleted
Catalogue.create_item(%{name: "Oak Panel", base_price: 25.50, sku: "OAK-18"})
Catalogue.trash_item(item)                         # soft-delete
Catalogue.restore_item(item)                       # cascades up to category + catalogue
Catalogue.permanently_delete_item(item)            # hard-delete
Catalogue.trash_items_in_category(cat_uuid)        # bulk soft-delete
Catalogue.move_item_to_category(item, new_cat_uuid)
Catalogue.item_pricing(item)                       # %{base_price, markup_percentage, price}
Catalogue.swap_category_positions(cat_a, cat_b)    # atomic position swap

# ── Manufacturers ─────────────────────────────────────
Catalogue.list_manufacturers(status: "active")
Catalogue.create_manufacturer(%{name: "Blum", website: "https://blum.com"})
Catalogue.delete_manufacturer(m)                   # hard-delete

# ── Suppliers ─────────────────────────────────────────
Catalogue.list_suppliers(status: "active")
Catalogue.create_supplier(%{name: "Regional Distributors"})
Catalogue.delete_supplier(s)                       # hard-delete

# ── Manufacturer ↔ Supplier Links ─────────────────────
Catalogue.link_manufacturer_supplier(m_uuid, s_uuid)
Catalogue.unlink_manufacturer_supplier(m_uuid, s_uuid)
Catalogue.sync_manufacturer_suppliers(m_uuid, [s1_uuid, s2_uuid])
Catalogue.list_suppliers_for_manufacturer(m_uuid)
Catalogue.list_manufacturers_for_supplier(s_uuid)

# ── Search ────────────────────────────────────────────
Catalogue.search_items("oak")                      # global across all catalogues
Catalogue.search_items("oak", limit: 10)
Catalogue.search_items_in_catalogue(cat_uuid, "panel")
Catalogue.search_items_in_category(cat_uuid, "oak") # within one category

# ── Counts ────────────────────────────────────────────
Catalogue.item_count_for_catalogue(cat_uuid)       # active items
Catalogue.category_count_for_catalogue(cat_uuid)   # active categories
Catalogue.deleted_count_for_catalogue(cat_uuid)    # deleted items + categories
Catalogue.deleted_catalogue_count()

# ── Multilang ─────────────────────────────────────────
Catalogue.get_translation(record, "ja")
Catalogue.set_translation(record, "ja", field_data, &Catalogue.update_catalogue/2)
```

## Reusable Components

Import into any LiveView:

```elixir
import PhoenixKitCatalogue.Web.Components
```

### `item_table/1`

Data-driven item table with opt-in columns, actions, and card view:

```heex
<%!-- Minimal --%>
<.item_table items={@items} columns={[:name, :sku]} />

<%!-- Full featured with card view --%>
<.item_table
  items={@items}
  columns={[:name, :sku, :base_price, :price, :unit, :status]}
  markup_percentage={@catalogue.markup_percentage}
  edit_path={&Paths.item_edit/1}
  on_delete="delete_item"
  cards={true}
  id="my-items"
/>
```

Available columns: `:name`, `:sku`, `:base_price`, `:price`, `:unit`, `:status`, `:category`, `:catalogue`, `:manufacturer`

Unknown columns render as "—" with a logger warning. Unloaded associations, nil values, and invalid markup types are handled gracefully — the component never crashes the page.

### `search_input/1`

Search bar with debounce and clear button:

```heex
<.search_input query={@search_query} placeholder="Search..." />
```

### `view_mode_toggle/1`

Global table/card toggle that syncs all tables sharing the same `storage_key`:

```heex
<.view_mode_toggle storage_key="my-items" />
<.item_table cards={true} show_toggle={false} storage_key="my-items" id="table-1" ... />
<.item_table cards={true} show_toggle={false} storage_key="my-items" id="table-2" ... />
```

### `search_results_summary/1` and `empty_state/1`

```heex
<.search_results_summary count={length(@results)} query={@query} />
<.empty_state message="No items yet." />
```

All component text (column headers, action labels, toggle tooltips, result counts) is localizable via PhoenixKit's Gettext backend.

## Admin UI

The module registers admin tabs via `PhoenixKit.Module`:

| Path | View |
|------|------|
| `/admin/catalogue` | Catalogue list with Active/Deleted tabs |
| `/admin/catalogue/new` | New catalogue form |
| `/admin/catalogue/:uuid` | Catalogue detail with categories, items, status tabs |
| `/admin/catalogue/:uuid/edit` | Edit catalogue + permanent delete |
| `/admin/catalogue/manufacturers` | Manufacturer list |
| `/admin/catalogue/suppliers` | Supplier list |
| `/admin/catalogue/categories/:uuid/edit` | Edit category + move + permanent delete |
| `/admin/catalogue/items/:uuid/edit` | Edit item + move |

All forms support multilingual content when the Languages module is enabled.

## Database & Migrations

This package contains **no database migrations**. All tables (`phoenix_kit_cat_*`) and migrations are managed by the parent [phoenix_kit](https://github.com/BeamLabEU/phoenix_kit) project. This module only defines Ecto schemas that map to those tables.

## Tests

```bash
mix test
```

The test database must be created and migrated by the parent `phoenix_kit` project first.

120+ tests covering:
- Full CRUD for all entities
- Cascading soft-delete (downward) and restore (upward to category + catalogue)
- Permanent delete cascading
- Move operations (category between catalogues, item between categories)
- Deleted counts
- Schema validations (status, unit, base_price, SKU uniqueness, name length)
- Manufacturer-supplier link sync (with error handling)
- Atomic category position swapping
- Sale price calculation (markup, nil handling, rounding)
- Item pricing API (base_price, markup_percentage, computed price)
- Search (by name, SKU, description; case-insensitive; scoped and global)
- Catalogue markup_percentage defaults and validation

## License

MIT
