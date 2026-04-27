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

- **Catalogue** (`phoenix_kit_cat_catalogues`) — top-level groupings with name, description, `markup_percentage` (default 0, NOT NULL), `discount_percentage` (default 0, NOT NULL, V102), `kind` (`"standard"` | `"smart"`, default `"standard"`, NOT NULL, V102), status (active/archived/deleted). A **smart catalogue** holds items whose cost is a rule-driven function of other catalogues (see "Smart catalogues" section below). Optional `data["featured_image_uuid"]` + `data["files_folder_uuid"]` wire the `Attachments` module in (see "Attachments" section).
- **Category** (`phoenix_kit_cat_categories`) — subdivisions within a catalogue with position ordering, status (active/deleted), and a nullable self-FK `parent_uuid` (V103) that turns the flat taxonomy into an arbitrary-depth tree. `NULL` means root. Position is scoped to `(catalogue_uuid, parent_uuid)` — siblings only.
- **Item** (`phoenix_kit_cat_items`) — individual products with SKU, base_price, unit of measure, manufacturer link, status (active/deleted). **Belongs directly to a catalogue via `catalogue_uuid`** (required), with an optional `category_uuid` for grouping. Items without a category are "uncategorized within a catalogue" — still scoped to that catalogue. Has two nullable percentage overrides (`markup_percentage` added V97, `discount_percentage` added V102) with identical inherit-or-override semantics: `NULL` inherits from the catalogue, any Decimal (including `0`) overrides it. `Item.effective_markup/2` and `Item.effective_discount/2` resolve which value applies
- **Manufacturer** (`phoenix_kit_cat_manufacturers`) — company directory with name, website, logo, status (active/inactive)
- **Supplier** (`phoenix_kit_cat_suppliers`) — delivery companies with name, website, status (active/inactive)
- **ManufacturerSupplier** (`phoenix_kit_cat_manufacturer_suppliers`) — many-to-many join table
- **CatalogueRule** (`phoenix_kit_cat_item_catalogue_rules`, V102) — one row per `(item, referenced_catalogue)` for smart-catalogue items. Nullable `value` + `unit` plus `position` for UI ordering. At the **data layer**, `CatalogueRule.effective/2` still falls back to `item.default_value` / `item.default_unit` when a leg is NULL (kept for backward compat with pre-existing rows). At the **UI layer**, only `value` surfaces inheritance — the rules picker displays an `Inherit: N` placeholder for a blank value; `unit` is always explicit per row and does **not** read from `item.default_unit`. `UNIQUE(item_uuid, referenced_catalogue_uuid)` and `ON DELETE CASCADE` on both FKs — deleting a catalogue wipes every rule that references it, so warn the user first via `list_items_referencing_catalogue/1`.

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

- **Downward on trash:** catalogue → categories + all items (categorized and uncategorized) in that catalogue. Category → **entire subtree** (V103) including descendant categories + their items.
- **Upward on restore:** item → category → catalogue; category → **every deleted ancestor category** + catalogue + full deleted subtree + items. Restoring a deep child brings back ancestors so the restored node is reachable in the active tree.
- **Permanent delete** follows same downward cascade but removes from DB; uncategorized items of the catalogue are removed too. For categories: subtree is walked, items hard-deleted, `parent_uuid` NULL'd across the subtree (V103's FK has no `ON DELETE CASCADE`), then rows deleted.
- All cascading operations wrapped in `Repo.transaction/1`. Activity metadata on `category.trashed` / `category.restored` / `category.permanently_deleted` / `category.moved` carries `subtree_size` (categories touched, including root) and `items_cascaded` so the audit log tells the full story.

### Nested Categories (V103)

The V103 migration adds `parent_uuid` to `phoenix_kit_cat_categories`. All tree walks run through `PhoenixKitCatalogue.Catalogue.Tree` (internal module, `@moduledoc false`), which exposes `subtree_uuids/1`, `descendant_uuids/1`, `ancestor_uuids/1`, `ancestors_in_order/1`, `build_children_index/1`, `walk_subtree/3`. Recursive CTEs use `UNION` (not `UNION ALL`) so even if DB corruption produced a cycle, the working-set dedupe would break termination — no infinite-loop risk.

