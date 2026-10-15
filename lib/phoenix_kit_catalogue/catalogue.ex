defmodule PhoenixKitCatalogue.Catalogue do
  @moduledoc """
  Context module for managing catalogues, manufacturers, suppliers, categories, and items.

  ## Soft-Delete System

  Catalogues, categories, and items support soft-delete via a `status` field set to `"deleted"`.
  Manufacturers and suppliers use hard-delete only (they are reference data).

  ### Cascade behaviour

  **Downward cascade on trash/permanently_delete:**
  - Trashing a catalogue → trashes all its categories and their items
  - Trashing a category → trashes all its items
  - Permanently deleting follows the same cascade but removes from DB

  **Upward cascade on restore:**
  - Restoring an item → restores its parent category if deleted
  - Restoring a category → restores its parent catalogue if deleted, plus all items

  All cascading operations are wrapped in database transactions.

  ## Usage from IEx

      alias PhoenixKitCatalogue.Catalogue

      # Create a full hierarchy
      {:ok, cat} = Catalogue.create_catalogue(%{name: "Kitchen"})
      {:ok, category} = Catalogue.create_category(%{name: "Frames", catalogue_uuid: cat.uuid})
      {:ok, item} = Catalogue.create_item(%{name: "Oak Panel", category_uuid: category.uuid, base_price: 25.50})

      # Soft-delete and restore
      {:ok, _} = Catalogue.trash_catalogue(cat)   # cascades to category + item
      {:ok, _} = Catalogue.restore_catalogue(cat)  # cascades back

      # Move operations
      {:ok, _} = Catalogue.move_category_to_catalogue(category, other_catalogue_uuid)
      {:ok, _} = Catalogue.move_item_to_category(item, other_category_uuid)

  ## Smart catalogues

  For an end-to-end walkthrough of integrating smart catalogues
  (`kind: "smart"` items priced as functions of other catalogues), see
  the [Smart Catalogues guide](smart_catalogues.md).
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{
    ActivityLog,
    Attributes,
    AttributeSets,
    Catalogues,
    Categories,
    Counts,
    CrmLink,
    Duplication,
    Folders,
    Helpers,
    ItemSupplierInfos,
    Links,
    Manufacturers,
    PdfLibrary,
    PubSub,
    Rules,
    Search,
    Shared,
    SmartPricing,
    SupplierComments,
    SupplierFields,
    Suppliers,
    Translations,
    Trash,
    Tree
  }

  alias PhoenixKit.Utils.Values
  alias PhoenixKitCatalogue.MediaFolders
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, ItemAttributeSet}

  require Logger

  @reorder_max_uuids Shared.reorder_max_uuids()

  # What an `.updated` entry reports as changed, per resource. The activity
  # feed used to say only that a row had been updated, naming it but never
  # what moved (boss via Max, 2026-09-20). `ActivityLog.changed_fields/3`
  # turns these into `from`/`to` pairs, which core renders as `old → new`.
  #
  # `description` is tracked but records only THAT it changed — see
  # `ActivityLog`'s `@flag_only_fields`. A move is not here at all; it has its
  # own action (`item.moved`, `category.moved`, `catalogue.moved_to_folder`)
  # carrying both ends.
  @item_logged_fields [
    :name,
    :sku,
    :base_price,
    :markup_percentage,
    :discount_percentage,
    :unit,
    :item_type,
    :status,
    :default_value,
    :default_unit,
    :description
  ]

  # Slug projection tables read by `get_item_by_slug/3` / `get_category_by_slug/3`
  # (owned by `PhoenixKitCatalogue.Catalogue.Slugs`'s generation rule, kept in
  # sync by the `trg_cat_item_slugs` / `trg_cat_category_slugs` triggers).
  @item_slugs_table "phoenix_kit_cat_item_slugs"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # Same idea for items, scoped by `(catalogue_uuid, category_uuid)`.
  # Only fires when both scope fields are already in attrs — otherwise
  # we don't have enough information to compute the next position, so
  # we leave it at the schema default (0).
  defp maybe_put_item_position(attrs) when is_map(attrs) do
    cond do
      Helpers.has_attr?(attrs, :position) ->
        attrs

      Helpers.has_attr?(attrs, :catalogue_uuid) ->
        catalogue_uuid = Helpers.fetch_attr(attrs, :catalogue_uuid)

        category_uuid =
          if Helpers.has_attr?(attrs, :category_uuid),
            do: attrs |> Helpers.fetch_attr(:category_uuid) |> Values.blank_to_nil(),
            else: nil

        if is_binary(catalogue_uuid) do
          Helpers.put_attr(attrs, :position, next_item_position(catalogue_uuid, category_uuid))
        else
          attrs
        end

      true ->
        attrs
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturers — see PhoenixKitCatalogue.Catalogue.Manufacturers
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_manufacturers(opts \\ []), to: Manufacturers

  defdelegate get_manufacturer(uuid), to: Manufacturers

  defdelegate get_manufacturer!(uuid), to: Manufacturers

  defdelegate create_manufacturer(attrs, opts \\ []), to: Manufacturers

  defdelegate update_manufacturer(manufacturer, attrs, opts \\ []), to: Manufacturers

  defdelegate delete_manufacturer(manufacturer, opts \\ []), to: Manufacturers

  defdelegate change_manufacturer(manufacturer, attrs \\ %{}), to: Manufacturers

  @doc """
  Resolves a manufacturer UUID to a unified map regardless of source
  (local or CRM). Note items still reference the LOCAL row by hard FK.
  """
  defdelegate resolve_manufacturer(uuid), to: Manufacturers, as: :resolve

  @doc "Lists manufacturers from all available sources (local + CRM) as normalized maps."
  defdelegate list_all_manufacturers(opts \\ []), to: Manufacturers, as: :list_all

  # ═══════════════════════════════════════════════════════════════════
  # Suppliers — see PhoenixKitCatalogue.Catalogue.Suppliers
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_suppliers(opts \\ []), to: Suppliers

  defdelegate get_supplier(uuid), to: Suppliers

  defdelegate get_supplier!(uuid), to: Suppliers

  defdelegate create_supplier(attrs, opts \\ []), to: Suppliers

  defdelegate update_supplier(supplier, attrs, opts \\ []), to: Suppliers

  defdelegate delete_supplier(supplier, opts \\ []), to: Suppliers

  defdelegate change_supplier(supplier, attrs \\ %{}), to: Suppliers

  @doc "Resolves a supplier UUID to a unified map regardless of source (local or CRM)."
  defdelegate resolve_supplier(uuid), to: Suppliers, as: :resolve

  @doc "Lists all suppliers from all available sources (local + CRM) as normalized maps."
  defdelegate list_all_suppliers(opts \\ []), to: Suppliers, as: :list_all

  # ═══════════════════════════════════════════════════════════════════
  # CRM links — see PhoenixKitCatalogue.Catalogue.CrmLink
  # ═══════════════════════════════════════════════════════════════════

  defdelegate crm_link_available?(), to: CrmLink, as: :available?

  defdelegate crm_link_candidates(), to: CrmLink, as: :list_candidates

  defdelegate link_supplier_to_crm(supplier, company_uuid, opts \\ []),
    to: CrmLink,
    as: :link_supplier

  defdelegate unlink_supplier_from_crm(supplier, opts \\ []), to: CrmLink, as: :unlink_supplier

  defdelegate link_manufacturer_to_crm(manufacturer, company_uuid, opts \\ []),
    to: CrmLink,
    as: :link_manufacturer

  defdelegate unlink_manufacturer_from_crm(manufacturer, opts \\ []),
    to: CrmLink,
    as: :unlink_manufacturer

  @doc """
  What a CRM party supplies / manufactures — the read model behind the
  catalogue panel on a company's CRM page. Both accept a party uuid and match
  local projections of it too.
  """
  defdelegate items_supplied_by(party_uuid), to: Suppliers

  defdelegate items_manufactured_by(party_uuid), to: Manufacturers

  @doc "Batch supplier resolution for a page of rows — see `Suppliers.resolve_many/1`."
  defdelegate resolve_suppliers(uuids), to: Suppliers, as: :resolve_many

  @doc "Batch manufacturer resolution for a page of items — see `Manufacturers.resolve_many/1`."
  defdelegate resolve_manufacturers(uuids), to: Manufacturers, as: :resolve_many

  # ═══════════════════════════════════════════════════════════════════
  # Item ↔ Supplier info — see PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  # ═══════════════════════════════════════════════════════════════════

  # ── Duplication (see `Catalogue.Duplication`) ────────────────────
  defdelegate duplicate_item(item, opts \\ []), to: Duplication

  defdelegate duplicate_category(category, opts \\ []), to: Duplication

  defdelegate duplicate_catalogue(catalogue, opts \\ []), to: Duplication

  defdelegate catalogue_copy_counts(catalogue_uuid), to: Duplication

  defdelegate bulk_duplicate_items(uuids, opts \\ []), to: Duplication

  defdelegate bulk_duplicate_categories(uuids, opts \\ []), to: Duplication

  defdelegate list_supplier_infos_for_item(item_uuid), to: ItemSupplierInfos, as: :list_for_item

  defdelegate supplier_cost_ranges(item_uuids), to: ItemSupplierInfos, as: :cost_ranges

  defdelegate get_supplier_info(uuid), to: ItemSupplierInfos, as: :get

  defdelegate create_supplier_info(attrs, opts \\ []), to: ItemSupplierInfos, as: :create

  defdelegate update_supplier_info(info, attrs, opts \\ []), to: ItemSupplierInfos, as: :update

  defdelegate delete_supplier_info(info, opts \\ []), to: ItemSupplierInfos, as: :delete

  defdelegate set_primary_supplier_info(info, opts \\ []),
    to: ItemSupplierInfos,
    as: :set_primary

  @doc "Returns the primary supplier-info row for an item, or `nil` if none is marked primary."
  defdelegate primary_supplier_info_for_item(item_uuid),
    to: ItemSupplierInfos,
    as: :primary_for_item

  @doc "Returns all rows for an item/supplier pair ordered newest-first (current + closed)."
  defdelegate supplier_info_history_for_pair(item_uuid, supplier_uuid),
    to: ItemSupplierInfos,
    as: :history_for_pair

  @doc "Returns the current junction row for an item/supplier pair or nil."
  defdelegate active_supplier_info_for(item_uuid, supplier_uuid),
    to: Suppliers,
    as: :active_info_for

  @doc "Closes the current junction row and inserts a successor with the new unit cost."
  defdelegate revise_supplier_info_cost(info, new_cost, opts \\ []),
    to: ItemSupplierInfos,
    as: :revise_unit_cost

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturer ↔ Supplier links — see PhoenixKitCatalogue.Catalogue.Links
  # ═══════════════════════════════════════════════════════════════════

  defdelegate link_manufacturer_supplier(manufacturer_uuid, supplier_uuid, opts \\ []),
    to: Links

  defdelegate delete_manufacturer_supplier_links_for(uuid, opts \\ []),
    to: Links,
    as: :delete_links_for

  defdelegate unlink_manufacturer_supplier(manufacturer_uuid, supplier_uuid, opts \\ []),
    to: Links

  defdelegate list_suppliers_for_manufacturer(manufacturer_uuid), to: Links

  defdelegate list_manufacturers_for_supplier(supplier_uuid), to: Links

  defdelegate linked_supplier_uuids(manufacturer_uuid), to: Links

  defdelegate linked_manufacturer_uuids(supplier_uuid), to: Links

  defdelegate sync_manufacturer_suppliers(manufacturer_uuid, supplier_uuids, opts \\ []),
    to: Links

  defdelegate sync_supplier_manufacturers(supplier_uuid, manufacturer_uuids, opts \\ []),
    to: Links

  # ═══════════════════════════════════════════════════════════════════
  # Catalogues — see PhoenixKitCatalogue.Catalogue.Catalogues
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_catalogues(opts \\ []), to: Catalogues
  defdelegate list_catalogues_by_name_prefix(prefix, opts \\ []), to: Catalogues
  defdelegate deleted_catalogue_count(), to: Catalogues
  defdelegate get_catalogue(uuid), to: Catalogues
  defdelegate fetch_catalogue!(uuid), to: Catalogues
  defdelegate get_catalogue!(uuid, opts \\ []), to: Catalogues
  defdelegate create_catalogue(attrs, opts \\ []), to: Catalogues
  defdelegate update_catalogue(catalogue, attrs, opts \\ []), to: Catalogues
  defdelegate delete_catalogue(catalogue, opts \\ []), to: Catalogues
  defdelegate trash_catalogue(catalogue, opts \\ []), to: Catalogues
  defdelegate restore_catalogue(catalogue, opts \\ []), to: Catalogues
  defdelegate permanently_delete_catalogue(catalogue, opts \\ []), to: Catalogues
  defdelegate change_catalogue(catalogue, attrs \\ %{}), to: Catalogues
  defdelegate next_catalogue_position(), to: Catalogues
  defdelegate reorder_catalogues(ordered_uuids, opts \\ []), to: Catalogues

  # ═══════════════════════════════════════════════════════════════════
  # Categories — see PhoenixKitCatalogue.Catalogue.Categories
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_categories_for_catalogue(catalogue_uuid), to: Categories
  defdelegate list_categories_metadata_for_catalogue(catalogue_uuid, opts \\ []), to: Categories
  defdelegate category_summary_for_catalogue(catalogue_uuid, opts \\ []), to: Categories
  defdelegate list_all_categories(), to: Categories
  defdelegate get_category(uuid), to: Categories
  defdelegate get_category!(uuid), to: Categories
  defdelegate get_category_by_slug(slug, lang, opts \\ []), to: Categories
  defdelegate create_category(attrs, opts \\ []), to: Categories
  defdelegate update_category(category, attrs, opts \\ []), to: Categories
  defdelegate delete_category(category, opts \\ []), to: Categories
  defdelegate trash_category(category, opts \\ []), to: Categories
  defdelegate restore_category(category, opts \\ []), to: Categories
  defdelegate permanently_delete_category(category, opts \\ []), to: Categories
  defdelegate permanent_delete_scope(category), to: Categories

  defdelegate move_category_to_catalogue(category, target_catalogue_uuid, opts \\ []),
    to: Categories

  defdelegate move_category_under(category, new_parent_uuid, opts \\ []), to: Categories
  defdelegate bulk_move_categories_under(uuids, new_parent_uuid, opts \\ []), to: Categories
  defdelegate swap_category_positions(cat_a, cat_b, opts \\ []), to: Categories
  defdelegate change_category(category, attrs \\ %{}), to: Categories
  defdelegate category_subtree_uuids(category_uuids), to: Categories
  defdelegate list_move_target_categories(category), to: Categories
  defdelegate list_category_tree(catalogue_uuid, opts \\ []), to: Categories
  defdelegate list_live_categories(catalogue_uuids), to: Categories
  defdelegate list_child_categories(catalogue_uuid, parent_uuid, opts \\ []), to: Categories
  defdelegate category_children_counts(catalogue_uuid, opts \\ []), to: Categories
  defdelegate category_uuids_with_children(catalogue_uuid, opts \\ []), to: Categories
  defdelegate next_category_position(catalogue_uuid, parent_uuid \\ nil), to: Categories

  defdelegate reorder_categories(catalogue_uuid, parent_uuid, ordered_uuids, opts \\ []),
    to: Categories

  defdelegate reorder_categories_groups(catalogue_uuid, groups, opts \\ []), to: Categories
  defdelegate category_slug_taken?(slug, lang, opts \\ []), to: Categories

  defdelegate bulk_move_categories_to_catalogue(
                uuids,
                target_catalogue_uuid,
                parent_uuid,
                opts \\ []
              ),
              to: Categories

  defdelegate bulk_trash_categories(uuids, disposition, opts), to: Categories

  @doc """
  Lists a page of items for a single category, in the admin's Manual
  order by default (`:sort_by`, `:sort_dir` select another).

  Used by the infinite-scroll detail view; returns at most `:limit`
  items starting at `:offset`. Preloads `:catalogue` and `:manufacturer`
  so the table cell renderers can access them without extra queries.

  DIRECT items only — never the subtree. The detail page's "include
  subcategory items" toggle is a SEARCH refinement (Max, 2026-08-30:
  it "should only do something when searching"); the browse list always
  shows the level you are standing on. Widening a subtree search is
  `Catalogue.search_items_in_category/3`'s `:include_descendants`.

  ## Options

    * `:mode` — `:active` (default, excludes deleted items) or `:deleted`
      (only deleted items)
    * `:offset` — default `0`
    * `:limit` — default `50`
    * `:preload` — extra associations appended to the default
      `[:catalogue]`.
    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all.
  """
  @spec list_items_for_category_paged(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_items_for_category_paged(category_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)
    preloads = Helpers.merge_preloads([:catalogue], opts)

    query =
      from(i in Item,
        as: :item,
        where: i.category_uuid == ^category_uuid,
        offset: ^offset,
        limit: ^limit,
        preload: ^preloads
      )

    query
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> apply_item_order(opts)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc """
  Lists a page of a catalogue's items ACROSS all its categories — the
  detail page's Items mode since category drilling was removed (Max,
  2026-08-29): with no level to stand in, the mode lists the whole
  catalogue. Same options as `list_items_for_category_paged/2`, plus
  `:outside_trashed_categories` — `true` skips items inside a trashed
  category, which the Deleted tab counts on that category's card instead.
  The default (position) order is the DOCUMENT order — category position,
  then item position — the same walk the export uses.
  """
  @spec list_catalogue_items_paged(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_catalogue_items_paged(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)
    preloads = Helpers.merge_preloads([:catalogue, category: :catalogue], opts)

    query =
      from(i in Item,
        as: :item,
        left_join: c in Category,
        on: i.category_uuid == c.uuid,
        where: i.catalogue_uuid == ^catalogue_uuid,
        offset: ^offset,
        limit: ^limit,
        preload: ^preloads
      )

    query
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> maybe_outside_trashed_categories(opts)
    |> apply_catalogue_item_order(opts)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc "Total item count for `list_catalogue_items_paged/2`'s filters."
  @spec count_items_for_catalogue(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def count_items_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    from(i in Item, as: :item, where: i.catalogue_uuid == ^catalogue_uuid)
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> maybe_outside_trashed_categories(opts)
    |> repo().aggregate(:count)
  end

  defp maybe_outside_trashed_categories(query, opts) do
    if Keyword.get(opts, :outside_trashed_categories, false),
      do: Trash.outside_trashed_categories(query),
      else: query
  end

  @doc "Per-status item counts for a whole catalogue: `%{\"active\" => n, …}`."
  @spec item_status_counts_for_catalogue(Ecto.UUID.t()) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def item_status_counts_for_catalogue(catalogue_uuid) do
    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid,
      group_by: i.status,
      select: {i.status, count(i.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  # Position on a catalogue-wide list means the DOCUMENT order (category
  # position, then item position) — bare `i.position` interleaves
  # per-category sequences into noise. Every other sort defers to the
  # shared whitelist.
  defp apply_catalogue_item_order(query, opts) do
    case Keyword.get(opts, :sort_by, :position) do
      :position ->
        order_by(query, [i, c],
          asc_nulls_last: c.position,
          asc: i.position,
          asc: i.name,
          asc: i.uuid
        )

      _ ->
        apply_item_order(query, opts)
    end
  end

  # Status filter shared by the item list/count queries. `:status` (an
  # exact status string like `"discontinued"`) takes precedence and filters
  # to that one status — used by the detail page's per-status tabs. Without
  # it, the coarser `:mode` applies: `:deleted` → deleted only, anything
  # else → all non-deleted (used for the category-card "N items" totals).
  defp apply_item_status_filter(query, opts, mode) do
    cond do
      status = Keyword.get(opts, :status) ->
        where(query, [i], i.status == ^status)

      mode == :deleted ->
        where(query, [i], i.status == "deleted")

      true ->
        where(query, [i], i.status != "deleted")
    end
  end

  @doc """
  Lists a page of uncategorized items for a catalogue, in the admin's
  Manual order by default.

  Same shape as `list_items_for_category_paged/2`, but for items where
  `category_uuid IS NULL AND catalogue_uuid = ?`. Used as the final
  section of the infinite-scroll detail view.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
    * `:offset` — default `0`
    * `:limit` — default `50`
    * `:preload` — extra associations appended to the default
      `[:catalogue]`.
    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all.
  """
  @spec list_uncategorized_items_paged(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_uncategorized_items_paged(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)
    preloads = Helpers.merge_preloads([:catalogue], opts)

    query =
      from(i in Item,
        as: :item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid),
        offset: ^offset,
        limit: ^limit,
        preload: ^preloads
      )

    query
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> apply_item_order(opts)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  # ── Item sort + strategy reorder ─────────────────────────────────

  # Sortable item columns. `:position` is the manual-order default
  # (matches the pre-sort behavior); `name` sorts on the raw `name`
  # column (multilang lives in `data` JSONB, not sorted here).
  @item_sort_fields ~w(position name sku base_price inserted_at status)a

  # Applies `:sort_by` / `:sort_dir` from `opts` to an Item query. Every
  # order ends with `asc: i.uuid` so paging is deterministic across ties.
  defp apply_item_order(query, opts) do
    sort_by = Keyword.get(opts, :sort_by, :position)
    sort_dir = if Keyword.get(opts, :sort_dir) == :desc, do: :desc, else: :asc
    item_order_by(query, sort_by, sort_dir)
  end

  defp item_order_by(query, :position, _dir),
    do: order_by(query, [i], asc: i.position, asc: i.name, asc: i.uuid)

  defp item_order_by(query, field, dir) when field in @item_sort_fields,
    do: order_by(query, [i], [{^dir, field(i, ^field)}, {:asc, i.uuid}])

  defp item_order_by(query, _field, _dir),
    do: order_by(query, [i], asc: i.position, asc: i.name, asc: i.uuid)

  @doc """
  Counts the uncategorized items of a catalogue (items with
  `category_uuid IS NULL`). Used to decide whether the infinite-scroll
  detail view needs to show an "Uncategorized" card at all.

  ## Options

    * `:mode` — `:active` (default, all but deleted) or `:deleted`
    * `:status` — only items with this exact status; wins over `:mode`
    * `:value_slugs` — only items carrying all of these attribute value
      slugs (`filter_by_attribute_values/2`); `[]` = all.
    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all.
  """
  @spec uncategorized_count_for_catalogue(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def uncategorized_count_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(i in Item,
        as: :item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid)
      )

    query
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> repo().aggregate(:count)
  end

  @doc """
  Narrows an item query to the items carrying ALL of the given attribute
  VALUE slugs — "the blue doors", and with two slugs "the blue oak doors"
  (Max, 2026-08-28).

  The slugs are what an item's attachment row stores in
  `data["selected_value_slugs"]`, so this reads the selection the item
  form writes. AND semantics: each slug adds its own EXISTS, because
  narrowing is what a filter is for — an OR would widen the list as you
  pick more.

  Pass `value_slugs: [...]` to the paged listings and the counts; an
  empty list is no filter.
  """
  @spec filter_by_attribute_values(Ecto.Query.t(), keyword()) :: Ecto.Query.t()
  def filter_by_attribute_values(query, opts) do
    opts
    |> Keyword.get(:value_slugs, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.reduce(query, fn slug, acc ->
      # `?` is the JSONB "key/element exists" operator; doubled here
      # because Ecto reads a single one as a parameter placeholder.
      from(i in acc,
        where:
          exists(
            from(a in ItemAttributeSet,
              where: a.item_uuid == parent_as(:item).uuid,
              where: fragment("jsonb_typeof(? -> 'selected_value_slugs') = 'array'", a.data),
              where: fragment("? -> 'selected_value_slugs' \\? ?", a.data, ^slug),
              select: 1
            )
          )
      )
    end)
  end

  @doc """
  Narrows an item query (it must carry the `:item` named binding) to the
  items whose EFFECTIVE type is one of `opts[:item_types]` — the item's own
  `item_type`, or its catalogue's when it has none (an item without a
  catalogue counts as goods). The SQL twin of `Item.effective_type/2`.

  Pass `item_types: ["goods"]` (strings or atoms) to the listings, the
  search and the counts; `nil` or `[]` is no filter.
  """
  @spec filter_by_item_types(Ecto.Query.t(), keyword()) :: Ecto.Query.t()
  def filter_by_item_types(query, opts) do
    case opts |> Keyword.get(:item_types) |> List.wrap() |> Enum.map(&to_string/1) do
      [] ->
        query

      types ->
        orphan_goods? = "goods" in types

        catalogue_has_type =
          from(c in Catalogue,
            where: c.uuid == parent_as(:item).catalogue_uuid and c.item_type in ^types,
            select: 1
          )

        where(
          query,
          [item: i],
          i.item_type in ^types or
            (is_nil(i.item_type) and
               (exists(subquery(catalogue_has_type)) or
                  (is_nil(i.catalogue_uuid) and type(^orphan_goods?, :boolean))))
        )
    end
  end

  @doc """
  Counts items in a single category (ignoring its catalogue scope).

  Used by the infinite-scroll detail view to show the total under each
  category header (the number in `"Category Name (N items)"`) without
  loading the items themselves.

  Counts the DIRECT items only, matching `list_items_for_category_paged/2`
  — the number under a header has to be the number of rows the header
  opens onto.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all.
  """
  @spec item_count_for_category(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def item_count_for_category(category_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query = from(i in Item, as: :item, where: i.category_uuid == ^category_uuid)

    query
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> repo().aggregate(:count)
  end

  @doc """
  Returns `%{status => count}` for the items in a single category, across
  every status (`"active"`, `"inactive"`, `"discontinued"`, `"deleted"`).
  One grouped query — drives the detail page's per-status item tabs.
  Missing statuses are simply absent from the map (treat as 0).
  """
  @spec item_status_counts_for_category(Ecto.UUID.t()) :: %{String.t() => non_neg_integer()}
  def item_status_counts_for_category(category_uuid) do
    from(i in Item,
      where: i.category_uuid == ^category_uuid,
      group_by: i.status,
      select: {i.status, count(i.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc """
  `%{status => count}` for a catalogue's uncategorized items (`category_uuid
  IS NULL`), across every status. Per-status sibling of
  `uncategorized_count_for_catalogue/2`.
  """
  @spec item_status_counts_for_uncategorized(Ecto.UUID.t()) :: %{String.t() => non_neg_integer()}
  def item_status_counts_for_uncategorized(catalogue_uuid) do
    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid),
      group_by: i.status,
      select: {i.status, count(i.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Returns a map of `%{category_uuid => item_count}` for every category
  in a catalogue in a single grouped query. Used by the infinite-scroll
  detail view so each category card can show its total count without a
  separate per-card round trip.

  Items without a category (uncategorized) are excluded here — use
  `uncategorized_count_for_catalogue/2` for those.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all.
  """
  @spec item_counts_by_category_for_catalogue(Ecto.UUID.t(), keyword()) :: %{
          Ecto.UUID.t() => non_neg_integer()
        }
  def item_counts_by_category_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(i in Item,
        as: :item,
        where: i.catalogue_uuid == ^catalogue_uuid and not is_nil(i.category_uuid),
        group_by: i.category_uuid,
        select: {i.category_uuid, count(i.uuid)}
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    query
    |> filter_by_item_types(opts)
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Returns the list of ancestor categories from root down to (but not
  including) `category_uuid`. Empty when the category is a root.
  Useful for breadcrumbs.
  """
  @spec list_category_ancestors(Ecto.UUID.t()) :: [Category.t()]
  defdelegate list_category_ancestors(category_uuid), to: Tree, as: :ancestors_in_order

  # ═══════════════════════════════════════════════════════════════════
  # Catalogue folders — see PhoenixKitCatalogue.Catalogue.Folders
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_folder_tree(opts \\ []), to: Folders
  defdelegate folder_uuids_with_children(opts \\ []), to: Folders
  defdelegate catalogues_by_folder(opts \\ []), to: Folders
  defdelegate get_folder(uuid), to: Folders
  defdelegate create_folder(attrs, opts \\ []), to: Folders
  defdelegate update_folder(folder, attrs, opts \\ []), to: Folders
  defdelegate move_folder(folder, new_parent_uuid, opts \\ []), to: Folders
  defdelegate trash_folder(folder, opts \\ []), to: Folders
  defdelegate restore_folder(folder, opts \\ []), to: Folders
  defdelegate delete_empty_folder(folder, opts \\ []), to: Folders
  defdelegate permanently_delete_folder(folder, opts \\ []), to: Folders
  defdelegate reorder_folders(ordered_uuids, opts \\ []), to: Folders
  defdelegate place_level_rows(entries, opts \\ []), to: Folders
  defdelegate move_catalogue_to_folder(catalogue, folder_uuid, opts \\ []), to: Folders

  # ═══════════════════════════════════════════════════════════════════
  # Trash provenance and the per-catalogue lock — see PhoenixKitCatalogue.Catalogue.Trash
  # ═══════════════════════════════════════════════════════════════════

  @doc false
  defdelegate lock_catalogue!(catalogue_uuid), to: Trash

  @doc """
  Returns the next available `position` for a new item within a scope.

  Items are scoped to `(catalogue_uuid, category_uuid)`. Pass
  `category_uuid: nil` for the uncategorized bucket of a catalogue.
  """
  @spec next_item_position(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: integer()
  def next_item_position(catalogue_uuid, category_uuid)
      when is_binary(catalogue_uuid) do
    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid,
        select: max(i.position)
      )

    query =
      case category_uuid do
        nil -> where(query, [i], is_nil(i.category_uuid))
        uuid -> where(query, [i], i.category_uuid == ^uuid)
      end

    case repo().one(query) do
      nil -> 1
      n -> n + 1
    end
  end

  @doc """
  Re-indexes the items inside a `(catalogue_uuid, category_uuid)`
  bucket. Pass `category_uuid: nil` to reorder the uncategorized
  bucket. Behaves like `reorder_categories/4`: validates scope, runs
  two passes inside a transaction, logs an activity row.

  UUIDs that don't belong to the scope abort with
  `{:error, :wrong_scope}` so a stale DOM can't bleed reorder writes
  across catalogues.
  """
  @spec reorder_items(Ecto.UUID.t(), Ecto.UUID.t() | nil, [Ecto.UUID.t()], keyword()) ::
          :ok | {:error, :wrong_scope | :too_many_uuids | term()}
  def reorder_items(catalogue_uuid, category_uuid, ordered_uuids, opts \\ [])
      when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    case validate_and_apply_item_reorder(catalogue_uuid, category_uuid, ordered_uuids) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

        Shared.log_activity(%{
          action: "item.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: List.first(unique_uuids),
          parent_catalogue_uuid: catalogue_uuid,
          metadata: %{
            "category_uuid" => category_uuid,
            "count" => count
          }
        })

        :ok

      {:error, reason} when reason in [:too_many_uuids, :wrong_scope] ->
        Shared.log_reorder_rejected(
          :item,
          reason,
          length(ordered_uuids),
          catalogue_uuid,
          opts
        )

        {:error, reason}

      {:error, reason} ->
        Shared.log_reorder_db_error(
          :item,
          Helpers.dedupe_keep_last(ordered_uuids),
          catalogue_uuid,
          opts,
          category_uuid: category_uuid
        )

        {:error, reason}
    end
  end

  # Validates scope + applies the two-pass write inside its own
  # transaction. Returns `{:ok, count}` on success or `{:error, reason}`
  # without any logging — callers (incl. a future in-transaction caller)
  # handle logging outside the transaction so audit rows survive a
  # rollback.
  defp validate_and_apply_item_reorder(catalogue_uuid, _category_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) and
              length(ordered_uuids) > @reorder_max_uuids,
       do: {:error, :too_many_uuids}

  defp validate_and_apply_item_reorder(catalogue_uuid, category_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

    case item_scope_check(catalogue_uuid, category_uuid, unique_uuids) do
      :empty ->
        {:ok, 0}

      {:ok, valid} ->
        unique_uuids
        |> Enum.filter(&MapSet.member?(valid, &1))
        |> then(&commit_item_positions(catalogue_uuid, &1))

      {:error, _} = err ->
        err
    end
  end

  # The catalogue's trash/restore lock, as `commit_category_positions/2`.
  defp commit_item_positions(catalogue_uuid, unique_uuids) do
    reorder = fn ->
      lock_catalogue!(catalogue_uuid)
      write_item_positions(unique_uuids)
    end

    case repo().transaction(reorder) do
      {:ok, _} -> {:ok, length(unique_uuids)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Deleted items are excluded up front: a uuid captured in a client-side
  # selection (or stale DOM order) that gets trashed in another tab before
  # the reorder lands must not be re-slotted into the active sequence.
  # Mirrors the active-only invariant `scope_items/2` enforces on the
  # `:all` path. Returns the in-scope, non-deleted uuids as a MapSet so the
  # caller can drop them while preserving the requested order.
  defp item_scope_check(catalogue_uuid, category_uuid, unique_uuids) do
    rows =
      from(i in Item, where: i.uuid in ^unique_uuids and i.status != "deleted")
      |> repo().all()

    cond do
      rows == [] ->
        :empty

      not Enum.all?(rows, fn i ->
        i.catalogue_uuid == catalogue_uuid and i.category_uuid == category_uuid
      end) ->
        {:error, :wrong_scope}

      true ->
        {:ok, MapSet.new(rows, & &1.uuid)}
    end
  end

  # Future (perf): collapse the two-pass loop below to a single
  # `UPDATE phoenix_kit_cat_items SET position = v.pos
  #   FROM (VALUES (uuid, pos), …) AS v(uuid, pos)
  #   WHERE phoenix_kit_cat_items.uuid = v.uuid`
  # round-trip per scope. Trigger to revisit: `:reorder_max_uuids`
  # config bumped past 1000, or a unique index on
  # `(catalogue_uuid, category_uuid, position)` is added.
  defp write_item_positions(unique_uuids) do
    # Written (and so locked) in uuid order rather than the caller's.
    pairs = unique_uuids |> Enum.with_index(1) |> Enum.sort_by(fn {uuid, _idx} -> uuid end)

    Enum.each(pairs, fn {uuid, idx} ->
      from(i in Item, where: i.uuid == ^uuid)
      |> repo().update_all(set: [position: -idx])
    end)

    Enum.each(pairs, fn {uuid, idx} ->
      from(i in Item, where: i.uuid == ^uuid)
      |> repo().update_all(set: [position: idx])
    end)

    :ok
  end

  @valid_item_reorder_strategies ~w(name_asc name_desc created_asc created_desc reverse)a

  @doc """
  Bulk-reorders the items in one `(catalogue_uuid, category_uuid)` scope
  by a strategy (mirrors `PhoenixKitProjects.reorder_tasks_by/3`).

  `category_uuid` is normalized via `normalize_category_uuid/1` (`nil` /
  `:uncategorized` → the uncategorized scope). `scope`:

    * `:all` — reindex the whole scope `1..N` in strategy order.
    * a list of item UUIDs — permute those rows in place into their own
      (sorted) position slots. Requires distinct positions; otherwise
      `{:error, :duplicate_positions}` (run an `:all` reorder first to
      normalise — catalogue items default to `position: 0`).

  Strategies: `:name_asc` / `:name_desc` (raw `name` column),
  `:created_asc` / `:created_desc`, `:reverse`.
  """
  @spec reorder_items_by(
          Ecto.UUID.t(),
          Ecto.UUID.t() | :uncategorized | nil,
          atom(),
          :all | [Ecto.UUID.t()],
          keyword()
        ) ::
          :ok
          | {:error,
             :invalid_strategy
             | :duplicate_positions
             | :uuids_outside_scope
             | :too_many_uuids
             | term()}
  def reorder_items_by(catalogue_uuid, category_uuid, strategy, scope, opts \\ [])

  def reorder_items_by(_catalogue_uuid, _category_uuid, strategy, _scope, _opts)
      when strategy not in @valid_item_reorder_strategies,
      do: {:error, :invalid_strategy}

  def reorder_items_by(catalogue_uuid, category_uuid, strategy, :all, opts)
      when is_binary(catalogue_uuid) do
    cat_uuid = normalize_category_uuid(category_uuid)
    ordered = catalogue_uuid |> scope_items(cat_uuid) |> item_strategy_order(strategy)

    cond do
      ordered == [] ->
        :ok

      length(ordered) > @reorder_max_uuids ->
        {:error, :too_many_uuids}

      true ->
        finish_item_reorder_by(
          repo().transaction(fn ->
            lock_catalogue!(catalogue_uuid)
            write_item_positions(ordered)
          end),
          catalogue_uuid,
          cat_uuid,
          strategy,
          :all,
          ordered,
          opts
        )
    end
  end

  def reorder_items_by(catalogue_uuid, category_uuid, strategy, uuids, opts)
      when is_binary(catalogue_uuid) and is_list(uuids) do
    cat_uuid = normalize_category_uuid(category_uuid)
    unique = Helpers.dedupe_keep_last(uuids)

    if length(unique) > @reorder_max_uuids do
      {:error, :too_many_uuids}
    else
      case item_scope_check(catalogue_uuid, cat_uuid, unique) do
        :empty ->
          :ok

        {:error, :wrong_scope} ->
          {:error, :uuids_outside_scope}

        {:ok, valid} ->
          kept = Enum.filter(unique, &MapSet.member?(valid, &1))
          permute_items_by(catalogue_uuid, cat_uuid, kept, strategy, opts)
      end
    end
  end

  # Permute the selected rows into their own (sorted) position slots.
  defp permute_items_by(catalogue_uuid, cat_uuid, unique, strategy, opts) do
    rows = from(i in Item, where: i.uuid in ^unique) |> repo().all()
    slots = rows |> Enum.map(& &1.position) |> Enum.sort()

    if slots != Enum.uniq(slots) do
      {:error, :duplicate_positions}
    else
      pairs = Enum.zip(item_strategy_order(rows, strategy), slots)

      finish_item_reorder_by(
        repo().transaction(fn ->
          lock_catalogue!(catalogue_uuid)
          write_item_permutation(pairs)
        end),
        catalogue_uuid,
        cat_uuid,
        strategy,
        :selected,
        Enum.map(pairs, fn {uuid, _} -> uuid end),
        opts
      )
    end
  end

  defp finish_item_reorder_by({:ok, _}, catalogue_uuid, cat_uuid, strategy, mode, ordered, opts) do
    Shared.log_activity(%{
      action: "item.reordered",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "item",
      resource_uuid: List.first(ordered),
      parent_catalogue_uuid: catalogue_uuid,
      metadata: %{
        "category_uuid" => cat_uuid,
        "strategy" => Atom.to_string(strategy),
        "scope" => Atom.to_string(mode),
        "count" => length(ordered)
      }
    })

    :ok
  end

  defp finish_item_reorder_by(
         {:error, reason},
         catalogue_uuid,
         cat_uuid,
         _strategy,
         _mode,
         ordered,
         opts
       ) do
    Shared.log_reorder_db_error(:item, ordered, catalogue_uuid, opts, category_uuid: cat_uuid)
    {:error, reason}
  end

  defp scope_items(catalogue_uuid, nil) do
    from(i in Item,
      where:
        i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid) and i.status != "deleted"
    )
    |> repo().all()
  end

  defp scope_items(catalogue_uuid, category_uuid) do
    from(i in Item,
      where:
        i.catalogue_uuid == ^catalogue_uuid and i.category_uuid == ^category_uuid and
          i.status != "deleted"
    )
    |> repo().all()
  end

  # Writes arbitrary {uuid, position} pairs two-phase (negatives, then the
  # final positives) to dodge transient unique collisions; uuid-sorted
  # write order is deadlock-safe.
  defp write_item_permutation(pairs) do
    write_order = Enum.sort_by(pairs, fn {uuid, _pos} -> uuid end)

    write_order
    |> Enum.with_index(1)
    |> Enum.each(fn {{uuid, _pos}, idx} ->
      from(i in Item, where: i.uuid == ^uuid) |> repo().update_all(set: [position: -idx])
    end)

    Enum.each(write_order, fn {uuid, pos} ->
      from(i in Item, where: i.uuid == ^uuid) |> repo().update_all(set: [position: pos])
    end)

    :ok
  end

  # Maps rows → uuids in the order a strategy implies. uuid pre-sort is a
  # stable tiebreaker for equal names / same-second inserts.
  defp item_strategy_order(rows, :reverse),
    do: rows |> Enum.sort_by(& &1.position) |> Enum.reverse() |> Enum.map(& &1.uuid)

  defp item_strategy_order(rows, :name_asc),
    do:
      rows
      |> Enum.sort_by(& &1.uuid)
      |> Enum.sort_by(&downcase_or_empty(&1.name))
      |> Enum.map(& &1.uuid)

  defp item_strategy_order(rows, :name_desc),
    do:
      rows
      |> Enum.sort_by(& &1.uuid, :desc)
      |> Enum.sort_by(&downcase_or_empty(&1.name), :desc)
      |> Enum.map(& &1.uuid)

  # The DateTime sorter, not term order — structurally, DateTime structs
  # compare field-alphabetically (day before month), so a bare
  # `& &1.inserted_at` key put Jan 2nd AFTER Feb 1st. The category-side
  # strategies (`order_categories_for_strategy/2`) already sort this way.
  defp item_strategy_order(rows, :created_asc),
    do:
      rows
      |> Enum.sort_by(& &1.uuid)
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})
      |> Enum.map(& &1.uuid)

  defp item_strategy_order(rows, :created_desc),
    do:
      rows
      |> Enum.sort_by(& &1.uuid, :desc)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.map(& &1.uuid)

  defp downcase_or_empty(nil), do: ""
  defp downcase_or_empty(s) when is_binary(s), do: String.downcase(s)

  @doc """
  Normalizes a node reference to an item `category_uuid`: `nil` /
  `:uncategorized` / `"uncategorized"` → `nil` (the uncategorized scope);
  `%Category{}` → its uuid; a uuid string passes through. Shared by the
  detail LV and `reorder_items_by/5` so the uncategorized bucket always
  reaches scope checks as `category_uuid: nil`.
  """
  @spec normalize_category_uuid(nil | :uncategorized | String.t() | Category.t()) ::
          Ecto.UUID.t() | nil
  def normalize_category_uuid(nil), do: nil
  def normalize_category_uuid(:uncategorized), do: nil
  def normalize_category_uuid("uncategorized"), do: nil
  def normalize_category_uuid(%Category{uuid: uuid}), do: uuid
  def normalize_category_uuid(uuid) when is_binary(uuid), do: uuid

  # ═══════════════════════════════════════════════════════════════════
  # Items
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists all non-deleted items across all catalogues in the admin's
  Manual document order — catalogue (position, name), category
  position, then item position and name — the same chain
  `search_items/2` defaults to.

  ALL of them: the catalogue join is a LEFT join, so an item whose
  catalogue row is gone still lists (last). `catalogue_uuid` is
  nullable and its FK is `ON DELETE SET NULL`, so hard-deleting a
  catalogue (`delete_catalogue/2`) orphans its items rather than
  removing them — and this function is what the Translations page
  enumerates items with, where a silently missing row reads as
  "already translated".

  Preloads category (with catalogue) and manufacturer.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
      When nil (default), returns all non-deleted items.
    * `:limit` — max results to return (default: no limit)
    * `:item_types` — only items of these EFFECTIVE types, e.g.
      `["goods"]` (`filter_by_item_types/2`); `nil`/`[]` = all.

  ## Examples

      Catalogue.list_items()                          # all non-deleted
      Catalogue.list_items(status: "active")          # only active
      Catalogue.list_items(limit: 100)                # first 100
  """
  @spec list_items(keyword()) :: [Item.t()]
  def list_items(opts \\ []) do
    query =
      from(i in Item,
        as: :item,
        left_join: cat in Catalogue,
        on: i.catalogue_uuid == cat.uuid,
        left_join: c in Category,
        on: i.category_uuid == c.uuid,
        order_by: [
          asc_nulls_last: cat.position,
          asc: fragment("lower(?)", cat.name),
          asc: cat.uuid,
          asc_nulls_last: c.position,
          asc: i.position,
          asc: i.name,
          asc: i.uuid
        ],
        preload: [:catalogue, category: :catalogue]
      )

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [i], i.status != "deleted")
        status -> where(query, [i], i.status == ^status)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> limit(query, ^limit)
      end

    query |> filter_by_item_types(opts) |> repo().all() |> Manufacturers.hydrate()
  end

  @doc """
  Lists non-deleted items for a category, ordered by position then name.

  Default preloads `[:catalogue, category: :catalogue]`.
  Pass `:preload` in `opts` to add more (e.g.
  `preload: [catalogue_rules: :referenced_catalogue]` for smart-pricing
  consumers); the lists are concatenated, not replaced.

  ## Options

    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all. Same option as
      `list_items_for_category_paged/2`.
  """
  @spec list_items_for_category(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_items_for_category(category_uuid, opts \\ []) do
    from(i in Item,
      as: :item,
      where: i.category_uuid == ^category_uuid and i.status != "deleted",
      order_by: [asc: i.position, asc: i.name],
      preload: ^Helpers.merge_preloads([:catalogue, category: :catalogue], opts)
    )
    |> filter_by_item_types(opts)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc """
  Lists non-deleted items for a catalogue, ordered by category position,
  then item position, name and uuid. Includes uncategorized items (those
  with no category) at the end.

  Byte-for-byte the tail of `search_items/2`'s `:position` chain (the
  leading catalogue keys are constant here), uuid tie-break included —
  the unpaged read and the paged one must not disagree on two items
  that tie on every visible key.

  Default preloads `[:catalogue, category: :catalogue]`.
  Pass `:preload` in `opts` to add more — see `list_items_for_category/2`.

  ## Options

    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all. Same option as
      `list_catalogue_items_paged/2`.
  """
  @spec list_items_for_catalogue(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_items_for_catalogue(catalogue_uuid, opts \\ []) do
    from(i in Item,
      as: :item,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status != "deleted",
      order_by: [asc_nulls_last: c.position, asc: i.position, asc: i.name, asc: i.uuid],
      preload: ^Helpers.merge_preloads([:catalogue, category: :catalogue], opts)
    )
    |> filter_by_item_types(opts)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc """
  Lists soft-deleted items in a catalogue as a flat list, ordered by
  deletion date (most-recently-deleted first). `updated_at` is the
  deletion-time proxy — flipping `status` to `"deleted"` always bumps
  it. Used by the Items tab Deleted view, which surfaces a recency-
  ordered audit list rather than category-grouped cards.

  ## Options

    * `:limit` — caps the list (default 500). Pagination isn't wired
      yet; if a catalogue routinely exceeds the limit, layer a cursor
      on top of this query.
    * `:preload` — extra associations on top of the default
      `[:catalogue, category: :catalogue]`.

  ## Examples

      Catalogue.list_deleted_items_for_catalogue(catalogue_uuid)
  """
  @spec list_deleted_items_for_catalogue(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_deleted_items_for_catalogue(catalogue_uuid, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status == "deleted",
      order_by: [desc: i.updated_at, asc: i.uuid],
      limit: ^limit,
      preload: ^Helpers.merge_preloads([:catalogue, category: :catalogue], opts)
    )
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc """
  Lists uncategorized items (no category assigned) for a specific catalogue.

  ## Options

    * `:mode` — `:active` (default) excludes deleted items;
      `:deleted` returns only deleted items.
    * `:preload` — extra associations appended to the default
      `[:catalogue]` preloads. Pass
      `[catalogue_rules: :referenced_catalogue]` for smart-pricing.

  ## Examples

      Catalogue.list_uncategorized_items(catalogue_uuid)
      Catalogue.list_uncategorized_items(catalogue_uuid, mode: :deleted)
  """
  @spec list_uncategorized_items(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_uncategorized_items(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    preloads = Helpers.merge_preloads([:catalogue], opts)

    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid),
        order_by: [asc: i.position, asc: i.name],
        preload: ^preloads
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().all(query)
  end

  @doc """
  Fetches an item by UUID. Returns `nil` if not found.

  ## Options

    * `:preload` — list of associations to preload. Default `[]`.
      Common smart-pricing preload: `[catalogue_rules: :referenced_catalogue]`.

  ## Examples

      Catalogue.get_item(uuid)
      Catalogue.get_item(uuid, preload: [:catalogue, catalogue_rules: :referenced_catalogue])
  """
  @spec get_item(Ecto.UUID.t(), keyword()) :: Item.t() | nil
  def get_item(uuid, opts \\ []) do
    case Helpers.get_by_uuid(Item, uuid) do
      nil -> nil
      item -> repo().preload(item, Keyword.get(opts, :preload, []))
    end
  end

  @doc """
  Fetches an item by UUID with preloaded `:catalogue`, `:category`,
  and `:manufacturer`. Raises `Ecto.NoResultsError` if not found.

  Pass `:preload` to add more associations (concatenated with the
  defaults).
  """
  @spec get_item!(Ecto.UUID.t(), keyword()) :: Item.t()
  def get_item!(uuid, opts \\ []) do
    Item
    |> Helpers.get_by_uuid!(uuid)
    |> repo().preload(Helpers.merge_preloads([:catalogue, :category], opts))
    |> Manufacturers.hydrate()
  end

  @doc """
  Fetches an item by its per-language `slug`.

  Tries an exact match in `lang`'s base language first (`"en-US"` folds
  to `"en"`), falling back to any language when `opts[:any_lang]` is
  `true`. The result is `{:error, :not_found}` on a miss; a hit is a
  2-tuple by default, or — whenever `opts[:any_lang]` is `true`, even
  when the base language itself matched — a 3-tuple carrying the
  language the slug actually matched in, so a caller that opted into
  the fallback can always destructure the same shape. Any other option
  (e.g. `:preload`) is forwarded to `get_item/2`.
  """
  @spec get_item_by_slug(String.t(), String.t(), keyword()) ::
          {:ok, Item.t()} | {:ok, Item.t(), String.t()} | {:error, :not_found}
  def get_item_by_slug(slug, lang, opts \\ []) do
    Shared.find_by_slug(@item_slugs_table, "item_uuid", slug, lang, opts, &get_item/2)
  end

  @doc """
  Whether `slug` is already projected for `lang`'s base language by an
  item other than `opts[:exclude_uuid]`. Trashed items count: their slugs
  stay in the projection so a restore cannot collide, which is also why
  a generated slug must probe here rather than through `get_item_by_slug/3`.
  The probe `Catalogue.Slugs.unique/3` runs before a generated slug is
  written (the item form, the AI translation adapter).
  """
  @spec item_slug_taken?(String.t(), String.t(), keyword()) :: boolean()
  def item_slug_taken?(slug, lang, opts \\ []) do
    Shared.slug_taken?(@item_slugs_table, "item_uuid", slug, lang, opts[:exclude_uuid])
  end

  @doc """
  Bulk-fetches items by a list of UUIDs. Excludes soft-deleted items.
  Result order matches the input UUID order; missing UUIDs are dropped
  (no `nil` placeholders, no error). Duplicate input UUIDs collapse to
  a single result.

  Designed for snapshot rehydration — e.g. an order stored as a list of
  item UUIDs that needs full item data on reload. Avoids the N+1 trap
  of looping `get_item/1` per UUID.

  ## Options

    * `:preload` — extra associations appended to the default
      `[:catalogue, :category]`. Pass
      `[catalogue_rules: :referenced_catalogue]` for smart-pricing.

  ## Examples

      Catalogue.list_items_by_uuids([uuid1, uuid2, uuid3])
      Catalogue.list_items_by_uuids(uuids, preload: [catalogue_rules: :referenced_catalogue])
  """
  @spec list_items_by_uuids([Ecto.UUID.t()], keyword()) :: [Item.t()]
  def list_items_by_uuids(uuids, opts \\ [])

  def list_items_by_uuids([], _opts), do: []

  def list_items_by_uuids(uuids, opts) when is_list(uuids) do
    preloads = Helpers.merge_preloads([:catalogue, :category], opts)

    items_by_uuid =
      from(i in Item,
        where: i.uuid in ^uuids and i.status != "deleted",
        preload: ^preloads
      )
      |> repo().all()
      |> Map.new(&{&1.uuid, &1})

    uuids
    |> Enum.uniq()
    |> Enum.flat_map(fn uuid ->
      case Map.get(items_by_uuid, uuid) do
        nil -> []
        item -> [item]
      end
    end)
  end

  @doc """
  Creates an item.

  ## Required attributes

    * `:name` — item name (1-255 chars)
    * `:catalogue_uuid` — the parent catalogue (required). Auto-derived from
      `:category_uuid` when omitted and a category is provided.

  ## Optional attributes

    * `:description` — text description
    * `:sku` — stock keeping unit (max 100 chars; not unique — the same
      SKU may appear on multiple items)
    * `:base_price` — decimal, must be >= 0 (cost/purchase price before markup)
    * `:unit` — one of `Item.allowed_units/0` (default `"piece"`)
    * `:item_type` — `"goods"` or `"service"`; omit (or pass nil) to inherit
      the catalogue's type. Read it back with `Item.effective_type/2`
    * `:status` — `"active"` (default), `"inactive"`, `"discontinued"`, or `"deleted"`
    * `:category_uuid` — the parent category (optional — leave nil for uncategorized items)
    * `:manufacturer_uuid` — the manufacturer (optional)
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_item(%{name: "Oak Panel 18mm", catalogue_uuid: cat.uuid, base_price: 25.50})
      Catalogue.create_item(%{name: "Hinge", category_uuid: category.uuid, manufacturer_uuid: m.uuid})
  """
  @spec create_item(map(), keyword()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t(Item.t())}
  def create_item(attrs, opts \\ []) do
    skip_derive? = Keyword.get(opts, :skip_derive, false)
    attrs = maybe_put_item_position(attrs)

    # We run derivation + insert in the same transaction so that the
    # `FOR SHARE` row lock inside `put_catalogue_from_effective_category`
    # is held until the INSERT commits. That closes the race with a
    # concurrent `move_category_to_catalogue/3` (which takes `FOR UPDATE`
    # on the same row): while the move holds the exclusive lock, our
    # derive waits; once we hold the shared lock, the move waits — so an
    # item can never be inserted with a stale `catalogue_uuid` mid-move.
    result =
      repo().transaction(fn ->
        {attrs, category} =
          if skip_derive?, do: {attrs, nil}, else: derive_catalogue_uuid(nil, attrs)

        case %Item{}
             |> Item.changeset(attrs)
             |> check_item_category(category)
             |> Shared.stamp_created_deleted()
             |> repo().insert() do
          {:ok, item} -> item
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, item} ->
        Shared.log_activity(
          %{
            action: "item.created",
            mode: opts[:mode] || "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            resource_uuid: item.uuid,
            parent_catalogue_uuid: item.catalogue_uuid,
            metadata: %{"name" => item.name, "sku" => item.sku || ""}
          },
          opts
        )

        {:ok, item}

      {:error, _changeset} = error ->
        error
    end
  end

  # Keeps `catalogue_uuid` in lockstep with `category_uuid`. The
  # category is the single source of truth: an item in a category must
  # live in that category's catalogue. We compute the *effective*
  # resulting `category_uuid` (new value if attrs mentions it, otherwise
  # the item's current value) and, whenever that yields a category, we
  # set `catalogue_uuid` to that category's `catalogue_uuid` — overriding
  # any stale value the caller might have passed. This prevents silent
  # inconsistencies where an item ends up with a category in catalogue A
  # but `catalogue_uuid` pointing at catalogue B.
  #
  # Also normalizes an empty-string `category_uuid` from form params
  # into `nil` so the changeset treats it as "clear category" rather
  # than attempting a malformed DB lookup.
  #
  # Accepts both atom- and string-keyed maps, and a `nil` item for the
  # create path.
  # Returns `{attrs, category}`: the category it read FOR SHARE (or nil) goes
  # on to `check_item_category/2`, which would otherwise read it again.
  defp derive_catalogue_uuid(item, attrs) when is_map(attrs) do
    attrs
    |> normalize_blank_category()
    |> put_catalogue_from_effective_category(effective_category_uuid(item, attrs))
  end

  # Returns the category_uuid the item will have *after* this
  # create/update: the incoming one from attrs if provided (nil if it's
  # an empty string), otherwise the item's current value (nil on create).
  defp effective_category_uuid(item, attrs) do
    if Helpers.has_attr?(attrs, :category_uuid) do
      attrs |> Helpers.fetch_attr(:category_uuid) |> Values.blank_to_nil()
    else
      item && Map.get(item, :category_uuid)
    end
  end

  # An empty-string `category_uuid` arrives from form params; normalize it
  # to `nil` so the changeset treats it as "clear category" instead of
  # tripping a malformed FK lookup.
  defp normalize_blank_category(attrs) do
    if Helpers.has_attr?(attrs, :category_uuid) and
         Helpers.fetch_attr(attrs, :category_uuid) == "" do
      Helpers.put_attr(attrs, :category_uuid, nil)
    else
      attrs
    end
  end

  # The category an item is written into must be live while the item is,
  # and must belong to the item's catalogue. One FOR SHARE read, which also
  # waits out a `trash_category/2` or `move_category_to_catalogue/3` holding
  # the row. A form or tab still offering a trashed category gets a
  # changeset error instead of an item hidden from the tree; an importer
  # writing with `skip_derive: true` whose category moved to another
  # catalogue mid-import gets one instead of an item in a catalogue its
  # category is not in.
  defp check_item_category(%Ecto.Changeset{} = changeset, known) do
    with category_uuid when is_binary(category_uuid) <- category_to_check(changeset),
         {category_status, category_catalogue_uuid} <- category_facts(category_uuid, known) do
      live? = Ecto.Changeset.get_field(changeset, :status) != "deleted"

      cond do
        live? and category_status == "deleted" ->
          Ecto.Changeset.add_error(changeset, :category_uuid, "is invalid")

        Ecto.Changeset.get_field(changeset, :catalogue_uuid) != category_catalogue_uuid ->
          Ecto.Changeset.add_error(changeset, :category_uuid, "belongs to another catalogue")

        true ->
          changeset
      end
    else
      _ -> changeset
    end
  end

  # The category to check: a changed one, or the unchanged one when the
  # item's catalogue changes under it (an importer passing `skip_derive: true`
  # with a new `catalogue_uuid`). Either can leave an item in a category of
  # another catalogue.
  defp category_to_check(changeset) do
    case Ecto.Changeset.fetch_change(changeset, :category_uuid) do
      {:ok, category_uuid} ->
        category_uuid

      :error ->
        if Ecto.Changeset.changed?(changeset, :catalogue_uuid),
          do: Ecto.Changeset.get_field(changeset, :category_uuid)
    end
  end

  # The derive step already read this category FOR SHARE in the same
  # transaction; reading it again cost a query per item write, which imports
  # multiply.
  # A `do` block, not `, do:` — the formatter's indent for a wrapped
  # `, do:` continuation moved between Elixir 1.18 and 1.19, so the
  # one-liner flip-flops with whichever version last ran `mix format`.
  defp category_facts(uuid, %Category{uuid: uuid} = known) do
    {known.status, known.catalogue_uuid}
  end

  defp category_facts(uuid, _known) do
    repo().one(
      from(c in Category,
        where: c.uuid == ^uuid,
        lock: "FOR SHARE",
        select: {c.status, c.catalogue_uuid}
      )
    )
  end

  # If the effective category exists, pin `catalogue_uuid` to that
  # category's catalogue — this is the single source of truth and
  # overrides any stale value the caller might have passed. If no
  # category exists in the resulting state, leave `catalogue_uuid`
  # alone; `validate_required` enforces it ends up set.
  #
  # The `FOR SHARE` row lock closes the move_category race: see the
  # comment in `create_item/2`. Must be invoked inside a transaction
  # for the lock to persist until the insert/update commits.
  defp put_catalogue_from_effective_category(attrs, nil), do: {attrs, nil}

  defp put_catalogue_from_effective_category(attrs, category_uuid)
       when is_binary(category_uuid) do
    query = from(c in Category, where: c.uuid == ^category_uuid, lock: "FOR SHARE")

    case repo().one(query) do
      %Category{catalogue_uuid: cat_uuid} = category ->
        {Helpers.put_attr(attrs, :catalogue_uuid, cat_uuid), category}

      nil ->
        # Target category doesn't exist — leave attrs as-is so the
        # changeset's FK constraint surfaces a clear error.
        {attrs, nil}
    end
  end

  @doc """
  Updates an item with the given attributes.

  ## `:data_owned_keys`

  A caller (typically a form) that only rendered/edited PART of `data`
  can pass `:data_owned_keys` — a list of `data`'s top-level keys it
  actually owns. When set, this function re-reads the row `FOR UPDATE`
  inside its transaction and, for each owned key, takes that key's
  value from `attrs["data"]` (falling back to the fresh row's own value
  when the key is absent from `attrs["data"]` — an owned key is never
  written as a deletion by mere absence). Every key NOT listed keeps the
  freshest DB value untouched, no matter what stale copy `attrs["data"]`
  happens to carry for it — the whole point: a form built from a
  page-load snapshot can no longer clobber a key some other process
  wrote after that snapshot was taken (translation fingerprints, a sync,
  …).

  Omit the option (or pass `nil`) for the previous behavior: `data` is
  replaced wholesale by whatever `attrs["data"]` contains, same as a
  plain `Ecto.Changeset.cast/4` on a `:map` field.
  """
  @spec update_item(Item.t(), map(), keyword()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t(Item.t())}
  def update_item(%Item{} = item, attrs, opts \\ []) do
    skip_derive? = Keyword.get(opts, :skip_derive, false)

    result =
      repo().transaction(fn ->
        # The category (FOR SHARE, in the derive) before the item row (FOR
        # UPDATE, in the data narrowing): the order a category trash takes
        # them, so a form save and a trash cannot deadlock.
        {attrs, category} =
          if skip_derive?, do: {attrs, nil}, else: derive_catalogue_uuid(item, attrs)

        attrs = Shared.narrow_data_ownership(Item, item.uuid, attrs, opts)

        case item
             |> Item.changeset(attrs)
             |> Shared.keep_trash_status(Item, item.uuid)
             |> check_item_category(category)
             |> repo().update() do
          {:ok, updated} -> updated
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, updated} ->
        Shared.log_activity(
          %{
            action: "item.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            resource_uuid: updated.uuid,
            parent_catalogue_uuid: updated.catalogue_uuid,
            metadata:
              ActivityLog.with_changes(
                %{"name" => updated.name, "sku" => updated.sku || ""},
                item,
                updated,
                @item_logged_fields
              )
          },
          opts
        )

        MediaFolders.follow([{item, updated}], opts[:actor_uuid])
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc "Hard-deletes an item. Prefer `trash_item/1` for soft-delete."
  @spec delete_item(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, term()}
  def delete_item(%Item{} = item, opts \\ []) do
    release = MediaFolders.release_plan([from(i in Item, where: i.uuid == ^item.uuid)])

    case repo().delete(item) do
      {:ok, _} = ok ->
        MediaFolders.release(release)

        Shared.log_activity(%{
          action: "item.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: item.uuid,
          parent_catalogue_uuid: item.catalogue_uuid,
          metadata: %{"name" => item.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes an item by setting its status to `"deleted"`, stamped as
  trashed on its own — restoring its catalogue or category later leaves
  it in the trash. Returns `{:error, :not_found}` when the row is gone. An
  item already in the trash is returned unchanged.

  ## Examples

      {:ok, item} = Catalogue.trash_item(item)
  """
  @spec trash_item(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, :not_found | term()}
  def trash_item(%Item{} = item, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        _locked = Trash.lock_row_in_catalogue!(Item, item.uuid)

        {trashed_now, _} =
          from(i in Item, where: i.uuid == ^item.uuid and i.status != "deleted")
          |> Trash.stamp_trashed_self(DateTime.utc_now())
          |> repo().update_all([])

        {repo().get!(Item, item.uuid), trashed_now}
      end)

    # An item already in the trash was not trashed by this call.
    with {:ok, {trashed, trashed_now}} <- result do
      if trashed_now > 0 do
        Shared.log_activity(%{
          action: "item.trashed",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: trashed.uuid,
          parent_catalogue_uuid: trashed.catalogue_uuid,
          metadata: %{"name" => trashed.name}
        })
      end

      {:ok, trashed}
    end
  end

  @doc """
  Restores a soft-deleted item to the status it had before it was
  trashed (`inactive` and `discontinued` survive the round trip).

  Refuses with `{:error, :parent_catalogue_deleted}` when the item's
  catalogue is deleted — restore the catalogue first. (An item cannot
  exist outside a catalogue.)

  When the catalogue is live but the item's category is still in the
  trash, the item is **uncategorized on restore**: `category_uuid` is set
  to `nil` so it resurfaces in the catalogue's Uncategorized bucket,
  instead of reviving the category behind the operator's back. To get the
  item back in place, restore the category instead — `restore_category/2`
  brings back the items its own trash took.

  An item that is not deleted is returned unchanged.

  ## Examples

      {:ok, item} = Catalogue.restore_item(item)
      {:error, :parent_catalogue_deleted} =
        Catalogue.restore_item(item_under_deleted_catalogue)
  """
  @spec restore_item(Item.t(), keyword()) ::
          {:ok, Item.t()} | {:error, :parent_catalogue_deleted | :not_found | term()}
  def restore_item(%Item{} = item, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        fresh = Trash.lock_row_in_catalogue!(Item, item.uuid)

        if Shared.catalogue_deleted?(fresh.catalogue_uuid),
          do: repo().rollback(:parent_catalogue_deleted)

        if fresh.status == "deleted",
          do: {:restored, do_restore_item(fresh), fresh},
          else: {:unchanged, {fresh, false}}
      end)

    case result do
      {:ok, {:restored, {restored, detached?}, fresh}} ->
        if detached?, do: MediaFolders.follow([{fresh, restored}], opts[:actor_uuid])

        Shared.log_activity(%{
          action: "item.restored",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: restored.uuid,
          parent_catalogue_uuid: restored.catalogue_uuid,
          metadata:
            %{"name" => restored.name}
            |> Map.merge(if detached?, do: %{"detached_from_category" => true}, else: %{})
        })

        {:ok, restored}

      {:ok, {:unchanged, {fresh, _}}} ->
        {:ok, fresh}

      error ->
        error
    end
  end

  defp do_restore_item(%Item{} = item) do
    detached? = category_deleted?(item.category_uuid)

    query =
      from(i in Item, where: i.uuid == ^item.uuid)
      |> Trash.restore_trashed(:item, DateTime.utc_now())

    query = if detached?, do: update(query, set: [category_uuid: nil]), else: query
    repo().update_all(query, [])

    {repo().get!(Item, item.uuid), detached?}
  end

  defp category_deleted?(nil), do: false

  defp category_deleted?(category_uuid) do
    repo().one(
      from(c in Category, where: c.uuid == ^category_uuid, lock: "FOR SHARE", select: c.status)
    ) == "deleted"
  end

  @doc """
  Permanently deletes an item from the database. This cannot be undone.

  ## Examples

      {:ok, _} = Catalogue.permanently_delete_item(item)
  """
  @spec permanently_delete_item(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, term()}
  def permanently_delete_item(%Item{} = item, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        locked = Trash.lock_row_in_catalogue!(Item, item.uuid)

        # `only_trashed: true` (a Deleted-tab action) refuses an item that was
        # restored in another tab since the page showed it.
        if opts[:only_trashed] == true and locked.status != "deleted",
          do: repo().rollback(:not_in_trash)

        release = MediaFolders.release_plan([from(i in Item, where: i.uuid == ^item.uuid)])
        from(i in Item, where: i.uuid == ^item.uuid) |> repo().delete_all()
        release
      end)

    with {:ok, release} <- result do
      MediaFolders.release(release)

      Shared.log_activity(%{
        action: "item.permanently_deleted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        resource_uuid: item.uuid,
        parent_catalogue_uuid: item.catalogue_uuid,
        metadata: %{"name" => item.name}
      })

      {:ok, item}
    end
  end

  @doc """
  Bulk soft-deletes all non-deleted items in a category.

  Returns `{count, nil}` where count is the number of items affected.

  ## Examples

      {3, nil} = Catalogue.trash_items_in_category(category_uuid)
  """
  @spec trash_items_in_category(Ecto.UUID.t(), keyword()) :: {non_neg_integer(), nil}
  def trash_items_in_category(category_uuid, opts \\ []) do
    parent_catalogue_uuid = Shared.lookup_parent(:category, category_uuid)

    trash = fn ->
      lock_catalogue!(parent_catalogue_uuid)

      if Shared.lookup_parent(:category, category_uuid) != parent_catalogue_uuid,
        do: repo().rollback(:catalogue_moved)

      {count, _} =
        from(i in Item,
          where: i.category_uuid == ^category_uuid and i.status != "deleted"
        )
        |> Trash.stamp_trashed_self(DateTime.utc_now())
        |> repo().update_all([])

      count
    end

    count =
      case Trash.locked_transaction(trash) do
        {:ok, count} -> count
        {:error, _} -> 0
      end

    if count > 0 do
      Shared.log_activity(
        %{
          action: "item.bulk_trashed",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          parent_catalogue_uuid: parent_catalogue_uuid,
          metadata: %{"category_uuid" => category_uuid, "count" => count}
        },
        opts
      )
    end

    {count, nil}
  end

  # ── Batch fan-out for uuid-list bulk ops ──────────────────────

  # A uuid list from the admin toolbar normally comes from one catalogue,
  # but nothing in the API forbids a mixed list — so the batch event goes
  # out once per touched catalogue (the `nil` uuid marks it as a batch;
  # see `broadcast_for/2`). The bulk paths get that list from
  # `lock_catalogues_of!/2`, read BEFORE the write for trash / delete: the
  # rows may no longer exist afterwards.

  defp broadcast_item_batch(catalogue_uuids, opts) do
    if Keyword.get(opts, :broadcast, true) do
      Enum.each(catalogue_uuids, &PubSub.broadcast(:item, nil, &1))
    end

    :ok
  end

  # ── Bulk actions on UUID lists (admin selection toolbar) ──────

  defp bulk_result({:ok, {count, catalogue_uuids}}), do: {count, catalogue_uuids}

  defp bulk_result({:error, reason}) do
    Logger.warning("Catalogue bulk item operation rolled back: #{inspect(reason)}")
    {0, []}
  end

  # `only_trashed: true` (a Deleted-tab action) leaves live items alone, so a
  # row restored in another tab since the page showed it is not destroyed.
  defp only_trashed_items(query, opts) do
    if opts[:only_trashed] == true,
      do: where(query, [i], i.status == "deleted"),
      else: query
  end

  @doc """
  Bulk soft-deletes items by UUID. Empty list is a no-op. Logs a single
  `item.bulk_trashed` activity row when count > 0.
  """
  @spec bulk_trash_items([Ecto.UUID.t()], keyword()) :: {non_neg_integer(), nil}
  def bulk_trash_items([], _opts), do: {0, nil}

  def bulk_trash_items(uuids, opts) when is_list(uuids) do
    uuids = scope_item_uuids(uuids, opts[:catalogue_uuid])

    {count, catalogue_uuids} =
      Trash.locked_transaction(fn ->
        catalogue_uuids = Trash.lock_catalogues_of!(Item, uuids)

        {count, _} =
          from(i in Item, where: i.uuid in ^uuids and i.status != "deleted")
          |> Trash.stamp_trashed_self(DateTime.utc_now())
          |> repo().update_all([])

        {count, catalogue_uuids}
      end)
      |> bulk_result()

    if count > 0 do
      Shared.log_activity(
        %{
          action: "item.bulk_trashed",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          metadata: %{"count" => count, "uuids" => uuids}
        },
        broadcast: false
      )

      broadcast_item_batch(catalogue_uuids, opts)
    end

    {count, nil}
  end

  @doc """
  Bulk restores items by UUID. Skips items whose parent catalogue is
  deleted (returns only the count of items actually flipped to active).
  Items with deleted parent categories are uncategorized on restore —
  same rule as `restore_item/2`.

  Each item comes back to the status it had before it was trashed.
  Runs under the per-catalogue lock every trash / restore path takes, so
  no category trash can land between the read that partitions the items
  and the write — a transaction alone does not stop that under READ
  COMMITTED, and it used to leave live items in a trashed category.
  """
  @spec bulk_restore_items([Ecto.UUID.t()], keyword()) :: {non_neg_integer(), nil}
  def bulk_restore_items([], _opts), do: {0, nil}

  def bulk_restore_items(uuids, opts) when is_list(uuids) do
    uuids = scope_item_uuids(uuids, opts[:catalogue_uuid])

    restore = fn ->
      Trash.lock_catalogues_of!(Item, uuids)
      do_bulk_restore_items(uuids)
    end

    case Trash.locked_transaction(restore) do
      {:ok, {count, count_detached, restored_uuids, catalogue_uuids, detached}} ->
        detached
        |> Enum.map(&{&1, %{&1 | category_uuid: nil}})
        |> MediaFolders.follow(opts[:actor_uuid])

        if count > 0 do
          Shared.log_activity(
            %{
              action: "item.bulk_restored",
              mode: "manual",
              actor_uuid: opts[:actor_uuid],
              resource_type: "item",
              metadata: %{
                "count" => count,
                "detached_count" => count_detached,
                "uuids" => restored_uuids
              }
            },
            broadcast: false
          )

          broadcast_item_batch(catalogue_uuids, opts)
        end

        {count, nil}

      # A rollback inside the batch is a result, not a MatchError — and
      # its audit row says "restore", not "reorder".
      {:error, reason} ->
        Logger.warning("bulk_restore_items rolled back: #{inspect(reason)}")

        Shared.log_activity(
          %{
            action: "item.bulk_restored",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            metadata: %{"count" => 0, "uuids" => uuids, "db_pending" => true}
          },
          broadcast: false
        )

        {0, nil}
    end
  end

  defp do_bulk_restore_items(uuids) do
    now = DateTime.utc_now()

    items =
      from(i in Item,
        where: i.uuid in ^uuids and i.status == "deleted",
        preload: [:catalogue, :category]
      )
      |> repo().all()
      |> Enum.reject(fn i -> i.catalogue && i.catalogue.status == "deleted" end)

    {attached_uuids, detached_uuids} =
      Enum.split_with(items, fn item ->
        is_nil(item.category) || item.category.status != "deleted"
      end)
      |> then(fn {attached, detached} ->
        {Enum.map(attached, & &1.uuid), Enum.map(detached, & &1.uuid)}
      end)

    # The lock makes the partition above current; the guard keeps the write
    # right even if a future caller forgets it.
    {count_attached, _} =
      from(i in Item, as: :item, where: i.uuid in ^attached_uuids and i.status == "deleted")
      |> Trash.outside_trashed_categories()
      |> Trash.restore_trashed(:item, now)
      |> repo().update_all([])

    {count_detached, _} =
      from(i in Item, where: i.uuid in ^detached_uuids and i.status == "deleted")
      |> Trash.restore_trashed(:item, now)
      |> update(set: [category_uuid: nil])
      |> repo().update_all([])

    catalogue_uuids = items |> Enum.map(& &1.catalogue_uuid) |> Enum.uniq()

    detached = Enum.filter(items, &(&1.uuid in detached_uuids))

    {count_attached + count_detached, count_detached, attached_uuids ++ detached_uuids,
     catalogue_uuids, detached}
  end

  @doc """
  Bulk hard-deletes items by UUID. Use with care — no soft-delete cycle.
  Logs a single `item.bulk_permanently_deleted` activity row when
  count > 0.
  """
  @spec bulk_permanently_delete_items([Ecto.UUID.t()], keyword()) ::
          {non_neg_integer(), nil}
  def bulk_permanently_delete_items([], _opts), do: {0, nil}

  def bulk_permanently_delete_items(uuids, opts) when is_list(uuids) do
    uuids = scope_item_uuids(uuids, opts[:catalogue_uuid])

    release =
      MediaFolders.release_plan([
        from(i in Item, where: i.uuid in ^uuids) |> only_trashed_items(opts)
      ])

    {count, catalogue_uuids} =
      Trash.locked_transaction(fn ->
        catalogue_uuids = Trash.lock_catalogues_of!(Item, uuids)

        {count, _} =
          from(i in Item, where: i.uuid in ^uuids)
          |> only_trashed_items(opts)
          |> repo().delete_all()

        {count, catalogue_uuids}
      end)
      |> bulk_result()

    if count > 0 do
      MediaFolders.release(release)

      Shared.log_activity(
        %{
          action: "item.bulk_permanently_deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          metadata: %{"count" => count, "uuids" => uuids}
        },
        broadcast: false
      )

      broadcast_item_batch(catalogue_uuids, opts)
    end

    {count, nil}
  end

  @doc """
  Bulk-moves items to a target category within a single catalogue.

  ## Required opts

    * `:catalogue_uuid` — the calling LV's catalogue scope. Every item
      in `uuids` MUST already belong to this catalogue, and `target_uuid`
      (when not `nil`) must live in this catalogue. The single-item DnD
      handler enforces the same scope; this guard makes the bulk path
      symmetric so a crafted client request can't silently flip an
      item's `catalogue_uuid` cross-catalogue.

  Pass `target_uuid: nil` to uncategorize all items within their
  catalogue.

  Returns `{:ok, count}`, `{:error, :category_not_found}` (target),
  `{:error, :wrong_catalogue_scope}` (target lives elsewhere or one or
  more items don't belong to `:catalogue_uuid`), or
  `{:error, :missing_catalogue_scope}` (caller forgot the required opt).
  """
  @spec bulk_move_items_to_category([Ecto.UUID.t()], Ecto.UUID.t() | nil, keyword()) ::
          {:ok, non_neg_integer()}
          | {:error, :category_not_found}
          | {:error, :wrong_catalogue_scope}
          | {:error, :missing_catalogue_scope}
  def bulk_move_items_to_category([], _target, _opts), do: {:ok, 0}

  def bulk_move_items_to_category(uuids, target_uuid, opts) when is_list(uuids) do
    with {:ok, scope} <- fetch_bulk_scope(opts),
         :ok <- ensure_items_in_catalogue(uuids, scope),
         :ok <- target_in_scope(target_uuid, scope) do
      destination = if target_uuid, do: {:category, target_uuid}, else: {:catalogue, scope}
      bulk_move_items(uuids, destination, opts)
    end
  end

  # The same-catalogue flavour's one extra rule: the target category is
  # this catalogue's. `bulk_move_items/3` re-reads it under the locks.
  defp target_in_scope(nil, _scope), do: :ok

  defp target_in_scope(target_uuid, scope) do
    query =
      from(c in Category, where: c.uuid == ^target_uuid, select: {c.catalogue_uuid, c.status})

    case Shared.valid_uuid?(target_uuid) && repo().one(query) do
      {^scope, status} when status != "deleted" -> :ok
      {_other, status} when status != "deleted" -> {:error, :wrong_catalogue_scope}
      _ -> {:error, :category_not_found}
    end
  end

  @doc """
  Bulk-moves items from one catalogue to a destination anywhere:
  `{:category, uuid}` (the item takes that category's catalogue) or
  `{:catalogue, uuid}` (uncategorized in that catalogue — the current one
  included).

  `opts[:catalogue_uuid]` is required and is the SOURCE scope: every
  uuid must be an item of that catalogue, or nothing moves
  (`:wrong_catalogue_scope`) — the selection is client-captured. Both
  catalogues' locks are held for the move, so a trash of either cannot
  interleave. Refuses a missing/trashed destination
  (`:category_not_found` / `:catalogue_not_found`) and one of the other
  catalogue kind (`:kind_mismatch`). Trashed items in the list are
  skipped.

  Logs one `item.bulk_moved` activity and tells both catalogues.
  Returns `{:ok, count}`.
  """
  @spec bulk_move_items(
          [Ecto.UUID.t()],
          {:category, Ecto.UUID.t()} | {:catalogue, Ecto.UUID.t()},
          keyword()
        ) :: {:ok, non_neg_integer()} | {:error, atom()}
  def bulk_move_items(uuids, destination, opts) when is_list(uuids) do
    with {:ok, scope} <- fetch_bulk_scope(opts),
         {:ok, uuids} <- cast_uuids(uuids),
         :ok <- valid_destination(destination) do
      case uuids do
        [] -> {:ok, 0}
        uuids -> run_bulk_move_items(uuids, destination, scope, opts)
      end
    end
  end

  defp fetch_bulk_scope(opts) do
    case Keyword.fetch(opts, :catalogue_uuid) do
      {:ok, scope} when is_binary(scope) -> {:ok, scope}
      _ -> {:error, :missing_catalogue_scope}
    end
  end

  defp cast_uuids(uuids) do
    if Enum.all?(uuids, &Shared.valid_uuid?/1),
      do: {:ok, Enum.uniq(uuids)},
      else: {:error, :invalid_uuid}
  end

  defp valid_destination({kind, uuid}) when kind in [:category, :catalogue] do
    cond do
      Shared.valid_uuid?(uuid) -> :ok
      kind == :category -> {:error, :category_not_found}
      true -> {:error, :catalogue_not_found}
    end
  end

  defp valid_destination(_), do: {:error, :invalid_entry}

  defp run_bulk_move_items(uuids, destination, scope, opts) do
    result =
      Trash.locked_transaction(fn ->
        target_catalogue = destination_catalogue(destination)
        Trash.lock_catalogues!([scope, target_catalogue])

        if ensure_items_in_catalogue(uuids, scope) != :ok,
          do: repo().rollback(:wrong_catalogue_scope)

        target_category = lock_destination_category(destination, target_catalogue)
        Shared.check_move_destination!(scope, target_catalogue)
        moving = MediaFolders.moving_items(uuids)

        {count, _} =
          from(i in Item,
            where: i.uuid in ^uuids and i.catalogue_uuid == ^scope and i.status != "deleted"
          )
          |> repo().update_all(
            set: [
              catalogue_uuid: target_catalogue,
              category_uuid: target_category,
              updated_at: DateTime.utc_now()
            ]
          )

        {count, target_catalogue, target_category, moving}
      end)

    with {:ok, {count, target_catalogue, target_category, moving}} <- result do
      if count > 0,
        do: log_bulk_item_move(uuids, count, scope, target_catalogue, target_category, opts)

      moving
      |> Enum.filter(&(&1.catalogue_uuid == scope))
      |> Enum.map(&{&1, %{&1 | catalogue_uuid: target_catalogue, category_uuid: target_category}})
      |> MediaFolders.follow(opts[:actor_uuid])

      {:ok, count}
    end
  end

  defp log_bulk_item_move(uuids, count, scope, target_catalogue, target_category, opts) do
    Shared.log_activity(
      %{
        action: "item.bulk_moved",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        parent_catalogue_uuid: target_catalogue,
        metadata:
          %{
            "count" => count,
            # WHERE they landed, not a from/to: a bulk move gathers items
            # from many categories at once, so there is no single source to
            # put on the left of an arrow. Claiming one would be a lie the
            # reader cannot check.
            "moved_to" => %{
              "catalogue" => Shared.catalogue_ref(target_catalogue),
              "category" => Shared.category_ref(target_category)
            }
          }
          |> Map.merge(ActivityLog.sample_uuids(uuids, count))
      },
      opts
    )

    if scope != target_catalogue and Keyword.get(opts, :broadcast, true),
      do: PubSub.broadcast(:item, nil, scope)
  end

  # The catalogue a destination lives in, read before the locks; the
  # locked re-read in `lock_destination_category/2` retries the whole
  # transaction when a concurrent move changed it in between.
  defp destination_catalogue({:catalogue, uuid}), do: uuid

  defp destination_catalogue({:category, uuid}) do
    repo().one(from(c in Category, where: c.uuid == ^uuid, select: c.catalogue_uuid)) ||
      repo().rollback(:category_not_found)
  end

  defp lock_destination_category({:catalogue, _}, _catalogue_uuid), do: nil

  defp lock_destination_category({:category, uuid}, catalogue_uuid) do
    case repo().one(from(c in Category, where: c.uuid == ^uuid, lock: "FOR SHARE")) do
      %Category{status: "deleted"} -> repo().rollback(:category_not_found)
      %Category{catalogue_uuid: ^catalogue_uuid} -> uuid
      %Category{} -> repo().rollback(:catalogue_moved)
      nil -> repo().rollback(:category_not_found)
    end
  end

  # `opts[:catalogue_uuid]` on the bulk item ops is a scope: uuids that
  # are not this catalogue's items are dropped before anything is
  # touched (the lists are client-captured; the page only re-broadcasts
  # for its own catalogue).
  defp scope_item_uuids(uuids, nil), do: uuids

  defp scope_item_uuids(uuids, catalogue_uuid) do
    repo().all(
      from(i in Item,
        where: i.uuid in ^uuids and i.catalogue_uuid == ^catalogue_uuid,
        select: i.uuid
      )
    )
  end

  defp ensure_items_in_catalogue(uuids, catalogue_uuid) do
    foreign? =
      from(i in Item,
        where: i.uuid in ^uuids and i.catalogue_uuid != ^catalogue_uuid,
        limit: 1,
        select: i.uuid
      )
      |> repo().exists?()

    if foreign?, do: {:error, :wrong_catalogue_scope}, else: :ok
  end

  @doc """
  Moves an item to a different category.

  If the target category lives in a different catalogue, the item's
  `catalogue_uuid` is updated to match. Passing `nil` for `category_uuid`
  detaches the item from any category while keeping it in its current
  catalogue.

  Refuses a trashed item (`:not_found`), a missing or trashed category
  (`:category_not_found`) and a category in a catalogue of the other
  kind (`:kind_mismatch`). A move across catalogues tells both.

  ## Examples

      {:ok, item} = Catalogue.move_item_to_category(item, new_category_uuid)
      {:ok, item} = Catalogue.move_item_to_category(item, nil)  # make uncategorized
  """
  @spec move_item_to_category(Item.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Item.t()}
          | {:error,
             :category_not_found | :not_found | :kind_mismatch | Ecto.Changeset.t(Item.t())}
  def move_item_to_category(item, category_uuid, opts \\ [])

  def move_item_to_category(%Item{} = item, category_uuid, opts)
      when is_nil(category_uuid) or is_binary(category_uuid) do
    if is_nil(category_uuid) or Shared.valid_uuid?(category_uuid),
      do: do_move_item_to_category(item, category_uuid, opts),
      else: {:error, :category_not_found}
  end

  defp do_move_item_to_category(item, category_uuid, opts) do
    # One transaction, so the FOR SHARE lock `resolve_move_attrs/1` takes on
    # the target is held until the move commits: a concurrent category
    # trash either lands first (and the move refuses) or waits. The target
    # is locked BEFORE the item: a category trash holds the category and
    # then updates its items, so the other order could deadlock with it.
    result =
      repo().transaction(fn ->
        with {:ok, attrs} <- resolve_move_attrs(category_uuid),
             {:ok, current} <- lock_live_item(item),
             :ok <- same_kind(current.catalogue_uuid, attrs[:catalogue_uuid]),
             {:ok, moved} <- current |> Item.changeset(attrs) |> repo().update() do
          {moved, current}
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    with {:ok, {moved, before}} <- result do
      Shared.log_activity(
        %{
          action: "item.moved",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: moved.uuid,
          parent_catalogue_uuid: moved.catalogue_uuid,
          metadata: %{
            "name" => moved.name,
            "changes" =>
              ActivityLog.changes([
                {:category, Shared.category_ref(before.category_uuid),
                 Shared.category_ref(category_uuid)},
                {:catalogue, Shared.catalogue_ref(before.catalogue_uuid),
                 Shared.catalogue_ref(moved.catalogue_uuid)}
              ])
          }
        },
        Keyword.take(opts, [:broadcast, :mode])
      )

      if before.catalogue_uuid != moved.catalogue_uuid and Keyword.get(opts, :broadcast, true),
        do: PubSub.broadcast(:item, nil, before.catalogue_uuid)

      MediaFolders.follow([{before, moved}], opts[:actor_uuid])
      {:ok, moved}
    end
  end

  defp locked_move_item_to_catalogue(item, catalogue_uuid) do
    from_catalogue_uuid =
      repo().one(from(i in Item, where: i.uuid == ^item.uuid, select: i.catalogue_uuid)) ||
        repo().rollback(:not_found)

    if from_catalogue_uuid == catalogue_uuid, do: repo().rollback(:same_catalogue)
    Trash.lock_catalogues!([from_catalogue_uuid, catalogue_uuid])

    current =
      case lock_live_item(item) do
        {:ok, %Item{catalogue_uuid: ^from_catalogue_uuid} = current} -> current
        {:ok, _moved_meanwhile} -> repo().rollback(:catalogue_moved)
        {:error, reason} -> repo().rollback(reason)
      end

    Shared.check_move_destination!(from_catalogue_uuid, catalogue_uuid)

    case current
         |> Item.changeset(%{catalogue_uuid: catalogue_uuid, category_uuid: nil})
         |> repo().update() do
      {:ok, moved} -> {moved, current}
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  defp resolve_move_attrs(nil), do: {:ok, %{category_uuid: nil}}

  defp resolve_move_attrs(category_uuid) when is_binary(category_uuid) do
    case repo().one(from(c in Category, where: c.uuid == ^category_uuid, lock: "FOR SHARE")) do
      # A live item moved into a trashed category would vanish from the tree.
      %Category{status: "deleted"} ->
        {:error, :category_not_found}

      %Category{catalogue_uuid: cat_uuid} ->
        {:ok, %{category_uuid: category_uuid, catalogue_uuid: cat_uuid}}

      nil ->
        {:error, :category_not_found}
    end
  end

  # The item as it is now, row-locked; a trashed item is not movable (a
  # stale form or tab would otherwise carry a bin row somewhere new).
  defp lock_live_item(%Item{uuid: uuid}) do
    case repo().one(from(i in Item, where: i.uuid == ^uuid, lock: "FOR UPDATE")) do
      %Item{status: status} = current when status != "deleted" -> {:ok, current}
      _ -> {:error, :not_found}
    end
  end

  defp same_kind(_from, nil), do: :ok
  defp same_kind(same, same), do: :ok

  defp same_kind(from_uuid, to_uuid) do
    kinds =
      from(c in Catalogue, where: c.uuid in ^[from_uuid, to_uuid], select: {c.uuid, c.kind})
      |> repo().all()
      |> Map.new()

    if Map.get(kinds, from_uuid) == Map.get(kinds, to_uuid),
      do: :ok,
      else: {:error, :kind_mismatch}
  end

  @doc """
  Moves an item to a different catalogue, clearing its category.

  For smart items this is the whole move — categories don't apply; for
  standard items it files the item uncategorized in the target. Sets
  both `catalogue_uuid` and `category_uuid` in one update.

  Returns `{:error, :catalogue_not_found}` if the target catalogue is
  missing or trashed, `{:error, :same_catalogue}` if the item is already
  there, `{:error, :kind_mismatch}` for a catalogue of the other kind,
  `{:error, :not_found}` for a trashed item, or `{:error, changeset}` on
  validation failure. Both catalogues' locks are held, so a concurrent
  trash of either cannot interleave. Logs an `item.moved` activity with
  from/to catalogue metadata and tells both catalogues.

  ## Examples

      {:ok, item} = Catalogue.move_item_to_catalogue(item, other_smart.uuid)
  """
  @spec move_item_to_catalogue(Item.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Item.t()}
          | {:error,
             :catalogue_not_found
             | :same_catalogue
             | :kind_mismatch
             | :not_found
             | :catalogue_moved
             | Ecto.Changeset.t(Item.t())}
  def move_item_to_catalogue(%Item{} = item, catalogue_uuid, opts \\ [])
      when is_binary(catalogue_uuid) do
    # Whether the item is already there is decided from the row under the
    # lock, not from the caller's struct, which may be stale.
    if Shared.valid_uuid?(catalogue_uuid),
      do: do_move_item_to_catalogue(item, catalogue_uuid, opts),
      else: {:error, :catalogue_not_found}
  end

  defp do_move_item_to_catalogue(item, catalogue_uuid, opts) do
    result =
      Trash.locked_transaction(fn -> locked_move_item_to_catalogue(item, catalogue_uuid) end)

    with {:ok, {moved, before}} <- result do
      Shared.log_activity(
        %{
          action: "item.moved",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: moved.uuid,
          parent_catalogue_uuid: catalogue_uuid,
          metadata: %{
            "name" => moved.name,
            "changes" =>
              ActivityLog.changes([
                {:catalogue, Shared.catalogue_ref(before.catalogue_uuid),
                 Shared.catalogue_ref(catalogue_uuid)},
                {:category, Shared.category_ref(before.category_uuid), Shared.category_ref(nil)}
              ])
          }
        },
        Keyword.take(opts, [:broadcast, :mode])
      )

      if Keyword.get(opts, :broadcast, true),
        do: PubSub.broadcast(:item, nil, before.catalogue_uuid)

      MediaFolders.follow([{before, moved}], opts[:actor_uuid])
      {:ok, moved}
    end
  end

  @doc "Returns a changeset for tracking item changes."
  @spec change_item(Item.t(), map()) :: Ecto.Changeset.t(Item.t())
  def change_item(%Item{} = item, attrs \\ %{}) do
    Item.changeset(item, attrs)
  end

  @doc """
  Returns the full pricing breakdown for an item within its catalogue.

  Resolves both the catalogue's markup and discount (loading the
  catalogue association once if needed), then computes the sale price
  (after markup) and final price (after discount). The chain is
  `base → markup → discount`:

      sale_price  = base_price * (1 + effective_markup   / 100)
      final_price = sale_price  * (1 -  effective_discount / 100)

  Never raises — if the catalogue can't be loaded (e.g. DB hiccup), falls
  back to 0% markup and 0% discount and logs a warning so the caller
  still gets a renderable result instead of crashing a template.

  Returns a map with every field a pricing UI needs in one hop:

    * `:base_price` — the item's stored base price (or `nil` if unset)
    * `:catalogue_markup` — the catalogue's `markup_percentage` (the
      inherited default when the item has no override)
    * `:item_markup` — the item's markup override, or `nil` when
      inheriting from the catalogue
    * `:markup_percentage` — the markup actually applied (item override
      if set, otherwise catalogue's)
    * `:sale_price` — the price after markup, before any discount
      (or `nil` if no base price)
    * `:catalogue_discount` — the catalogue's `discount_percentage`
    * `:item_discount` — the item's discount override, or `nil` when
      inheriting from the catalogue
    * `:discount_percentage` — the discount actually applied (item
      override if set, otherwise catalogue's)
    * `:discount_amount` — the Decimal amount subtracted by the discount
      (`sale_price - final_price`), or `nil` if no discount applies or
      no base price
    * `:final_price` — the price after both markup and discount (or
      `nil` if no base price)

  ## Examples

      # Item inherits both markup (15%) and discount (10%)
      Catalogue.item_pricing(item)
      #=> %{
      #=>   base_price: Decimal.new("100.00"),
      #=>   catalogue_markup: Decimal.new("15.0"),
      #=>   item_markup: nil,
      #=>   markup_percentage: Decimal.new("15.0"),
      #=>   sale_price: Decimal.new("115.00"),
      #=>   catalogue_discount: Decimal.new("10.0"),
      #=>   item_discount: nil,
      #=>   discount_percentage: Decimal.new("10.0"),
      #=>   discount_amount: Decimal.new("11.50"),
      #=>   final_price: Decimal.new("103.50")
      #=> }

      # Item overrides discount to 0 — sale price is charged at full
      Catalogue.item_pricing(item_with_zero_discount)
      #=> %{..., final_price: Decimal.new("115.00"), discount_amount: Decimal.new("0.00"), ...}
  """
  @spec item_pricing(Item.t()) :: %{
          base_price: Decimal.t() | nil,
          catalogue_markup: Decimal.t() | nil,
          item_markup: Decimal.t() | nil,
          markup_percentage: Decimal.t() | nil,
          sale_price: Decimal.t() | nil,
          catalogue_discount: Decimal.t() | nil,
          item_discount: Decimal.t() | nil,
          discount_percentage: Decimal.t() | nil,
          discount_amount: Decimal.t() | nil,
          final_price: Decimal.t() | nil
        }
  def item_pricing(%Item{} = item) do
    {catalogue_markup, catalogue_discount} = safe_pricing_for_item(item)
    effective_markup = Item.effective_markup(item, catalogue_markup)
    effective_discount = Item.effective_discount(item, catalogue_discount)

    %{
      base_price: item.base_price,
      catalogue_markup: catalogue_markup,
      item_markup: item.markup_percentage,
      markup_percentage: effective_markup,
      sale_price: Item.sale_price(item, catalogue_markup),
      catalogue_discount: catalogue_discount,
      item_discount: item.discount_percentage,
      discount_percentage: effective_discount,
      discount_amount: Item.discount_amount(item, catalogue_markup, catalogue_discount),
      final_price: Item.final_price(item, catalogue_markup, catalogue_discount)
    }
  end

  @doc """
  The item type that actually applies to `item` — goods or service. The
  UI's entry point: unlike `Item.effective_type/1` it never raises and needs
  no preload. The item's own `item_type` answers without a query; otherwise
  a preloaded catalogue (or `category.catalogue`) is used, and failing that
  the catalogue's type is read — whatever the catalogue's status. An item
  without a catalogue (or whose catalogue row is gone) reads as goods.
  """
  @spec effective_item_type(Item.t()) :: String.t()
  def effective_item_type(%Item{item_type: type}) when is_binary(type), do: type

  def effective_item_type(%Item{} = item),
    do: Item.effective_type(item, catalogue_item_type(item))

  defp catalogue_item_type(%Item{catalogue: %Catalogue{item_type: type}}), do: type
  defp catalogue_item_type(%Item{catalogue: nil}), do: nil

  defp catalogue_item_type(%Item{category: %Category{catalogue: %Catalogue{item_type: type}}}),
    do: type

  defp catalogue_item_type(%Item{catalogue_uuid: uuid}) when is_binary(uuid) do
    repo().one(from(c in Catalogue, where: c.uuid == ^uuid, select: c.item_type))
  rescue
    # `effective_item_type/1` never raises — it is called while rendering —
    # so a failed read answers "no catalogue type" (goods). Said in the log,
    # or a database error would pass for an item without a catalogue.
    e ->
      Logger.warning(
        "Catalogue.effective_item_type: catalogue type read failed (#{inspect(e.__struct__)}); " <>
          "treating the item as having no catalogue type"
      )

      nil
  end

  defp catalogue_item_type(_item), do: nil

  # Returns {markup, discount} from the item's catalogue. Preloads
  # the catalogue association if needed; falls back to {0, 0} on any
  # failure so pricing rendering never crashes a template. One preload
  # handles both values.
  defp safe_pricing_for_item(item) do
    case item.catalogue do
      %Catalogue{} = catalogue ->
        {markup_from(catalogue), discount_from(catalogue)}

      %Ecto.Association.NotLoaded{} ->
        load_pricing(item)

      _ ->
        {Decimal.new("0"), Decimal.new("0")}
    end
  end

  defp load_pricing(item) do
    case repo().preload(item, [:catalogue]) do
      %Item{catalogue: %Catalogue{} = catalogue} ->
        {markup_from(catalogue), discount_from(catalogue)}

      _ ->
        {Decimal.new("0"), Decimal.new("0")}
    end
  rescue
    e ->
      Logger.warning(
        "[Catalogue] Failed to load catalogue for item_pricing/1 (item #{item.uuid}): " <>
          Exception.message(e)
      )

      {Decimal.new("0"), Decimal.new("0")}
  end

  defp markup_from(%Catalogue{markup_percentage: nil}), do: Decimal.new("0")
  defp markup_from(%Catalogue{markup_percentage: mp}), do: mp

  defp discount_from(%Catalogue{discount_percentage: nil}), do: Decimal.new("0")
  defp discount_from(%Catalogue{discount_percentage: d}), do: d

  # ═══════════════════════════════════════════════════════════════════
  # Smart-catalogue rules — see PhoenixKitCatalogue.Catalogue.Rules
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_catalogue_rules(item_or_uuid), to: Rules

  defdelegate catalogue_rule_map(item_or_uuid), to: Rules

  defdelegate get_catalogue_rule(item_uuid, referenced_catalogue_uuid), to: Rules

  defdelegate put_catalogue_rules(item, rules, opts \\ []), to: Rules

  defdelegate reorder_catalogue_rules(item_uuid, ordered_referenced_uuids, opts \\ []), to: Rules

  defdelegate list_items_referencing_catalogue(catalogue_uuid), to: Rules

  defdelegate catalogue_reference_count(catalogue_uuid), to: Rules

  defdelegate change_catalogue_rule(rule, attrs \\ %{}), to: Rules

  defdelegate create_catalogue_rule(attrs, opts \\ []), to: Rules

  defdelegate update_catalogue_rule(rule, attrs, opts \\ []), to: Rules

  defdelegate delete_catalogue_rule(rule, opts \\ []), to: Rules

  # ═══════════════════════════════════════════════════════════════════
  # Smart-catalogue pricing — see PhoenixKitCatalogue.Catalogue.SmartPricing
  # ═══════════════════════════════════════════════════════════════════

  defdelegate evaluate_smart_rules(entries, opts \\ []), to: SmartPricing

  # ═══════════════════════════════════════════════════════════════════
  # Search — see PhoenixKitCatalogue.Catalogue.Search
  # ═══════════════════════════════════════════════════════════════════

  defdelegate search_items(query, opts \\ []), to: Search

  defdelegate count_search_items(query, opts \\ []), to: Search

  defdelegate search_items_in_catalogue(catalogue_uuid, query, opts \\ []), to: Search

  defdelegate search_categories(catalogue_uuid, query, opts \\ []), to: Search

  defdelegate match_search_text(query, term), to: Search, as: :match_text

  defdelegate count_search_items_in_catalogue(catalogue_uuid, query), to: Search

  defdelegate search_items_in_category(category_uuid, query, opts \\ []), to: Search

  defdelegate count_search_items_in_category(category_uuid, query), to: Search

  # ═══════════════════════════════════════════════════════════════════
  # Counts — see PhoenixKitCatalogue.Catalogue.Counts
  # ═══════════════════════════════════════════════════════════════════

  defdelegate item_count_for_catalogue(catalogue_uuid), to: Counts

  defdelegate item_counts_by_catalogue(opts \\ []), to: Counts

  defdelegate trashed_item_counts_by_root(catalogue_uuid), to: Counts

  defdelegate attached_file_counts(resources), to: Counts

  defdelegate active_item_count_in_subtree(category_uuid), to: Counts

  defdelegate category_count_for_catalogue(catalogue_uuid), to: Counts

  defdelegate category_counts_by_catalogue(), to: Counts

  defdelegate deleted_item_count_for_catalogue(catalogue_uuid), to: Counts

  defdelegate deleted_category_count_for_catalogue(catalogue_uuid), to: Counts

  defdelegate deleted_count_for_catalogue(catalogue_uuid), to: Counts

  # ═══════════════════════════════════════════════════════════════════
  # Multilang helpers — see PhoenixKitCatalogue.Catalogue.Translations
  # ═══════════════════════════════════════════════════════════════════

  defdelegate get_translation(record, lang_code), to: Translations

  defdelegate translated_name(record, locale), to: Translations

  defdelegate translated_description(record, locale), to: Translations

  defdelegate translated_seo_title(record, locale), to: Translations

  defdelegate translated_seo_description(record, locale), to: Translations

  defdelegate localize(records, locale), to: Translations

  defdelegate localize_one(record, locale), to: Translations

  defdelegate set_translation(record, lang_code, field_data, update_fn, opts \\ []),
    to: Translations

  # ═══════════════════════════════════════════════════════════════════
  # PDF library — see PhoenixKitCatalogue.Catalogue.PdfLibrary
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_pdfs(opts \\ []), to: PdfLibrary

  defdelegate count_pdfs(opts \\ []), to: PdfLibrary

  defdelegate get_pdf(uuid), to: PdfLibrary

  defdelegate get_pdf!(uuid), to: PdfLibrary

  defdelegate get_pdf_extraction(pdf), to: PdfLibrary, as: :get_extraction

  defdelegate create_pdf_from_upload(tmp_path, original_filename, opts \\ []),
    to: PdfLibrary

  defdelegate trash_pdf(pdf, opts \\ []), to: PdfLibrary

  defdelegate restore_pdf(pdf, opts \\ []), to: PdfLibrary

  defdelegate permanently_delete_pdf(pdf, opts \\ []), to: PdfLibrary

  defdelegate search_pdfs_for_item(item, opts \\ []), to: PdfLibrary

  defdelegate search_pdf_contents(query, opts \\ []), to: PdfLibrary

  defdelegate more_pdf_content_matches(query, pdf_uuid, opts \\ []), to: PdfLibrary

  defdelegate more_pdf_matches_for_item(item, pdf_uuid, opts \\ []), to: PdfLibrary

  defdelegate prune_orphan_pdf_page_contents(), to: PdfLibrary, as: :prune_orphan_page_contents

  defdelegate retry_extraction(pdf, opts \\ []), to: PdfLibrary

  defdelegate requeue_stuck_extractions(opts \\ []), to: PdfLibrary

  # ═══════════════════════════════════════════════════════════════════
  # Attribute groups — see PhoenixKitCatalogue.Catalogue.Attributes
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_attribute_groups(opts \\ []), to: Attributes

  defdelegate change_attribute_group(group, attrs \\ %{}), to: Attributes

  defdelegate get_attribute_group(uuid), to: Attributes

  defdelegate get_attribute_group_full(uuid), to: Attributes

  defdelegate attribute_counts(group_uuids), to: Attributes

  defdelegate assignment_counts(group_uuids), to: Attributes

  defdelegate create_attribute_group(attrs, opts \\ []), to: Attributes

  defdelegate update_attribute_group(group, attrs, opts \\ []), to: Attributes

  defdelegate delete_attribute_group(group, opts \\ []), to: Attributes

  defdelegate get_attribute(uuid), to: Attributes

  defdelegate create_attribute(group, attrs, opts \\ []), to: Attributes

  defdelegate update_attribute(attribute, attrs, opts \\ []), to: Attributes

  defdelegate delete_attribute(attribute, opts \\ []), to: Attributes

  defdelegate reorder_attributes(group, uuids, opts \\ []), to: Attributes

  defdelegate get_attribute_value(uuid), to: Attributes

  defdelegate create_attribute_value(attribute, attrs, opts \\ []), to: Attributes

  defdelegate update_attribute_value(value, attrs, opts \\ []), to: Attributes

  defdelegate delete_attribute_value(value, opts \\ []), to: Attributes

  defdelegate set_default_value(value, opts \\ []), to: Attributes

  defdelegate reorder_attribute_values(attribute, uuids, opts \\ []), to: Attributes

  # ── Attribute SETS (2026-08-18 rework; see AttributeSets moduledoc) ─
  defdelegate create_attribute_set(attrs, opts \\ []), to: AttributeSets, as: :create_set

  defdelegate list_attribute_sets(opts \\ []), to: AttributeSets, as: :list_sets

  defdelegate get_attribute_set(uuid, opts \\ []), to: AttributeSets, as: :get_set

  defdelegate update_attribute_set(set, attrs, opts \\ []), to: AttributeSets, as: :update_set

  defdelegate delete_attribute_set(set, opts \\ []), to: AttributeSets, as: :delete_set

  defdelegate archive_attribute_set(set, opts \\ []), to: AttributeSets, as: :archive_set

  defdelegate restore_attribute_set(set, opts \\ []), to: AttributeSets, as: :restore_set

  defdelegate attribute_value_match_counts(opts \\ []),
    to: AttributeSets,
    as: :value_match_counts

  defdelegate attribute_filter_options(catalogue_uuid, opts \\ []),
    to: AttributeSets,
    as: :filter_options

  defdelegate attribute_set_uuids_matching_value(set_uuids, term),
    to: AttributeSets,
    as: :set_uuids_matching_value

  defdelegate list_attribute_set_attached_items(set_uuid, opts \\ []),
    to: AttributeSets,
    as: :list_attached_items

  defdelegate count_attribute_set_attached_items(set_uuid, opts \\ []),
    to: AttributeSets,
    as: :count_attached_items

  defdelegate create_attribute_set_value(set, attrs, opts \\ []),
    to: AttributeSets,
    as: :create_value

  defdelegate list_attribute_set_values(set, opts \\ []), to: AttributeSets, as: :list_values

  defdelegate list_attribute_set_values_for(set_uuids, opts \\ []),
    to: AttributeSets,
    as: :list_values_for

  defdelegate list_attribute_set_hidden_values_for(set_uuids, opts \\ []),
    to: AttributeSets,
    as: :list_hidden_values_for

  defdelegate drop_hidden_attribute_set_value_duplicates(hidden_values, values),
    to: AttributeSets,
    as: :drop_hidden_duplicates

  defdelegate get_attribute_set_value(set, value_uuid), to: AttributeSets, as: :get_value

  defdelegate update_attribute_set_value(set, value, attrs, opts \\ []),
    to: AttributeSets,
    as: :update_value

  defdelegate delete_attribute_set_value(set, value, opts \\ []),
    to: AttributeSets,
    as: :delete_value

  defdelegate reorder_attribute_set_values(set, ordered_uuids, opts \\ []),
    to: AttributeSets,
    as: :reorder_values

  defdelegate add_attribute_set_field(set, attrs, opts \\ []),
    to: AttributeSets,
    as: :add_extra_field

  defdelegate remove_attribute_set_field(set, key, opts \\ []),
    to: AttributeSets,
    as: :remove_extra_field

  defdelegate update_attribute_set_field(set, key, attrs, opts \\ []),
    to: AttributeSets,
    as: :update_extra_field

  defdelegate attribute_set_field_types(), to: AttributeSets, as: :extra_field_types

  # ── Supplier custom fields (entities-defined, values on the row) ────

  defdelegate supplier_crm_company_uuid(reference), to: Suppliers, as: :crm_company_uuid

  # ── Supplier comments (one thread per item × supplier) ──────────────
  # See PhoenixKitCatalogue.Catalogue.SupplierComments.
  defdelegate supplier_comment_resource_type(), to: SupplierComments, as: :resource_type

  defdelegate supplier_comment_thread_uuid(info), to: SupplierComments, as: :thread_uuid

  defdelegate supplier_comment_thread_for_pair(item_uuid, supplier_uuid),
    to: SupplierComments,
    as: :thread_for_pair

  defdelegate resolve_supplier_comment_resources(uuids),
    to: SupplierComments,
    as: :resolve_resources

  defdelegate supplier_builtin_fields(), to: SupplierFields, as: :builtin_fields

  defdelegate supplier_builtin_field(key), to: SupplierFields, as: :builtin_field

  defdelegate cast_supplier_builtin(key, raw), to: SupplierFields, as: :cast_builtin

  defdelegate supplier_fields(opts \\ []), to: SupplierFields, as: :fields

  defdelegate supplier_field(key, opts \\ []), to: SupplierFields, as: :field

  defdelegate supplier_field_types(), to: SupplierFields, as: :field_types

  defdelegate supplier_fields_enabled?(), to: SupplierFields, as: :enabled?

  defdelegate add_supplier_field(attrs, opts \\ []), to: SupplierFields, as: :add_field

  defdelegate update_supplier_field(key, attrs, opts \\ []), to: SupplierFields, as: :update_field

  defdelegate remove_supplier_field(key, opts \\ []), to: SupplierFields, as: :remove_field

  defdelegate supplier_field_values(info), to: SupplierFields, as: :values

  defdelegate cast_supplier_field_values(raw, opts \\ []), to: SupplierFields, as: :cast_values

  defdelegate put_supplier_field_values(metadata, values), to: SupplierFields, as: :put_values

  defdelegate attach_attribute_set(item_uuid, set_uuid, opts \\ []),
    to: AttributeSets,
    as: :attach_set

  defdelegate detach_attribute_set(item_uuid, set_uuid, opts \\ []),
    to: AttributeSets,
    as: :detach_set

  defdelegate reorder_attribute_sets(item_uuid, set_uuids, opts \\ []),
    to: AttributeSets,
    as: :reorder_attachments

  defdelegate list_attribute_set_attachments(item_uuid), to: AttributeSets, as: :list_attachments

  defdelegate set_attribute_set_selection(item_uuid, set_uuid, slugs, opts \\ []),
    to: AttributeSets,
    as: :set_attachment_selection

  defdelegate resolve_attribute_sets(item_uuids, opts \\ []),
    to: AttributeSets,
    as: :resolve_for_items

  defdelegate attribute_set_presence(item_uuids), to: AttributeSets, as: :attached_item_uuids

  defdelegate resolve_attribute_sets_for_item(item_uuid, opts \\ []),
    to: AttributeSets,
    as: :resolve_for_item

  defdelegate resolve_attribute_set(set_uuid, opts \\ []), to: AttributeSets, as: :resolve_set

  defdelegate attribute_sets_enabled?(), to: AttributeSets, as: :enabled?

  defdelegate attribute_set_contract(set), to: AttributeSets, as: :contract

  defdelegate attribute_set_kind(set), to: AttributeSets, as: :kind

  defdelegate attribute_set_default_value_slug(set), to: AttributeSets, as: :default_value_slug

  defdelegate attribute_set_attached?(set_uuid), to: AttributeSets, as: :set_attached?

  defdelegate valid_attribute_set_selection(slugs, resolved_set),
    to: AttributeSets,
    as: :valid_selection

  defdelegate prune_orphan_attribute_set_attachments(set_uuid),
    to: AttributeSets,
    as: :prune_orphan_attachments

  defdelegate prune_orphan_attribute_set_value_slugs(set_uuid),
    to: AttributeSets,
    as: :prune_orphan_value_slugs

  defdelegate attribute_set_value_counts(set_uuids), to: AttributeSets, as: :value_counts

  defdelegate attribute_set_attachment_counts(set_uuids),
    to: AttributeSets,
    as: :attachment_counts

  defdelegate migrate_attribute_groups_to_sets(opts \\ []),
    to: AttributeSets,
    as: :migrate_groups_to_sets

  defdelegate auto_migrate_attribute_groups(), to: AttributeSets, as: :auto_migrate_legacy

  defdelegate set_item_attribute_group(item, group_uuid, opts \\ []), to: Attributes

  defdelegate get_item_attribute_group_uuid(item_uuid), to: Attributes

  defdelegate item_attribute_group_map(item_uuids), to: Attributes

  defdelegate attribute_group_names(group_uuids), to: Attributes

  defdelegate resolved_group(group_uuid, lang), to: Attributes
end