- **Public tree API on `Catalogue`:** `list_category_tree/2` returns `[{category, depth}]` in depth-first display order. Options: `:mode` (`:active` default, excludes deleted; `:deleted` includes everything), `:exclude_subtree_of` (pass the category being edited to keep it out of its own parent picker). Orphans (categories whose parent was filtered out) are promoted to roots so they don't vanish. `list_category_ancestors/1` returns the breadcrumb chain (root → direct parent).
- **Reparent within a catalogue:** `move_category_under(category, new_parent_uuid, opts)`. Returns `{:error, :would_create_cycle}` (self or descendant), `{:error, :cross_catalogue}` (target lives elsewhere — caller should `move_category_to_catalogue/3` first), `{:error, :parent_not_found}`. `nil` promotes to root. Same-parent is a no-op.
- **Cross-catalogue move:** `move_category_to_catalogue/3` still takes the whole subtree along — internal `parent_uuid` links inside the subtree stay valid because every row moves. The root's `parent_uuid` is cleared (detaches from the former parent, which stays in the source catalogue).
- **Position:** `next_category_position(catalogue_uuid, parent_uuid \\ nil)` is scoped to sibling groups. `swap_category_positions/3` refuses `:not_siblings` when the two categories don't share a parent or catalogue — the detail view's up/down arrows filter to siblings before calling swap.
- **Parent-uuid guards:** `create_category/2` and `update_category/3` both run `validate_parent_in_same_catalogue/1` after the changeset. It catches three cases: (a) parent doesn't exist (`{:error, cs}` with `"does not exist"`), (b) parent belongs to another catalogue (`"must belong to the same catalogue"`), (c) on update, the new parent is the category itself or one of its descendants (`"would create a cycle"`). The form LV's parent dropdown only lists same-catalogue, non-descendant candidates, but this context guard covers programmatic / API callers too. `Category.changeset` rejects the self-parent case; the cross-catalogue + cycle cases live in the context because they need DB lookups. `move_category_under/3` runs the same cycle/cross-catalogue checks with richer error atoms (`:would_create_cycle`, `:cross_catalogue`, `:parent_not_found`) for callers that want to react specifically.
- **Breadcrumbs in `list_all_categories/0`:** now returns `"Catalogue / Ancestor / Child"` format (not just `"Catalogue / Child"`) so move-dropdowns disambiguate same-named leaves under different parents. Runs one catalogues query + one categories query, builds the tree in memory — not N+1 per catalogue.
- **Search: `:include_descendants`** in `search_items/2` (default `true`): passes each entry in `:category_uuids` through `Tree.subtree_uuids_for/1`, so filtering by a parent category also matches items in descendants. Pass `false` for strict literal-set semantics.

### Pricing

Two independent percentage legs apply on top of `base_price`, each with a catalogue-wide default plus an optional per-item override. The chain is `base → markup → discount` (multiplicative, in order):

```
sale_price  = base_price * (1 + effective_markup   / 100)   # "retail / crossed-out price"
final_price = sale_price  * (1 -  effective_discount / 100)   # "what the customer pays"
```

- **Catalogue-wide columns** — `Catalogue.markup_percentage` (V89) and `Catalogue.discount_percentage` (V102): `DECIMAL(7, 2) NOT NULL DEFAULT 0`. Changeset validates `0..1000` for markup and `0..100` for discount.
- **Per-item overrides** — `Item.markup_percentage` (V97) and `Item.discount_percentage` (V102): nullable `DECIMAL(7, 2)`. `NULL` inherits the catalogue's value; any set Decimal (including `0`) overrides. `0` is load-bearing — it means "sell at base / no discount" even when the catalogue has a non-zero value.
- **Pure helpers on `Item`** — `sale_price/2`, `final_price/3`, `effective_markup/2`, `effective_discount/2`, `discount_amount/3`. All return `nil` when `base_price` is `nil`; results rounded to 2 decimals.
- **`Catalogue.item_pricing/1`** is the one-stop API for pricing UIs. Returns a map with every field: `base_price`, `catalogue_markup`, `item_markup`, `markup_percentage` (effective), `sale_price` (post-markup), `catalogue_discount`, `item_discount`, `discount_percentage` (effective), `discount_amount`, `final_price` (post-discount). Resolves both catalogue columns in a single preload; on preload failure, logs a warning and falls back to `{0, 0}` so templates never crash.
- **`:discount` and `:final_price` columns on `item_table`** — opt-in display columns; the component needs both `markup_percentage` and `discount_percentage` attrs when either is listed. `:discount` shows the effective percentage (honoring overrides); `:final_price` is the post-discount price. Existing `:price` column stays as the post-markup sale price.
- **Naming:** `Catalogue.item_pricing/1` renamed `:price` to `:sale_price` in 0.1.11 to pair with the new `:final_price`. `Item.sale_price/2` (the pure helper) kept its name — it's still the pre-discount computation.

### Smart catalogues

A smart catalogue (`Catalogue.kind == "smart"`) holds items whose cost is a function of *other* catalogues. Classic example: a "Services" smart catalogue with a "Delivery" item that says "5% of Kitchen, 3% of Plumbing, plus $20 flat of Hardware". **This module stores the user's intent; downstream consumers do the math.**

- **Data model**: `Catalogue.kind` (`"standard"` default / `"smart"`) + `Item.default_value`, `Item.default_unit` (both nullable; only `default_value` participates in UI inheritance — see below) + the `CatalogueRule` table. The parent catalogue of a rule row is *always* the one containing the item; the rule points to the *referenced* catalogue via `referenced_catalogue_uuid`.
- **Inherit semantics differ by leg**. `value` inherits: a rule's NULL `value` falls back to `item.default_value` at math time, and the picker surfaces this via an `Inherit: N` placeholder. `unit` does **not** inherit in the UI — each rule row's unit is self-contained, toggling a row on seeds `unit: "percent"` explicitly. `CatalogueRule.effective(rule, item)` still inherits both legs at the data layer (backward compat for rows stored with NULL `unit`); new UI writes always populate `unit` directly.
- **Unit vocabulary is open**. V1 recognizes `"percent"` and `"flat"`; the column is `VARCHAR(20)` so new units don't need a migration. `CatalogueRule.changeset` permits `percent`/`flat`/`nil`; `Item.changeset` validates `default_unit` against the same list — extend both if you add a unit. Consumers validate whatever they accept.
- **Replace-all API**: `Catalogue.put_catalogue_rules(item, specs, opts)` takes a list of rule specs (`%{referenced_catalogue_uuid:, value:, unit:, position:}`), runs a single `Ecto.Multi` transaction that deletes missing rows, inserts new ones, and updates overlapping ones, and logs one `smart_rules.synced` activity with `added`/`updated`/`removed` counts. Duplicate `referenced_catalogue_uuid` in the input → `{:error, {:duplicate_referenced_catalogue, uuid}}` before any write.
- **Read API**: `list_catalogue_rules/1` (preloads `referenced_catalogue`), `catalogue_rule_map/1` (same, keyed for O(1) lookup), `get_catalogue_rule/2` (single row). For the reverse direction, `list_items_referencing_catalogue/1` and `catalogue_reference_count/1` surface "which smart items use this catalogue?" — useful for warning before a catalogue delete.
- **A rule's `referenced_catalogue` must be `kind: "standard"`.** The smart-chain guard lives in `Rules.build_rule_changeset/2` (called from `create_catalogue_rule/2`, `update_catalogue_rule/3`, `put_catalogue_rules/3`, and `change_catalogue_rule/2`) and rejects rules pointing at a smart catalogue with the error `"must reference a standard catalogue, not a smart catalogue"`. The picker in `item_form_live.ex` mirrors this by listing only `Catalogue.list_catalogues(kind: :standard)` candidates. Self-references are rejected by side effect — the only way to self-reference is for the item's catalogue to be the referenced one, which is smart by definition. Referencing a deleted catalogue: the rule row stays (FK still valid — soft-delete sets status, not FK); `list_catalogue_rules/1`'s preloaded `referenced_catalogue` carries the `status` so the UI can dim or warn on deleted references.
- **Form flow**: `ItemFormLive` branches on `catalogue.kind`. Smart items show the `catalogue_rules_picker` + Default Value/Unit inputs; the LV owns `working_rules` as `%{uuid => %{value, unit}}` and calls `put_catalogue_rules/3` after the item saves. `CatalogueFormLive` exposes the Kind selector at create time.
- **Component**: `catalogue_rules_picker/1` renders a checkbox + numeric input + unit dropdown per candidate catalogue; unchecked rows keep their inputs disabled but visible. Event names are customizable via attrs (`on_toggle`/`on_set_value`/`on_set_unit`/`on_clear`). The value input's placeholder shows `Inherit: N` when `item_default_value` is set. **There is no `item_default_unit` attr** — the unit dropdown reads only from the rule itself, falling back to the first entry of the `units` attr (default `"percent"`) when the rule has no unit. Changing the item's `default_unit` therefore never alters any rule row's visible unit.
- **Smart items don't use `base_price` / `markup_percentage` / `discount_percentage`.** Those columns still exist on the row (shared Item schema) but the smart item form doesn't surface them and the convention is to leave them `nil`. A smart item's intrinsic standalone fee lives in `default_value` + `default_unit`. For ruleless smart items, `default_value: 50, default_unit: "flat"` means "this item costs $50 flat". When rules exist, `default_value` still acts as a fallback for any rule row whose `value` is blank (the data-layer inheritance surfaced via the `Inherit: N` placeholder); `default_unit` is *not* a UI fallback for rule rows — each row's unit is explicit.
- **No math on our side.** `Catalogue.item_pricing/1` and `Item.final_price/3` work purely off `base_price` + markup + discount and do not consult rules or defaults — they're the standard-item pricing helpers. Smart-item consumers read `list_catalogue_rules/1` + the item's `default_value`/`default_unit` and do their own math.

### Attachments (featured image + file grid)

Both catalogue and item forms support a featured image + a folder-scoped file grid via the shared `PhoenixKitCatalogue.Attachments` module. All the form plumbing (mount, upload progress, media-selector integration, file detach with `FolderLink` awareness, folder-rename on create) lives there; the form LVs just delegate.

- **Folder-per-resource:** each item/catalogue owns one folder in `phoenix_kit_media_folders`, named deterministically (`catalogue-item-<uuid>` / `catalogue-<uuid>`). `data["files_folder_uuid"]` on the resource points at it. For `:new` forms the folder is created with a pending random name and `maybe_rename_pending_folder/2` renames it after save — non-fatal if rename fails (logs, returns `:ok`).
- **Featured image:** `data["featured_image_uuid"]` on the resource points at any `phoenix_kit_files` row (not necessarily in this resource's folder — cross-resource duplicate moves can leave the featured pointer in another folder, and `compute_files_list/1` surfaces it in the grid anyway).
- **Media picker scope:** catalogue + item forms render `<.live_component module={MediaSelectorModal} scope_folder_id={@files_folder_uuid} ...>`. The modal's `scope_folder_id` attr (added in phoenix_kit core) filters the browse query to files whose `folder_uuid` matches OR who have a `FolderLink` to that folder, and sets the same folder as home/link on post-upload files. This means uploading the same image to two items creates a `FolderLink` on the second — the file keeps its home with the first but appears in both grids.
- **File detach semantics** (`Attachments.trash_file/2`): if the file's home folder is this resource AND it's only here → `Storage.trash_file`; home here + linked elsewhere → promote a link to home and delete the promoted link (the file stays alive under its new owner); linked here (home elsewhere) → delete the link only. Also clears the featured pointer if the removed file was featured.
- **Save-path contract:** LVs call `Attachments.inject_attachment_data(params, socket)` before `update_item` / `update_catalogue` so `params["data"]` ends up with `files_folder_uuid` + `featured_image_uuid`. Save button is `disabled` while `@uploads.attachment_files.entries != []` to avoid racing a mid-upload `handle_progress` write against the save.
- **Query cap:** `list_files_in_folder/1` uses `limit: 200` to keep a mistakenly-huge folder from freezing the form on mount (the dropzone itself caps a single submission at 20 files).
- **`file_type` allowlist widened** (in phoenix_kit core): `File.changeset` now permits `["image", "video", "audio", "document", "archive", "other"]` so `file_type_from_mime/1` can safely return `"other"` for unknowns.

### Metadata (opt-in fields on items and catalogues)

`PhoenixKitCatalogue.Metadata` holds code-defined lists of metadata fields that items **and catalogues** can opt into (categories stay lightweight). Values live on `resource.data["meta"]` as a flat `%{key => string}` map — not on their own columns. Adding a field is a code edit; removing one does **not** wipe stored values (they surface in the form as "Legacy" rows with a remove-only action, so the user cleans them up explicitly).

- `definitions(:item)` and `definitions(:catalogue)` each return `[%{key: ..., label: Gettext.gettext(PhoenixKitWeb.Gettext, ...)}, ...]`. The `:key` is stable (JSONB key, never translated). The `:label` is gettext-wrapped at call time — callers cannot cache it across locale changes. Resource types keep their own separate definition lists (items cover color/weight/dimensions/material; catalogues cover brand/collection/season/region/vendor_ref).
- `definition(:item, key)` / `definition(:catalogue, key)` fetch a single entry by stable key; returns `nil` for unknown keys.
- Both Item and Catalogue form LVs render the same metadata tab shape: pick-a-field dropdown (only definitions not yet attached) + one text input per attached key, folded into `resource.data["meta"]` on save via a private `inject_meta_into_data/2`. Blank values drop; legacy keys pass through untouched.
- There is **no** `Catalogue.set_metadata/3` context helper — use `update_item/3` / `update_catalogue/3` with `%{data: %{"meta" => new_meta}}`. Merge the new meta with whatever else lives on `data`.

### Item Picker component

`PhoenixKitCatalogue.Web.Components.ItemPicker` is a combobox LiveComponent for picking a single item via server-side search. Exposed through the `<.item_picker id=... category_uuids=... locale=... />` wrapper in `Components`. Emits `{:item_picker_select, id, %Item{}}` / `{:item_picker_clear, id}` up to the parent LV (parent needs matching `handle_info/2` clauses). Keyboard/a11y is driven by a colocated `ItemPicker` hook (no external JS). Scope composes via `:category_uuids`, `:catalogue_uuids`, `:include_descendants` — the latter passes straight through to the `search_items/2` tree expansion.

The dropdown is absolutely positioned with `z-50` — the container's ancestors must not clip overflow.

### Activity Logging

Every mutating operation in `Catalogue` context is logged via `PhoenixKit.Activity.log/1`:

- **Pattern**: Private `log_activity/1` helper guarded by `Code.ensure_loaded?(PhoenixKit.Activity)` with rescue to `Logger.warning`. Activity logging failures never crash the primary operation.
- **Actor tracking**: All mutating functions accept `opts \\ []` keyword list. Pass `actor_uuid: user.uuid` to attribute the action.
- **Actions logged**: `manufacturer.created/updated/deleted`, `supplier.created/updated/deleted`, `catalogue.created/updated/deleted/trashed/restored/permanently_deleted`, `category.created/updated/deleted/trashed/restored/permanently_deleted/moved/positions_swapped`, `item.created/updated/deleted/trashed/restored/permanently_deleted/moved/bulk_trashed`, `manufacturer.suppliers_synced`, `supplier.manufacturers_synced`, `smart_rules.synced` (with `added`/`updated`/`removed`/`total` counts), `import.started`, `import.completed`. Since V103, `category.trashed` / `category.restored` / `category.permanently_deleted` carry `subtree_size` + `items_cascaded`; `category.moved` includes `from_parent_uuid` / `to_parent_uuid` (in-catalogue reparents via `move_category_under/3`) or `from_catalogue_uuid` / `to_catalogue_uuid` + `subtree_size` + `items_cascaded` (cross-catalogue moves). Attachments (file uploads, featured-image changes) are not individually logged — they're captured as part of the `item.updated` / `catalogue.updated` entry on the containing save.
- **Mode**: `"manual"` for user actions, `"auto"` for import-created items/categories
- **LiveViews**: Extract actor UUID via `actor_opts(socket)` private helper reading `socket.assigns[:phoenix_kit_current_user]`

### Import System

Multi-step file import wizard for bulk item creation from XLSX/CSV files.

- **Parser** (`import/parser.ex`): Format detection, XLSX via `XlsxReader`, CSV with auto-separator detection, BOM stripping
- **Mapper** (`import/mapper.ex`): Auto-detect column mappings, unit normalization, import plan builder with validation
- **Executor** (`import/executor.ex`): Three-phase execution (1: get-or-create categories + manufacturers + suppliers in column mode; 2: insert items resolving category/manufacturer per row; 3: create manufacturer↔supplier M:N links from per-row pairs and/or fixed supplier→all-touched-manufacturers), progress reporting, language support, actor_uuid threading for activity logs. Items get `manufacturer_uuid` directly; suppliers attach via the M:N join because items don't have a supplier FK
- **ImportLive** (`web/import_live.ex`): Upload → sheet select → column mapping → confirm → importing → results. ETS buffering for large files, duplicate detection, multilang support. Three pickers (category / manufacturer / supplier) share a four-mode vocabulary — `:none` / `:column` (per-row from a CSV column) / `:create` (inline form, persisted at execute time so cancelling the confirm step doesn't leave orphans) / `:existing` (pick from active records). The `available_picker_columns/2` filter prevents a picker from silently clobbering a sibling's column mapping; switching sheets / replacing the file calls `reset_picker_state/1` so picker assigns can never reference stale column indices

### Search API

One unified search function plus two scoped convenience wrappers, each paired with an unbounded count function. All share a private `search_items_base/2` query builder, so behavior is consistent: items in deleted catalogues/categories are always excluded; deterministic paging via trailing `asc: i.uuid`.

| List function | Count function | Scope behavior |
|---------------|---------------|---------------|
| `search_items/2` | `count_search_items/2` | Accepts `:catalogue_uuids` and `:category_uuids` scope filters. Neither given → global. Either/both → AND-composed. A narrowed `:category_uuids` implicitly excludes uncategorized items. |
| `search_items_in_catalogue/3` | `count_search_items_in_catalogue/2` | Thin wrapper around `search_items/2` with `catalogue_uuids: [catalogue_uuid]`. Orders by `asc_nulls_last: c.position, asc: i.name, asc: i.uuid` to walk categories in display order (important for the detail view UX). |
| `search_items_in_category/3` | `count_search_items_in_category/2` | Thin wrapper around `search_items/2` with `category_uuids: [category_uuid]`. |

All list functions take `:limit` (default 50) and `:offset` (default 0) in `opts`. Count functions accept the same scope filters but ignore `:limit`/`:offset` — they return the unbounded total.

**Composing scope with `list_catalogues_by_name_prefix/2`** — the natural pattern for "search only a subset of catalogues":

```elixir
uuids =
  "Kit"
  |> Catalogue.list_catalogues_by_name_prefix()
  |> Enum.map(& &1.uuid)

Catalogue.search_items("oak", catalogue_uuids: uuids)
Catalogue.count_search_items("oak", catalogue_uuids: uuids)
```

The `scope_selector/1` component in `web/components.ex` renders a disclosure with catalogue/category checkbox lists and emits toggle events (customizable names) — the LV owns the selected-UUIDs state and feeds them straight into the search options.

**LiveView usage pattern** (see `CatalogueDetailLive.run_search/2` and `load_next_search_batch/1`): fetch first page + total on search, render a sentinel while `search_has_more = loaded < total`, append pages via the shared `InfiniteScroll` hook. `search_results_summary` accepts an optional `loaded` attr to render "Showing X of Y" while paging.

**Async + loading state** (same LiveView): searches run inside `start_async(:search, …)` so a newer query cancels a pending one and stale responses are dropped by a query-equality guard in `handle_async(:search, {:ok, …})`. While a search is in flight, the template shows a "Searching for …" status line (first search) or dims the prior results with `opacity-50` and shows a small spinner next to the summary (subsequent searches). Unexpected task exits log a warning and surface a user-visible flash; expected cancellation reasons (`:shutdown` / `:killed`) are no-ops.

### Web Layer

- **Admin** (9 LiveViews): CataloguesLive (index for catalogues/manufacturers/suppliers), CatalogueDetailLive, CatalogueFormLive, CategoryFormLive, ItemFormLive, ManufacturerFormLive, SupplierFormLive, ImportLive (multi-step import wizard), EventsLive (activity log with infinite scroll)
- **Components** (`PhoenixKitCatalogue.Web.Components`): Reusable components — `item_table`, `search_input`, `search_results_summary`, `scope_selector`, `catalogue_rules_picker` (smart catalogue rule editor), `empty_state`, `view_mode_toggle`. All features opt-in via attrs. All text localized via `Gettext.gettext(PhoenixKitWeb.Gettext, ...)`. Components never crash — unknown columns, unloaded associations, nil values, and bad function arguments produce "—" placeholders and Logger warnings. `scope_selector` is the partner of the scoped search API: it renders a disclosure with catalogue/category checkbox lists and emits customizable toggle/clear events — the LV owns the selected-UUIDs state and feeds them into `Catalogue.search_items/2`'s `:catalogue_uuids` / `:category_uuids` opts.
- **Routes**: Admin routes auto-generated from `admin_tabs/0`
- **Paths**: Centralized path helpers in `Paths` module — always use these instead of hardcoding URLs

### Form conventions (0.1.12+)

All form LiveViews (`catalogue_form_live`, `item_form_live`, `manufacturer_form_live`, `supplier_form_live`, `category_form_live`) use **PhoenixKit's component-style field bindings**, not raw `<input name="x">` markup. The pattern:

- `<.form for={@form} action="#" phx-change="validate" phx-submit="save">` — `@form` comes from `to_form(changeset)`
- Fields: `<.input field={@form[:sku]} type="text" label="SKU" />`, `<.select field={@form[:status]} options={[{label, value}, ...]} />`, `<.textarea field={@form[:description]} />`
- Each LV has a private `assign_changeset/2` helper that assigns **both** `:changeset` (for `<.translatable_field>`, which needs the raw changeset) and `:form = to_form(changeset)` (for the component-style inputs). Every mount / validate / save-error path goes through that helper so the two assigns can never drift apart.
- Inline daisyUI modifiers ride on the `class` attr: `<.select field={@form[:x]} class="transition-colors focus-within:select-primary" />`, `<.input ... class="font-mono" />`. The attr is threaded onto the styled element itself (input/select/textarea/checkbox), not the outer wrapper — matches the Phoenix 1.7 generator convention. `<.input>` also has `wrapper_class` for the outer `<div phx-feedback-for>` when needed.

**Multilang wrapper boundary**: only translatable fields (name, description) live inside `<.multilang_fields_wrapper>`. Pricing, classification, status, actions, and smart-catalogue rules all render as **siblings outside** the wrapper. See phoenix_kit's `AGENTS.md > Multilang Form Components > Wrapper scope rule` — the wrapper's id includes `current_lang` so everything inside re-mounts on a language switch; keeping it tiny means only name+description pay that cost. Skeleton/fields visibility is flipped client-side by `switch_lang_js/2` — do **not** pass `switching_lang={@switching_lang}` to the wrapper; the attr is no longer read and doing so trips an "undefined attribute" warning against the vendored `deps/phoenix_kit` cache.

**Smart item form branches on `catalogue.kind`**: the whole "Pricing & Identification" section (SKU, Base Price, Unit, Markup Override, Discount Override) is hidden when kind == `"smart"`. Smart items show name/description + a Catalogue Rules section with the `<.catalogue_rules_picker>` component + a Default Value / Default Unit pair, plus the same Classification section (Category, Manufacturer) standard items get — categories within a smart catalogue exist purely for organisation and don't affect rule-based pricing. Smart items never use `base_price` / `markup_percentage` / `discount_percentage` — the intrinsic fee lives in `default_value` + `default_unit`.

**Move card also branches**: standard items get "Move to Another Category" (dropdown of `list_all_categories()` results, calls `move_item_to_category/3`); smart items get "Move to Another Smart Catalogue" (dropdown filtered to other smart catalogues via `list_catalogues(kind: :smart)`, calls `move_item_to_catalogue/3` which clears the category and sets the new catalogue). Each card only renders when its target list is non-empty.

**Tabs on Item and Catalogue forms** — both `item_form_live` and `catalogue_form_live` split content into Details / Metadata / Files tabs. Tab state (`current_tab`, `switch_tab` event, private `parse_tab/1`) is duplicated in each LV; panels stay in the DOM and toggle via `hidden` so multilang wrapper state + in-flight input survive tab switches. Category form stays tab-less — it's a lightweight taxonomy node with only the featured image card above its form.

**Featured image tiers** — all three resource types (Catalogue, Category, Item) accept a featured image through `Attachments.mount_attachments/2` + `MediaSelectorModal`. Catalogue and Item additionally support an inline files dropzone (registered via `Attachments.allow_attachment_upload/1`); Category does not. The folder is created lazily the first time the picker opens, so categories without a featured image never materialize a folder. Folder naming: `catalogue-<uuid>` / `catalogue-category-<uuid>` / `catalogue-item-<uuid>` — see `Attachments.folder_name_for/1`.

**`import_live.ex` is a principled exception** — it uses raw `<select name={"mapping[#{i}]"}>` because its column-mapping UI has runtime-constructed field names that `%Phoenix.HTML.FormField{}` can't model, and it assigns `:current_lang` directly in its own `handle_event("switch_language", ...)` instead of going through `handle_switch_language/2` (so the debounced skeleton UX doesn't apply to the import wizard's language picker, which is semantically different — it's picking "which language is this spreadsheet in?", not "which translation am I editing?"). Don't try to refactor the import wizard into the component-style pattern without rethinking its shape.

### Settings Keys

`catalogue_enabled`

### File Layout

```
lib/phoenix_kit_catalogue.ex                    # Main module (PhoenixKit.Module behaviour)
lib/phoenix_kit_catalogue/
├── catalogue.ex                               # Public context — thin API; delegates to catalogue/*.ex submodules
├── catalogue/                                 # Extracted submodules (internal API; callers stay on `Catalogue.*`)
│   ├── activity_log.ex                        # Guarded + rescued `PhoenixKit.Activity.log` wrapper
│   ├── counts.ex                              # item_count_*, category_counts_*, uncategorized_count_*
│   ├── helpers.ex                             # fetch_attr, sanitize_like, shared polymorphic accessors
│   ├── links.ex                               # Manufacturer↔Supplier M2M CRUD + sync
│   ├── manufacturers.ex                       # Manufacturer CRUD with activity logging
│   ├── pub_sub.ex                             # Single topic + broadcast helpers ({:catalogue_data_changed, kind, uuid})
│   ├── rules.ex                               # Smart-catalogue rule CRUD + put_catalogue_rules/3 replace-all
│   ├── search.ex                              # search_items/2 + scoped wrappers, count_*
│   ├── suppliers.ex                           # Supplier CRUD with activity logging
│   ├── translations.ex                        # Multilang read/write against schema.data JSONB
│   └── tree.ex                                # V103 recursive-CTE helpers (subtree/ancestor/children-index)
├── attachments.ex                             # Form-level featured-image + inline files dropzone wiring (shared by catalogue_form_live + item_form_live)
├── metadata.ex                                # Per-resource-type opt-in metadata field definitions (labels are gettext-wrapped)
├── paths.ex                                   # Centralized URL path helpers
├── schemas/
│   ├── cat_catalogue.ex                       # Catalogue schema + changeset (kind: standard|smart)
│   ├── catalogue_rule.ex                      # Smart-catalogue rule row (item → referenced catalogue)
│   ├── category.ex                            # Category schema + changeset
│   ├── item.ex                                # Item schema + changeset (default_value/default_unit)
│   ├── manufacturer.ex                        # Manufacturer schema + changeset
│   ├── manufacturer_supplier.ex               # Join table schema
│   └── supplier.ex                            # Supplier schema + changeset
├── import/
│   ├── parser.ex                              # XLSX/CSV file parsing
│   ├── mapper.ex                              # Column mapping + auto-detection
│   └── executor.ex                            # Import execution with progress reporting
└── web/
    ├── components.ex                          # Reusable components (item_table, search_input, item_picker wrapper, etc.)
    ├── components/
    │   └── item_picker.ex                     # Combobox LiveComponent (server-side search + colocated JS hook)
    ├── catalogues_live.ex                     # Index page (catalogues/manufacturers/suppliers)
    ├── catalogue_detail_live.ex               # Catalogue detail with categories + items (tree depths render indented)
    ├── catalogue_form_live.ex                 # Create/edit catalogue + featured image + files dropzone
    ├── category_form_live.ex                  # Create/edit/move category (with parent picker + Move-to-parent)
    ├── item_form_live.ex                      # Create/edit/move item (with tabs: Details / Metadata / Files)
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
- **Single public context** — callers go through `PhoenixKitCatalogue.Catalogue` for all business logic. Internally the context is broken into `PhoenixKitCatalogue.Catalogue.{Rules, Search, Manufacturers, Suppliers, Links, Counts, Translations, PubSub, ActivityLog, Helpers}` submodules for organization — they are an implementation detail, and `Catalogue` re-exports the public surface via `defdelegate`. **Do not** call submodules directly from LiveViews or external consumers; add new APIs to `Catalogue` and delegate inward. Schemas stay data-only with changesets.
- **Multilang fields** — name and description fields use PhoenixKit's `Multilang` module for i18n support
- **Soft-delete via status field** — catalogues, categories, and items use `status: "deleted"` for soft-delete; manufacturers and suppliers use hard-delete only

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

## Tailwind CSS Scanning

This module implements `css_sources/0` returning `[:phoenix_kit_catalogue]` so PhoenixKit's installer adds the correct `@source` directive to the parent's `app.css`. Without this, Tailwind purges classes unique to this module's templates. CSS-source discovery is automatic at compile time via the `:phoenix_kit_css_sources` compiler — see `phoenix_kit/AGENTS.md > Tailwind CSS Scanning for External Modules`.

## JavaScript Hooks

All shared DOM hooks (RowMenu, TableCardView, SortableGrid, InfiniteScroll) come from `phoenix_kit`'s bundled `priv/static/assets/phoenix_kit.js`, which exports `window.PhoenixKitHooks` and is already spread into the parent LiveSocket by `mix phoenix_kit.install`. This module does not ship its own external hooks. Any colocated hooks declared with `:type={Phoenix.LiveView.ColocatedHook}` inside our HEEx are bundled automatically.

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

> **Maintainer-owned:** `CHANGELOG.md` entries are written by the project maintainer, not by agents. If you bump `mix.exs` `@version` and the CHANGELOG hasn't caught up yet, that's intentional — flag the gap to the user and stop. Do not auto-write entries.

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
