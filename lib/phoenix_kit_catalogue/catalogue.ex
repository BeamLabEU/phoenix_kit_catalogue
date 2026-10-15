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

  @category_logged_fields [:name, :status, :description]

  # Slug projection tables read by `get_item_by_slug/3` / `get_category_by_slug/3`
  # (owned by `PhoenixKitCatalogue.Catalogue.Slugs`'s generation rule, kept in
  # sync by the `trg_cat_item_slugs` / `trg_cat_category_slugs` triggers).
  @item_slugs_table "phoenix_kit_cat_item_slugs"

  @category_slugs_table "phoenix_kit_cat_category_slugs"

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
  # Categories
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists non-deleted categories for a catalogue, ordered by position then name.

  Preloads items (non-deleted only).
  """
  @spec list_categories_for_catalogue(Ecto.UUID.t()) :: [Category.t()]
  def list_categories_for_catalogue(catalogue_uuid) do
    from(c in Category,
      where: c.catalogue_uuid == ^catalogue_uuid and c.status != "deleted",
      order_by: [asc: :position, asc: :name],
      preload: [:items]
    )
    |> repo().all()
  end

  @doc """
  Lists categories for a catalogue **without** preloading items, ordered by
  position then name. Used by the infinite-scroll detail view to walk
  categories in display order without fetching potentially thousands of
  items up front.

  ## Options

    * `:mode` — `:active` (default, excludes deleted categories) or
      `:deleted` (all categories — deleted categories can still contain
      trashed items we want to show).
  """
  @spec list_categories_metadata_for_catalogue(Ecto.UUID.t(), keyword()) :: [Category.t()]
  def list_categories_metadata_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        order_by: [asc: :position, asc: :name]
      )

    query =
      case mode do
        :active -> where(query, [c], c.status != "deleted")
        :deleted -> query
      end

    repo().all(query)
  end

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
  One-shot helper for lazy-loading a catalogue's category tree. Returns
  category metadata plus per-category and uncategorized item counts in
  two queries instead of three.

  Combines the work of:

    * `list_categories_metadata_for_catalogue/2`
    * `item_counts_by_category_for_catalogue/2`
    * `uncategorized_count_for_catalogue/2`

  Categories are ordered the same way `list_categories_metadata_for_catalogue/2`
  orders them. Empty categories don't appear in `:item_counts` (treat
  missing keys as `0`).

  ## Options

    * `:mode` — `:active` (default, excludes deleted) or `:deleted`.
      Mode is applied uniformly to both the categories query and the
      item-count query.
  """
  @spec category_summary_for_catalogue(Ecto.UUID.t(), keyword()) :: %{
          categories: [Category.t()],
          item_counts: %{Ecto.UUID.t() => non_neg_integer()},
          uncategorized_count: non_neg_integer()
        }
  def category_summary_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    categories = list_categories_metadata_for_catalogue(catalogue_uuid, mode: mode)

    rows =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid,
        group_by: i.category_uuid,
        select: {i.category_uuid, count(i.uuid)}
      )
      |> apply_summary_mode(mode)
      |> repo().all()

    {item_counts, uncategorized_count} =
      Enum.reduce(rows, {%{}, 0}, fn
        {nil, count}, {map, _} -> {map, count}
        {uuid, count}, {map, uncat} -> {Map.put(map, uuid, count), uncat}
      end)

    %{
      categories: categories,
      item_counts: item_counts,
      uncategorized_count: uncategorized_count
    }
  end

  defp apply_summary_mode(query, :active),
    do: where(query, [i], i.status != "deleted")

  defp apply_summary_mode(query, :deleted),
    do: where(query, [i], i.status == "deleted")

  @doc """
  Lists all non-deleted categories across all non-deleted catalogues,
  with breadcrumb-style names prefixed by their catalogue and every
  ancestor category (e.g. `"Kitchen / Cabinets / Frames"`). Useful for
  item move dropdowns where the user needs to distinguish
  same-named leaves under different parents.

  Entries are grouped by catalogue (catalogues ordered by name) and
  within each catalogue returned in depth-first display order.

  One query for catalogues + one query for all their categories — the
  tree walk and breadcrumb rewrite happen in memory. Safe to call on
  demand from move-dropdowns.
  """
  @spec list_all_categories() :: [Category.t()]
  def list_all_categories do
    catalogues =
      from(cat in Catalogue,
        where: cat.status != "deleted",
        order_by: [asc: cat.position, asc: cat.name]
      )
      |> repo().all()

    case catalogues do
      [] ->
        []

      catalogues ->
        catalogue_uuids = Enum.map(catalogues, & &1.uuid)

        categories_by_catalogue =
          from(c in Category,
            where: c.catalogue_uuid in ^catalogue_uuids and c.status != "deleted",
            order_by: [asc: :position, asc: :name]
          )
          |> repo().all()
          |> Enum.group_by(& &1.catalogue_uuid)

        Enum.flat_map(catalogues, fn %Catalogue{uuid: uuid, name: cat_name} ->
          categories = Map.get(categories_by_catalogue, uuid, [])
          breadcrumb_categories_for_catalogue(cat_name, categories)
        end)
    end
  end

  # Builds the depth-first list of `%Category{name: "A / B / C"}` for
  # one catalogue from a flat, pre-sorted list of its categories.
  defp breadcrumb_categories_for_catalogue(cat_name, categories) when is_list(categories) do
    uuid_set = MapSet.new(categories, & &1.uuid)

    # Promote orphans (children whose parent isn't in this list because
    # it's been deleted or excluded) to roots so they still appear.
    normalized =
      Enum.map(categories, fn c ->
        if c.parent_uuid == nil or MapSet.member?(uuid_set, c.parent_uuid) do
          c
        else
          %{c | parent_uuid: nil}
        end
      end)

    index = Tree.build_children_index(normalized)

    {reversed, _} =
      normalized
      |> Enum.filter(&is_nil(&1.parent_uuid))
      |> Enum.reduce({[], %{}}, fn root, {acc, path_by_uuid} ->
        collect_breadcrumb(root, index, cat_name, path_by_uuid, acc)
      end)

    Enum.reverse(reversed)
  end

  defp collect_breadcrumb(%Category{} = cat, index, catalogue_name, path_by_uuid, acc) do
    parent_label =
      case cat.parent_uuid do
        nil -> catalogue_name
        parent_uuid -> Map.get(path_by_uuid, parent_uuid, catalogue_name)
      end

    full_label = "#{parent_label} / #{cat.name}"
    labeled = %{cat | name: full_label}
    path_by_uuid = Map.put(path_by_uuid, cat.uuid, full_label)
    acc = [labeled | acc]

    index
    |> Map.get(cat.uuid, [])
    |> Enum.reduce({acc, path_by_uuid}, fn child, {acc, path_by_uuid} ->
      collect_breadcrumb(child, index, catalogue_name, path_by_uuid, acc)
    end)
  end

  @doc "Fetches a category by UUID. Returns `nil` if not found."
  @spec get_category(Ecto.UUID.t()) :: Category.t() | nil
  def get_category(uuid), do: Helpers.get_by_uuid(Category, uuid)

  @doc "Fetches a category by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_category!(Ecto.UUID.t()) :: Category.t()
  def get_category!(uuid), do: Helpers.get_by_uuid!(Category, uuid)

  @doc """
  Fetches a category by its per-language `slug`.

  Tries an exact match in `lang`'s base language first (`"en-US"` folds
  to `"en"`), falling back to any language when `opts[:any_lang]` is
  `true`. The result is `{:error, :not_found}` on a miss; a hit is a
  2-tuple by default, or — whenever `opts[:any_lang]` is `true`, even
  when the base language itself matched — a 3-tuple carrying the
  language the slug actually matched in, so a caller that opted into
  the fallback can always destructure the same shape.
  """
  @spec get_category_by_slug(String.t(), String.t(), keyword()) ::
          {:ok, Category.t()} | {:ok, Category.t(), String.t()} | {:error, :not_found}
  def get_category_by_slug(slug, lang, opts \\ []) do
    Shared.find_by_slug(@category_slugs_table, "category_uuid", slug, lang, opts, fn uuid,
                                                                                     _opts ->
      get_category(uuid)
    end)
  end

  @doc """
  Creates a category within a catalogue.

  ## Required attributes

    * `:name` — category name (1-255 chars)
    * `:catalogue_uuid` — the parent catalogue

  ## Optional attributes

    * `:description`, `:position` (default 0), `:status` (`"active"` or `"deleted"`)
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_category(%{name: "Frames", catalogue_uuid: catalogue.uuid})
  """
  @spec create_category(map(), keyword()) ::
          {:ok, Category.t()} | {:error, Ecto.Changeset.t(Category.t())}
  def create_category(attrs, opts \\ []) do
    # One transaction, so the parent read `FOR SHARE` in the catalogue
    # check holds until the insert commits: a move of the parent's tree
    # to another catalogue either lands first (and the check sees the new
    # catalogue) or waits and then carries the new child along.
    result =
      repo().transaction(fn ->
        %Category{}
        |> Category.changeset(put_default_category_position(attrs))
        |> validate_parent_in_same_catalogue()
        |> Shared.stamp_created_deleted()
        |> repo().insert()
        |> case do
          {:ok, category} -> category
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, category} = ok ->
        Shared.log_activity(
          %{
            action: "category.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "category",
            resource_uuid: category.uuid,
            parent_catalogue_uuid: category.catalogue_uuid,
            metadata: %{"name" => category.name, "catalogue_uuid" => category.catalogue_uuid}
          },
          Keyword.take(opts, [:broadcast, :mode])
        )

        ok

      error ->
        error
    end
  end

  @doc """
  Updates a category with the given attributes.

  Pass `:data_owned_keys` (a list of top-level `data` keys) when the
  caller only owns PART of `data` — e.g. a form that only rendered a
  subset of it. See `update_item/3`'s doc for the full rationale; the
  mechanism is identical.
  """
  @spec update_category(Category.t(), map(), keyword()) ::
          {:ok, Category.t()}
          | {:error, Ecto.Changeset.t(Category.t()) | :not_found | :catalogue_moved}
  def update_category(%Category{} = category, attrs, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        # A new parent is checked for a cycle against the tree as committed:
        # under the lock of the catalogue the row is in now (not the
        # caller's copy's), taken before any row lock — the order
        # `move_category_under/3` takes them in — so two opposite re-parents
        # neither both pass nor deadlock on each other's rows. The checks
        # then run on the locked row.
        category =
          if reparenting?(category, attrs),
            do: Trash.lock_row_in_catalogue!(Category, category.uuid),
            else: category

        attrs = Shared.narrow_data_ownership(Category, category.uuid, attrs, opts)

        changeset =
          category
          |> Category.changeset(attrs)
          |> Shared.keep_trash_status(Category, category.uuid)
          |> validate_parent_in_same_catalogue()

        case repo().update(changeset) do
          {:ok, updated} -> updated
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, updated} ->
        Shared.log_activity(
          %{
            action: "category.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "category",
            resource_uuid: updated.uuid,
            parent_catalogue_uuid: updated.catalogue_uuid,
            metadata:
              ActivityLog.with_changes(
                %{"name" => updated.name},
                category,
                updated,
                @category_logged_fields
              )
          },
          opts
        )

        MediaFolders.follow([{category, updated}], opts[:actor_uuid])
        {:ok, updated}

      {:error, _reason} = error ->
        error
    end
  end

  # Any change of parent, to the top level included: a move there skips
  # no cycle check, but it must not slip past the lock a trash or restore
  # decides the subtree under.
  defp reparenting?(%Category{parent_uuid: current}, attrs) do
    case Map.get(attrs, :parent_uuid, Map.get(attrs, "parent_uuid", current)) do
      parent when parent in [nil, ""] -> not is_nil(current)
      parent -> to_string(parent) != to_string(current)
    end
  end

  # Guards both create_category/2 and update_category/3 against a
  # `parent_uuid` that names a category in a different catalogue, AND
  # against cycles on update (a raw
  # `update_category(cat, %{parent_uuid: descendant.uuid})` would
  # otherwise sail past the `move_category_under/3` checks). The
  # self-parent rejection lives on `Category.changeset`; the
  # cross-catalogue and full-subtree cycle checks need DB lookups, so
  # they live here.
  defp validate_parent_in_same_catalogue(%Ecto.Changeset{} = changeset) do
    catalogue_uuid = Ecto.Changeset.get_field(changeset, :catalogue_uuid)
    parent_uuid = Ecto.Changeset.get_field(changeset, :parent_uuid)
    own_uuid = Ecto.Changeset.get_field(changeset, :uuid)

    cond do
      parent_uuid in [nil, ""] ->
        changeset

      is_nil(catalogue_uuid) ->
        Ecto.Changeset.add_error(
          changeset,
          :parent_uuid,
          "cannot be set without a catalogue"
        )

      own_uuid && cycle?(parent_uuid, own_uuid) ->
        Ecto.Changeset.add_error(
          changeset,
          :parent_uuid,
          "would create a cycle"
        )

      true ->
        check_parent_catalogue(changeset, parent_uuid, catalogue_uuid)
    end
  end

  # `Tree.subtree_uuids/1` returns raw 16-byte binaries (the schema-less
  # outer CTE select strips Ecto's type info). The textual `parent_uuid`
  # we got from the changeset doesn't match those, so dump it to the
  # raw binary form before the membership test. Without this, a real
  # cycle is silently accepted — the test
  # `update_category/3 rejects a parent that is a descendant (cycle)`
  # pins the regression.
  defp cycle?(parent_uuid, own_uuid) do
    case Ecto.UUID.dump(parent_uuid) do
      {:ok, raw} -> raw in Tree.subtree_uuids(own_uuid)
      :error -> false
    end
  end

  # `FOR SHARE`: callers run inside a transaction, so the parent cannot
  # change catalogue between this check and their write.
  # A parent being SET must be live: a new or moved category under a
  # trashed one would be a live row inside the trash. A row that keeps its
  # parent (a restore, an edit of other fields) is not re-checked for it.
  defp check_parent_catalogue(changeset, parent_uuid, catalogue_uuid) do
    case repo().one(from(c in Category, where: c.uuid == ^parent_uuid, lock: "FOR SHARE")) do
      nil ->
        Ecto.Changeset.add_error(changeset, :parent_uuid, "does not exist")

      %Category{status: "deleted"} = parent ->
        if Ecto.Changeset.get_change(changeset, :parent_uuid),
          do: Ecto.Changeset.add_error(changeset, :parent_uuid, "does not exist"),
          else: check_same_catalogue(changeset, parent, catalogue_uuid)

      %Category{} = parent ->
        check_same_catalogue(changeset, parent, catalogue_uuid)
    end
  end

  defp check_same_catalogue(changeset, %Category{catalogue_uuid: catalogue_uuid}, catalogue_uuid),
    do: changeset

  defp check_same_catalogue(changeset, _parent, _catalogue_uuid),
    do: Ecto.Changeset.add_error(changeset, :parent_uuid, "must belong to the same catalogue")

  @doc "Hard-deletes a category. Prefer `trash_category/1` for soft-delete."
  @spec delete_category(Category.t(), keyword()) :: {:ok, Category.t()} | {:error, term()}
  def delete_category(%Category{} = category, opts \\ []) do
    release = MediaFolders.release_plan([from(c in Category, where: c.uuid == ^category.uuid)])

    case repo().delete(category) do
      {:ok, _} = ok ->
        MediaFolders.release(release)

        Shared.log_activity(%{
          action: "category.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          parent_catalogue_uuid: category.catalogue_uuid,
          metadata: %{"name" => category.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes a category and its entire subtree by setting their
  status to `"deleted"`.

  **Cascades the categories downward** in a transaction (the category
  itself and every descendant flip to `"deleted"`), following the V103
  nested-category tree.

  **Items in the subtree** are handled per the `:items` opt:

    * `:cascade` (default) — items in the subtree flip to `"deleted"`
      alongside the categories. Original behavior, kept for programmatic
      callers + admin "delete and trash everything" intent.
    * `:uncategorize` — items in the subtree keep their `catalogue_uuid`
      but get `category_uuid: nil`, surviving the category trash. Used
      by the admin modal when the operator wants the category gone but
      the items kept in the same catalogue.
    * `{:move_to, target_uuid}` — items move to the target category
      (which must live in the same catalogue) before the category is
      trashed. Cross-catalogue moves aren't supported here; the LV
      restricts the dropdown to same-catalogue targets.

  Every category and cascaded item it flips is stamped as taken by this
  category, so `restore_category/2` can bring back exactly that set
  (`dev_docs/guides/trash-and-restore.md`). `{:move_to, _}` refuses a
  trashed target with `{:error, :move_target_not_found}`.

  Logs a single `category.trashed` activity on the root with
  `subtree_size`, `items_handled`, and `items_disposition` in metadata.

  ## Examples

      {:ok, _} = Catalogue.trash_category(category)
      {:ok, _} = Catalogue.trash_category(category, items: :uncategorize)
      {:ok, _} = Catalogue.trash_category(category, items: {:move_to, target_uuid})
  """
  @spec trash_category(Category.t(), keyword()) ::
          {:ok, Category.t()}
          | {:error,
             :move_target_not_found
             | :cross_catalogue_move
             | :move_target_in_subtree
             | term()}
  def trash_category(%Category{} = category, opts \\ []) do
    disposition = Keyword.get(opts, :items, :cascade)

    result =
      Trash.locked_transaction(fn ->
        category = Trash.lock_row_in_catalogue!(Category, category.uuid)
        now = DateTime.utc_now()
        subtree = Tree.subtree_uuids(category.uuid)
        Trash.lock_categories!(subtree)
        moving = disposition_moving(disposition, subtree)

        case apply_item_disposition(disposition, subtree, category, now) do
          {:ok, items_handled} ->
            root = category.uuid

            {children, _} =
              from(c in Category,
                where: c.uuid in ^subtree and c.uuid != ^root and c.status != "deleted"
              )
              |> Trash.stamp_trashed("category", root, now)
              |> repo().update_all([])

            {self, _} =
              from(c in Category, where: c.uuid == ^root and c.status != "deleted")
              |> Trash.stamp_trashed("self", root, now)
              |> repo().update_all([])

            changed? = children + self + items_handled > 0
            pairs = disposition_pairs(moving, disposition, category)
            {repo().get!(Category, root), length(subtree), items_handled, changed?, pairs}

          {:error, reason} ->
            repo().rollback(reason)
        end
      end)

    case result do
      # Already in the trash with nothing live under it: this call trashed
      # nothing, so it records nothing.
      {:ok, {updated, _subtree_size, _items_handled, false, _pairs}} ->
        {:ok, updated}

      {:ok, {updated, subtree_size, items_handled, true, pairs}} ->
        MediaFolders.follow(pairs, opts[:actor_uuid])

        # `broadcast: false` lets `bulk_trash_categories/3` run this inside
        # its own transaction and fan out once after that commits.
        Shared.log_activity(
          %{
            action: "category.trashed",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "category",
            resource_uuid: updated.uuid,
            parent_catalogue_uuid: updated.catalogue_uuid,
            metadata: %{
              "name" => updated.name,
              "catalogue_uuid" => updated.catalogue_uuid,
              "subtree_size" => subtree_size,
              "items_handled" => items_handled,
              "items_disposition" => disposition_to_metadata(disposition)
            }
          },
          Keyword.take(opts, [:broadcast, :mode])
        )

        {:ok, updated}

      error ->
        error
    end
  end

  # The items a trash takes out of the subtree, with a folder, as they are
  # now — their folders follow them to the catalogue or the target category.
  defp disposition_moving(:cascade, _subtree), do: []

  defp disposition_moving(_disposition, subtree) do
    MediaFolders.moving_records(
      from(i in Item, where: i.category_uuid in ^subtree and i.status != "deleted")
    )
  end

  defp disposition_pairs(moving, :uncategorize, category),
    do:
      Enum.map(moving, &{&1, %{&1 | category_uuid: nil, catalogue_uuid: category.catalogue_uuid}})

  defp disposition_pairs(moving, {:move_to, target_uuid}, category) do
    Enum.map(
      moving,
      &{&1, %{&1 | category_uuid: target_uuid, catalogue_uuid: category.catalogue_uuid}}
    )
  end

  defp disposition_pairs(_moving, _disposition, _category), do: []

  defp apply_item_disposition(:cascade, subtree, category, now) do
    {count, _} =
      from(i in Item,
        where: i.category_uuid in ^subtree and i.status != "deleted"
      )
      |> Trash.stamp_trashed("category", category.uuid, now)
      |> repo().update_all([])

    {:ok, count}
  end

  defp apply_item_disposition(:uncategorize, subtree, category, now) do
    {count, _} =
      from(i in Item,
        where: i.category_uuid in ^subtree and i.status != "deleted"
      )
      |> repo().update_all(
        set: [category_uuid: nil, catalogue_uuid: category.catalogue_uuid, updated_at: now]
      )

    {:ok, count}
  end

  defp apply_item_disposition({:move_to, target_uuid}, subtree, category, now) do
    case Helpers.get_by_uuid(Category, target_uuid) do
      nil ->
        {:error, :move_target_not_found}

      # Moving live items into a trashed category would hide them.
      %Category{status: "deleted"} ->
        {:error, :move_target_not_found}

      %Category{catalogue_uuid: target_cat_uuid}
      when target_cat_uuid != category.catalogue_uuid ->
        {:error, :cross_catalogue_move}

      %Category{uuid: ^target_uuid} = target ->
        # The picker hides the subtree, but a crafted target inside it
        # would reparent items onto a category this same transaction then
        # deletes — leaving live items in a deleted category.
        if in_subtree?(target.uuid, subtree) do
          {:error, :move_target_in_subtree}
        else
          {count, _} =
            from(i in Item,
              where: i.category_uuid in ^subtree and i.status != "deleted"
            )
            |> repo().update_all(
              set: [
                category_uuid: target.uuid,
                catalogue_uuid: target.catalogue_uuid,
                updated_at: now
              ]
            )

          {:ok, count}
        end
    end
  end

  # `Tree.subtree_uuids/1` returns raw 16-byte binaries; loaded rows
  # carry the textual form.
  defp in_subtree?(textual_uuid, subtree) do
    case Ecto.UUID.dump(textual_uuid) do
      {:ok, dumped} -> dumped in subtree
      :error -> false
    end
  end

  defp disposition_to_metadata(:cascade), do: "cascade"
  defp disposition_to_metadata(:uncategorize), do: "uncategorize"
  defp disposition_to_metadata({:move_to, uuid}), do: "move_to:#{uuid}"

  @doc """
  Restores a soft-deleted category, and with it exactly what
  `trash_category/2` took: the descendant categories and the items
  stamped as taken by THIS category, each back to the status it had.

  - **Refuses with `{:error, :parent_catalogue_deleted}`** when the
    catalogue is deleted — restore the catalogue first.
  - Rows trashed on their own (a descendant category, an item), rows a
    different trash took, and deleted rows with no stamp (they predate
    provenance) stay in the trash. So restoring a leaf of a trashed
    subtree brings back only that leaf, which `list_category_tree/2`
    orphan-promotes to a root while its ancestors stay trashed.
  - An item whose own category is still trashed after the pass stays in
    the trash, so no live item sits in a trashed category.
  - Items that an `:uncategorize` / `{:move_to, _}` trash moved out stay
    where they were moved — those dispositions are not undone.

  A category that is not deleted is returned unchanged. Logs
  `category.restored` with `descendants_restored` and `items_restored`.

  ## Examples

      {:ok, _} = Catalogue.restore_category(category)
      {:error, :parent_catalogue_deleted} =
        Catalogue.restore_category(category_under_deleted_catalogue)
  """
  @spec restore_category(Category.t(), keyword()) ::
          {:ok, Category.t()}
          | {:error, :parent_catalogue_deleted | :not_found | term()}
  def restore_category(%Category{} = category, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        fresh = Trash.lock_row_in_catalogue!(Category, category.uuid)

        if Shared.catalogue_deleted?(fresh.catalogue_uuid),
          do: repo().rollback(:parent_catalogue_deleted)

        if fresh.status == "deleted",
          do: {:restored, do_restore_category(fresh)},
          else: {:unchanged, {fresh, 0, 0}}
      end)

    case result do
      {:ok, {:restored, {updated, categories_restored, items_restored}}} ->
        Shared.log_activity(%{
          action: "category.restored",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: updated.uuid,
          parent_catalogue_uuid: updated.catalogue_uuid,
          metadata: %{
            "name" => updated.name,
            "catalogue_uuid" => updated.catalogue_uuid,
            "descendants_restored" => categories_restored,
            "items_restored" => items_restored
          }
        })

        {:ok, updated}

      {:ok, {:unchanged, {fresh, _, _}}} ->
        {:ok, fresh}

      error ->
        error
    end
  end

  defp do_restore_category(%Category{uuid: root}) do
    now = DateTime.utc_now()
    subtree = Tree.subtree_uuids(root)
    Trash.lock_categories!(subtree)

    from(c in Category, where: c.uuid == ^root)
    |> Trash.restore_trashed(:category, now)
    |> repo().update_all([])

    {categories_restored, _} =
      from(c in Category,
        where: c.uuid in ^subtree and c.uuid != ^root and c.status == "deleted"
      )
      |> Trash.trashed_by(root)
      |> Trash.restore_trashed(:category, now)
      |> repo().update_all([])

    stamped_items =
      from(i in Item, as: :item, where: i.category_uuid in ^subtree and i.status == "deleted")
      |> Trash.trashed_by(root)

    {items_restored, _} =
      stamped_items
      |> Trash.outside_trashed_categories()
      |> Trash.restore_trashed(:item, now)
      |> repo().update_all([])

    Trash.restamp_left_behind!(stamped_items)

    {repo().get!(Category, root), categories_restored, items_restored}
  end

  @doc """
  Permanently deletes a category and its subtree from the database.

  A **live** category takes its entire subtree: every descendant category
  and every item in any of them. A **trashed** category takes only the
  trashed part: the trashed descendants reached without passing through a
  live one, and the items in those categories. A live subcategory under it
  (one restored on its own, which the Active tab already shows at the top
  level) is kept with its own subtree and moves to the end of the top level.
  Trashed rows under a kept subcategory that the removed categories' trash
  took are re-stamped to a root that still exists, so a Restore can bring
  them back together (see `dev_docs/guides/trash-and-restore.md`).

  Pass `only_trashed: true` from a Deleted-tab action: the call then
  refuses with `{:error, :not_in_trash}` when the category, re-read under
  the lock, is no longer trashed (restored in another tab meanwhile).

  Runs in one transaction. This cannot be undone.
  """
  @spec permanently_delete_category(Category.t(), keyword()) ::
          {:ok, Category.t()} | {:error, term()}
  def permanently_delete_category(%Category{} = category, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        fresh = Trash.lock_row_in_catalogue!(Category, category.uuid)

        if opts[:only_trashed] == true and fresh.status != "deleted",
          do: repo().rollback(:not_in_trash)

        subtree = Tree.subtree_uuids(fresh.uuid)
        # Locked before the item delete: an item created in or moved into
        # the subtree meanwhile waits on its category row and then fails
        # its foreign key, instead of surviving uncategorized through
        # `ON DELETE SET NULL`.
        Trash.lock_categories!(subtree)

        {doomed, kept} = permanent_delete_split(fresh, subtree)

        release =
          MediaFolders.release_plan([
            from(c in Category, where: c.uuid in ^doomed),
            from(i in Item, where: i.category_uuid in ^doomed)
          ])

        # A live subcategory kept from a trashed parent moves to the top
        # level, where the Active tab already lists it, after its last row.
        # Its folder goes with it while its old parent still exists.
        moving = MediaFolders.moving_records(from(c in Category, where: c.uuid in ^kept))
        move_kept_to_top_level(fresh.catalogue_uuid, kept)

        moving
        |> Enum.map(&{&1, %{&1 | parent_uuid: nil}})
        |> MediaFolders.follow(opts[:actor_uuid])

        restamp_orphaned_trash(fresh.catalogue_uuid, subtree, doomed, kept)

        {items_cascaded, _} =
          from(i in Item, where: i.category_uuid in ^doomed)
          |> repo().delete_all()

        # V103's self-FK on parent_uuid has no ON DELETE CASCADE — a
        # straight `delete_all` would reject any parent row while its
        # children still reference it. Every row in `doomed` is being
        # deleted anyway, so NULL out parent_uuid first to break the
        # FKs between them, then delete in one shot.
        from(c in Category, where: c.uuid in ^doomed)
        |> repo().update_all(set: [parent_uuid: nil])

        from(c in Category, where: c.uuid in ^doomed)
        |> repo().delete_all()

        {length(doomed), items_cascaded, length(kept), release}
      end)

    case result do
      {:ok, {subtree_size, items_cascaded, kept_count, release}} ->
        MediaFolders.release(release)

        Shared.log_activity(%{
          action: "category.permanently_deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          parent_catalogue_uuid: category.catalogue_uuid,
          metadata: %{
            "name" => category.name,
            "catalogue_uuid" => category.catalogue_uuid,
            "subtree_size" => subtree_size,
            "items_cascaded" => items_cascaded,
            "kept_live_subcategories" => kept_count
          }
        })

        {:ok, category}

      error ->
        error
    end
  end

  @doc """
  What `permanently_delete_category/2` would remove, without removing it:
  `%{subcategories: n, items: m}`, the categories below the given one and
  the items in all of them. For a trashed category this includes rows that
  were trashed on their own before it, which its Restore does not bring
  back and its card does not count, so a Delete Forever confirmation can
  say what is really destroyed.
  """
  @spec permanent_delete_scope(Category.t()) :: %{
          subcategories: non_neg_integer(),
          items: non_neg_integer()
        }
  def permanent_delete_scope(%Category{} = category) do
    case repo().get(Category, category.uuid) do
      nil ->
        %{subcategories: 0, items: 0}

      fresh ->
        {doomed, _kept} = permanent_delete_split(fresh, Tree.subtree_uuids(fresh.uuid))
        items = from(i in Item, where: i.category_uuid in ^doomed) |> repo().aggregate(:count)
        %{subcategories: max(length(doomed) - 1, 0), items: items}
    end
  end

  # What a permanent delete removes. A live root takes its whole subtree; a
  # trashed root takes the trashed categories reached from it without
  # crossing a live one, and returns the live children it stops at.
  defp permanent_delete_split(%Category{status: "deleted", uuid: root}, subtree) do
    children =
      from(c in Category, where: c.uuid in ^subtree, select: {c.uuid, c.parent_uuid, c.status})
      |> repo().all()
      |> Enum.group_by(&elem(&1, 1))

    walk_trashed([root], children, [], [])
  end

  defp permanent_delete_split(_live_root, subtree), do: {subtree, []}

  defp walk_trashed([], _children, doomed, kept), do: {doomed, kept}

  defp walk_trashed([uuid | rest], children, doomed, kept) do
    {trashed, live} =
      children
      |> Map.get(uuid, [])
      |> Enum.split_with(fn {_uuid, _parent, status} -> status == "deleted" end)

    walk_trashed(
      Enum.map(trashed, &elem(&1, 0)) ++ rest,
      children,
      [uuid | doomed],
      Enum.map(live, &elem(&1, 0)) ++ kept
    )
  end

  defp move_kept_to_top_level(_catalogue_uuid, []), do: :ok

  defp move_kept_to_top_level(catalogue_uuid, kept) do
    first = next_category_position(catalogue_uuid, nil)

    from(c in Category, where: c.uuid in ^kept, order_by: [c.position, c.uuid], select: c.uuid)
    |> repo().all()
    |> Enum.with_index(first)
    |> Enum.each(fn {uuid, position} ->
      from(c in Category, where: c.uuid == ^uuid)
      |> repo().update_all(set: [parent_uuid: nil, position: position])
    end)
  end

  # The rows under a kept subcategory that the removed categories' trash
  # took still name one of them as their root, so no Restore would bring
  # them back together. Each takes the root its nearest trashed parent has
  # (the topmost trashed category on its path becomes its own root), and an
  # item in a live category becomes trashed on its own. `from_status` stays.
  defp restamp_orphaned_trash(_catalogue_uuid, _subtree, _doomed, []), do: :ok

  defp restamp_orphaned_trash(catalogue_uuid, subtree, doomed, _kept),
    do: restamp_trash_roots(catalogue_uuid, subtree, doomed)

  # A moved subtree can carry trashed rows stamped with a root the move
  # takes them out from under — a category restored on its own while its
  # trashed ancestor stays in the bin, then moved. That root's Restore
  # walks its current subtree and would never reach them again, so they
  # are restamped the way Delete Forever restamps what it leaves behind.
  # `covering` are the roots still above the landing spot (its catalogue
  # and ancestors); a stamp naming one of them, or a row of the subtree
  # itself, still works and is left alone. Call it after the move.
  defp restamp_moved_trash!(catalogue_uuid, subtree, covering) do
    subtree = Enum.map(subtree, &uuid_string/1)
    keep = MapSet.new(subtree ++ Enum.map(covering, &uuid_string/1))

    category_roots =
      from(c in Category,
        where: c.uuid in ^subtree and c.status == "deleted",
        select: fragment("? #>> '{_trash,root}'", c.data)
      )

    item_roots =
      from(i in Item,
        where: i.category_uuid in ^subtree and i.status == "deleted",
        select: fragment("? #>> '{_trash,root}'", i.data)
      )

    doomed =
      category_roots
      |> union(^item_roots)
      |> repo().all()
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(keep, &1)))

    if doomed != [], do: restamp_trash_roots(catalogue_uuid, subtree, doomed)
    :ok
  end

  defp restamp_trash_roots(catalogue_uuid, subtree, doomed) do
    doomed_set = MapSet.new(doomed)
    remaining = Enum.reject(subtree, &MapSet.member?(doomed_set, &1))

    info =
      from(c in Category,
        where: c.uuid in ^remaining,
        select: {c.uuid, {c.parent_uuid, c.status, fragment("? #>> '{_trash,root}'", c.data)}}
      )
      |> repo().all()
      |> Map.new()

    trashed = for {uuid, {_parent, "deleted", _root}} <- info, do: uuid
    live = for {uuid, {_parent, status, _root}} <- info, status != "deleted", do: uuid

    trashed
    |> Enum.group_by(&current_trash_root(&1, info, doomed_set, map_size(info)))
    |> Enum.each(fn {root, categories} ->
      via = if root == catalogue_uuid, do: "catalogue", else: "category"

      from(c in Category, where: c.uuid == ^root)
      |> orphaned_by(doomed)
      |> restamp_trash_self()
      |> repo().update_all([])

      from(c in Category, where: c.uuid in ^categories and c.uuid != ^root)
      |> orphaned_by(doomed)
      |> restamp_trash(via, root)
      |> repo().update_all([])

      from(i in Item, where: i.category_uuid in ^categories and i.status == "deleted")
      |> orphaned_by(doomed)
      |> restamp_trash(via, root)
      |> repo().update_all([])
    end)

    from(i in Item, where: i.category_uuid in ^live and i.status == "deleted")
    |> orphaned_by(doomed)
    |> restamp_trash_self()
    |> repo().update_all([])

    :ok
  end

  # The root a trashed category's row answers to once `doomed` is gone: its
  # own stamp's root when that survives (the category itself when unstamped),
  # otherwise its trashed parent's, otherwise itself. `fuel` stops a cycle.
  defp current_trash_root(uuid, info, doomed, fuel) do
    {parent, _status, root} = Map.fetch!(info, uuid)

    cond do
      is_nil(root) ->
        uuid

      not MapSet.member?(doomed, root) ->
        root

      fuel > 0 and match?({_, "deleted", _}, Map.get(info, parent)) ->
        current_trash_root(parent, info, doomed, fuel - 1)

      true ->
        uuid
    end
  end

  defp orphaned_by(query, doomed) do
    where(
      query,
      [r],
      fragment("(? #>> '{_trash,root}') = ANY(?)", r.data, type(^doomed, {:array, :string}))
    )
  end

  defp restamp_trash(query, via, root_uuid) do
    update(query, [r],
      set: [
        data:
          fragment(
            "jsonb_set(jsonb_set(?, '{_trash,via}', to_jsonb(?::text)), '{_trash,root}', to_jsonb(?::text))",
            r.data,
            ^via,
            ^to_string(root_uuid)
          )
      ]
    )
  end

  defp restamp_trash_self(query) do
    update(query, [r],
      set: [
        data:
          fragment(
            "jsonb_set(jsonb_set(?, '{_trash,via}', to_jsonb('self'::text)), '{_trash,root}', to_jsonb(?::text))",
            r.data,
            r.uuid
          )
      ]
    )
  end

  @doc """
  Moves a category — along with its entire subtree and every item
  inside — to a different catalogue.

  The moved category's `parent_uuid` is cleared (it detaches from its
  former parent, which stays in the source catalogue) and it takes the
  next available root-level position in the target — or, with
  `parent_uuid:`, the next position under that category of the target
  catalogue. Internal parent links inside the moved subtree are
  preserved.

  Refuses a trashed category (`:not_found`), a missing or trashed
  target catalogue (`:catalogue_not_found`), a target of the other kind
  (`:kind_mismatch` — standard and smart items price differently), and
  a `parent_uuid:` that is missing, trashed or in another catalogue
  (`:parent_not_found`) or inside the moved subtree
  (`:would_create_cycle`). Both catalogues are told about the move.

  With `catalogue_uuid:`, a category that is no longer in that catalogue
  when its row is locked is refused (`:wrong_catalogue_scope`).

  ## Examples

      {:ok, moved} = Catalogue.move_category_to_catalogue(category, target_catalogue_uuid)
      {:ok, moved} = Catalogue.move_category_to_catalogue(category, target, parent_uuid: parent)
  """
  @spec move_category_to_catalogue(Category.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Category.t()} | {:error, term()}
  def move_category_to_catalogue(%Category{} = category, target_catalogue_uuid, opts \\ []) do
    parent_uuid = opts[:parent_uuid]

    cond do
      not Shared.valid_uuid?(target_catalogue_uuid) -> {:error, :catalogue_not_found}
      not (is_nil(parent_uuid) or Shared.valid_uuid?(parent_uuid)) -> {:error, :parent_not_found}
      true -> do_move_category_to_catalogue(category, target_catalogue_uuid, parent_uuid, opts)
    end
  end

  defp do_move_category_to_catalogue(category, target_catalogue_uuid, parent_uuid, opts) do
    result =
      Trash.locked_transaction(fn ->
        # Both catalogues' trash/restore locks first, in sorted order: a
        # trash or restore in either one otherwise deadlocks against this
        # move, each holding a row the other updates next.
        source_catalogue_uuid =
          repo().one(
            from(c in Category, where: c.uuid == ^category.uuid, select: c.catalogue_uuid)
          ) ||
            repo().rollback(:not_found)

        Trash.lock_catalogues!([source_catalogue_uuid, target_catalogue_uuid])

        # Take an exclusive row lock on the category being moved. This
        # serializes concurrent `create_item`/`update_item` calls that
        # read the same category via `FOR SHARE` in
        # `put_catalogue_from_effective_category/2`: while we hold the
        # lock they block, and once we commit they read the new
        # `catalogue_uuid`. No item can slip in with a stale
        # `catalogue_uuid` between our items-update and our commit.
        locked =
          repo().one!(from(c in Category, where: c.uuid == ^category.uuid, lock: "FOR UPDATE"))

        check_move_source!(locked, source_catalogue_uuid, opts[:catalogue_uuid])

        # Read under both locks, so a trash of the target cannot land
        # between this check and the commit.
        Shared.check_move_destination!(source_catalogue_uuid, target_catalogue_uuid)

        subtree = lock_subtree!(category.uuid)
        if parent_uuid, do: check_move_parent!(parent_uuid, target_catalogue_uuid, subtree)
        now = DateTime.utc_now()

        {items_updated, _} =
          from(i in Item, where: i.category_uuid in ^subtree)
          |> repo().update_all(set: [catalogue_uuid: target_catalogue_uuid, updated_at: now])

        # Reparent the whole subtree to the target catalogue in a
        # single query — internal parent_uuids stay intact because
        # they still reference rows in the subtree.
        {categories_updated, _} =
          from(c in Category, where: c.uuid in ^subtree)
          |> repo().update_all(set: [catalogue_uuid: target_catalogue_uuid, updated_at: now])

        restamp_moved_trash!(
          target_catalogue_uuid,
          subtree,
          [target_catalogue_uuid | parent_and_ancestors(parent_uuid)]
        )

        # Position is computed inside the transaction (after the
        # subtree has moved) to avoid the same-`max_position` race
        # called out in prior PR reviews.
        next_pos = next_category_position(target_catalogue_uuid, parent_uuid)

        moved =
          locked
          |> Category.changeset(%{
            catalogue_uuid: target_catalogue_uuid,
            parent_uuid: parent_uuid,
            position: next_pos
          })
          |> repo().update!()

        {moved, categories_updated, items_updated, source_catalogue_uuid, locked.parent_uuid}
      end)

    case result do
      {:ok, {moved, categories_updated, items_updated, source_catalogue_uuid, from_parent_uuid}} ->
        Shared.log_activity(
          %{
            action: "category.moved",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "category",
            resource_uuid: moved.uuid,
            parent_catalogue_uuid: target_catalogue_uuid,
            metadata: %{
              "name" => moved.name,
              "subtree_size" => categories_updated,
              "items_cascaded" => items_updated,
              "changes" =>
                ActivityLog.changes([
                  {:catalogue, Shared.catalogue_ref(source_catalogue_uuid),
                   Shared.catalogue_ref(target_catalogue_uuid)},
                  {:parent, Shared.category_ref(from_parent_uuid),
                   Shared.category_ref(parent_uuid)}
                ])
            }
          },
          Keyword.take(opts, [:broadcast, :mode])
        )

        # The activity broadcast names the target; pages open on the
        # source lost a subtree and its items and must reload too.
        if source_catalogue_uuid != target_catalogue_uuid and Keyword.get(opts, :broadcast, true),
          do: broadcast_moved_out(source_catalogue_uuid)

        before = %{moved | catalogue_uuid: source_catalogue_uuid, parent_uuid: from_parent_uuid}
        MediaFolders.follow([{before, moved}], opts[:actor_uuid])
        {:ok, moved}

      error ->
        error
    end
  end

  # Every category of the moving subtree, row-locked before any item is
  # touched. Creating, updating or moving an item reads its category
  # `FOR SHARE`, so it either finishes first — and the item update below
  # then carries it along — or waits and reads the new catalogue. With
  # only the root locked, an item could land in a subcategory under the
  # old catalogue, or deadlock against the item update (review finding).
  # Re-read until the subtree stops changing under the locks.
  defp lock_subtree!(root_uuid, attempts \\ 3) do
    subtree = Tree.subtree_uuids(root_uuid)
    Trash.lock_categories!(subtree)

    cond do
      Enum.sort(Tree.subtree_uuids(root_uuid)) == Enum.sort(subtree) -> subtree
      attempts > 1 -> lock_subtree!(root_uuid, attempts - 1)
      true -> repo().rollback(:catalogue_moved)
    end
  end

  defp broadcast_moved_out(catalogue_uuid) do
    PubSub.broadcast(:category, nil, catalogue_uuid)
    PubSub.broadcast(:item, nil, catalogue_uuid)
  end

  # A parent in the destination: live, in that catalogue, and not a
  # member of the subtree being moved (the subtree carries raw uuids).
  # `FOR SHARE` holds it against a concurrent trash until commit.
  defp check_move_parent!(parent_uuid, catalogue_uuid, subtree) do
    case repo().one(from(c in Category, where: c.uuid == ^parent_uuid, lock: "FOR SHARE")) do
      %Category{status: status, catalogue_uuid: ^catalogue_uuid} when status != "deleted" ->
        {:ok, raw} = Ecto.UUID.dump(parent_uuid)
        if raw in subtree, do: repo().rollback(:would_create_cycle), else: :ok

      _ ->
        repo().rollback(:parent_not_found)
    end
  end

  @doc """
  Reparents a category within the same catalogue, placing it under
  `new_parent_uuid` (or promoting it to a root with `nil`).

  Rejects moves that would:
    * produce a cycle (`new_parent_uuid` is the category itself or one
      of its descendants) — returns `{:error, :would_create_cycle}`
    * cross a catalogue boundary — returns `{:error, :cross_catalogue}`.
      Callers who want that should run `move_category_to_catalogue/3`
      first, then reparent.
    * target a missing or trashed parent — returns `{:error, :parent_not_found}`
    * move a trashed category — returns `{:error, :not_found}`

  The moved category takes the next-available position among its new
  siblings. Its subtree comes along untouched (parent links inside the
  subtree stay valid).

  Passing `new_parent_uuid = nil` promotes the category to a root within
  its current catalogue.

  ## Examples

      {:ok, moved} = Catalogue.move_category_under(child, parent.uuid)
      {:ok, moved} = Catalogue.move_category_under(child, nil)  # promote to root
  """
  @spec move_category_under(Category.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Category.t()}
          | {:error,
             :would_create_cycle
             | :cross_catalogue
             | :parent_not_found
             | :not_found
             | :catalogue_moved
             | Ecto.Changeset.t(Category.t())}
  def move_category_under(category, new_parent_uuid, opts \\ [])

  def move_category_under(%Category{parent_uuid: same} = category, same, _opts)
      when is_binary(same) or is_nil(same),
      do: {:ok, category}

  def move_category_under(%Category{} = category, nil, opts),
    do: do_move_category_under(category, nil, opts)

  def move_category_under(%Category{} = category, new_parent_uuid, opts)
      when is_binary(new_parent_uuid) do
    cond do
      new_parent_uuid == category.uuid -> {:error, :would_create_cycle}
      not Shared.valid_uuid?(new_parent_uuid) -> {:error, :parent_not_found}
      true -> do_move_category_under(category, new_parent_uuid, opts)
    end
  end

  # Runs the checks, the position calc and the update in one transaction
  # under the catalogue lock plus `FOR UPDATE` on the moved row, so it
  # serialises with every trash/restore path (a category trashed a moment
  # ago is refused, not revived as a live child of a live parent) and
  # with a concurrent reparent: two reparents that would jointly create a
  # cycle — the second one re-runs `Tree.subtree_uuids/1` against the
  # post-commit tree and gets `:would_create_cycle`.
  defp do_move_category_under(category, new_parent_uuid, opts) do
    result =
      Trash.locked_transaction(fn ->
        catalogue_uuid =
          repo().one(
            from(c in Category, where: c.uuid == ^category.uuid, select: c.catalogue_uuid)
          ) || repo().rollback(:not_found)

        lock_catalogue!(catalogue_uuid)

        locked =
          repo().one!(from(c in Category, where: c.uuid == ^category.uuid, lock: "FOR UPDATE"))

        cond do
          locked.catalogue_uuid != catalogue_uuid ->
            repo().rollback(:catalogue_moved)

          locked.status == "deleted" ->
            repo().rollback(:not_found)

          new_parent_uuid && cycle?(new_parent_uuid, locked.uuid) ->
            repo().rollback(:would_create_cycle)

          true ->
            moved = run_locked_reparent(locked, new_parent_uuid)

            restamp_moved_trash!(
              catalogue_uuid,
              Tree.subtree_uuids(locked.uuid),
              [catalogue_uuid | parent_and_ancestors(new_parent_uuid)]
            )

            moved
        end
      end)

    with {:ok, {moved, from_parent_uuid}} <- result do
      Shared.log_activity(
        %{
          action: "category.moved",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: moved.uuid,
          parent_catalogue_uuid: moved.catalogue_uuid,
          metadata: %{
            "name" => moved.name,
            "catalogue_uuid" => moved.catalogue_uuid,
            "changes" =>
              ActivityLog.changes([
                {:parent, Shared.category_ref(from_parent_uuid),
                 Shared.category_ref(new_parent_uuid)}
              ])
          }
        },
        Keyword.take(opts, [:broadcast, :mode])
      )

      MediaFolders.follow([{%{moved | parent_uuid: from_parent_uuid}, moved}], opts[:actor_uuid])
      {:ok, moved}
    end
  end

  # `opts[:catalogue_uuid]`, when given, is a scope: a category outside it
  # is refused (`:wrong_catalogue_scope`) — the uuids come from the client.
  defp move_one_category(uuid, new_parent_uuid, opts) do
    scope = opts[:catalogue_uuid]

    case get_category(uuid) do
      nil ->
        {:error, :not_found}

      %Category{catalogue_uuid: c} when is_binary(scope) and c != scope ->
        {:error, :wrong_catalogue_scope}

      category ->
        move_category_under(category, new_parent_uuid, opts)
    end
  end

  @doc """
  Re-parents several categories at once — under `new_parent_uuid`, or to
  the root of their catalogue when it is `nil`. Each move is
  `move_category_under/3` with its own guards (cycles, cross-catalogue,
  missing parent); one refusal does not stop the others. Per-move
  broadcasts are muted and ONE `:category` batch event per touched
  catalogue is emitted after the loop, so every open page reloads once.

  Pass `catalogue_uuid:` to refuse categories outside that catalogue
  (`:wrong_catalogue_scope`) — the uuids are client-captured.

  Returns `{:ok, %{moved: n, errors: [{uuid, reason}]}}`.
  """
  @spec bulk_move_categories_under([Ecto.UUID.t()], Ecto.UUID.t() | nil, keyword()) ::
          {:ok, %{moved: non_neg_integer(), errors: [{Ecto.UUID.t(), term()}]}}
  def bulk_move_categories_under(uuids, new_parent_uuid, opts \\ []) when is_list(uuids) do
    muted = Keyword.put(opts, :broadcast, false)

    {moved, errors, catalogues} =
      Enum.reduce(uuids, {0, [], MapSet.new()}, fn uuid, {moved, errors, cats} ->
        case move_one_category(uuid, new_parent_uuid, muted) do
          {:ok, m} -> {moved + 1, errors, MapSet.put(cats, m.catalogue_uuid)}
          {:error, reason} -> {moved, [{uuid, reason} | errors], cats}
        end
      end)

    if moved > 0 and Keyword.get(opts, :broadcast, true) do
      Enum.each(catalogues, &PubSub.broadcast(:category, nil, &1))
    end

    {:ok, %{moved: moved, errors: Enum.reverse(errors)}}
  end

  # Loads a raw 16-byte binary UUID from a Tree CTE result back into the
  # textual `xxxxxxxx-xxxx-...` form, falling back to the raw input if
  # it isn't a valid UUID. Used by `list_category_tree/2`'s
  # `:exclude_subtree_of` membership test (loaded `Category` rows carry
  # textual UUIDs).
  defp check_move_source!(locked, source_catalogue_uuid, scope) do
    cond do
      locked.catalogue_uuid != source_catalogue_uuid -> repo().rollback(:catalogue_moved)
      locked.status == "deleted" -> repo().rollback(:not_found)
      # A client-captured selection is checked where the row is locked:
      # moved to another catalogue since the page read it, it is not this
      # page's to move any more.
      scope && scope != source_catalogue_uuid -> repo().rollback(:wrong_catalogue_scope)
      true -> :ok
    end
  end

  # `Tree` returns raw 16-byte uuids; stamps hold the string form.
  defp uuid_string(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp uuid_string(uuid), do: uuid

  defp parent_and_ancestors(nil), do: []
  defp parent_and_ancestors(uuid), do: [uuid | Tree.ancestor_uuids(uuid)]

  defp load_uuid(raw) do
    case Ecto.UUID.load(raw) do
      {:ok, str} -> str
      :error -> raw
    end
  end

  defp run_locked_reparent(category, nil), do: reparent!(category, nil)

  # `FOR SHARE` holds the parent against a concurrent trash until commit;
  # a trashed parent would hide the moved subtree from every tree.
  defp run_locked_reparent(category, new_parent_uuid) do
    case repo().one(from(c in Category, where: c.uuid == ^new_parent_uuid, lock: "FOR SHARE")) do
      nil ->
        repo().rollback(:parent_not_found)

      %Category{status: "deleted"} ->
        repo().rollback(:parent_not_found)

      %Category{catalogue_uuid: other} when other != category.catalogue_uuid ->
        repo().rollback(:cross_catalogue)

      %Category{} ->
        reparent!(category, new_parent_uuid)
    end
  end

  defp reparent!(category, new_parent_uuid) do
    from_parent_uuid = category.parent_uuid
    next_pos = next_category_position(category.catalogue_uuid, new_parent_uuid)

    case category
         |> Category.changeset(%{parent_uuid: new_parent_uuid, position: next_pos})
         |> repo().update() do
      {:ok, moved} -> {moved, from_parent_uuid}
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  @doc """
  Atomically swaps the positions of two categories within a transaction.

  Positions are scoped to `(catalogue_uuid, parent_uuid)` sibling
  groups (V103). Swapping positions of categories that are not
  siblings would mix two independent ordering axes, so this function
  refuses with `{:error, :not_siblings}` when the categories live
  under different parents or in different catalogues. The detail-view
  reorder buttons enforce the same constraint at the LV level; this
  is the context-level guard for any programmatic caller.

  ## Examples

      {:ok, _} = Catalogue.swap_category_positions(cat_a, cat_b)
      {:error, :not_siblings} = Catalogue.swap_category_positions(root, child)
  """
  @spec swap_category_positions(Category.t(), Category.t(), keyword()) ::
          {:ok, term()} | {:error, :not_siblings | term()}
  def swap_category_positions(%Category{} = cat_a, %Category{} = cat_b, opts \\ []) do
    if cat_a.catalogue_uuid != cat_b.catalogue_uuid or
         cat_a.parent_uuid != cat_b.parent_uuid do
      {:error, :not_siblings}
    else
      do_swap_category_positions(cat_a, cat_b, opts)
    end
  end

  defp do_swap_category_positions(cat_a, cat_b, opts) do
    result =
      repo().transaction(fn ->
        # Take FOR UPDATE on both rows before reading their positions so
        # two concurrent swaps with overlapping siblings serialise. The
        # first transaction commits its swap; the second re-reads the
        # post-commit positions and writes the correct values, instead
        # of computing both positions off pre-commit reads and producing
        # duplicates.
        # Locked in uuid order, like every other multi-row category lock, so
        # two swaps over the same pair (or a swap and a subtree trash)
        # cannot deadlock.
        locked =
          from(c in Category,
            where: c.uuid in ^[cat_a.uuid, cat_b.uuid],
            order_by: c.uuid,
            lock: "FOR UPDATE"
          )
          |> repo().all()
          |> Map.new(&{&1.uuid, &1})

        a = Map.fetch!(locked, cat_a.uuid)
        b = Map.fetch!(locked, cat_b.uuid)

        a |> Category.changeset(%{position: b.position}) |> repo().update!()
        b |> Category.changeset(%{position: a.position}) |> repo().update!()
      end)

    with {:ok, _} <- result do
      Shared.log_activity(%{
        action: "category.positions_swapped",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "category",
        resource_uuid: cat_a.uuid,
        parent_catalogue_uuid: cat_a.catalogue_uuid,
        metadata: %{
          "category_a_uuid" => cat_a.uuid,
          "category_a_name" => cat_a.name,
          "category_b_uuid" => cat_b.uuid,
          "category_b_name" => cat_b.name
        }
      })

      result
    end
  end

  @doc "Returns a changeset for tracking category changes."
  @spec change_category(Category.t(), map()) :: Ecto.Changeset.t(Category.t())
  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

  @doc """
  Returns the list of ancestor categories from root down to (but not
  including) `category_uuid`. Empty when the category is a root.
  Useful for breadcrumbs.
  """
  @spec list_category_ancestors(Ecto.UUID.t()) :: [Category.t()]
  defdelegate list_category_ancestors(category_uuid), to: Tree, as: :ancestors_in_order

  @doc """
  Returns the uuids of `category_uuids` and every category below them,
  trashed rows included, as text. A move or trash picker prunes these:
  a live category under a trashed one is still in the subtree, which a
  tree of live rows alone cannot see (it shows such a row at the top).
  Strings that are not UUIDs are ignored.
  """
  @spec category_subtree_uuids([String.t()]) :: [Ecto.UUID.t()]
  def category_subtree_uuids(category_uuids) when is_list(category_uuids) do
    category_uuids
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> Tree.subtree_uuids_for()
    |> Enum.map(&load_uuid/1)
  end

  @doc """
  Returns same-catalogue active categories that can receive items from
  a category about to be deleted (the category itself and its V103
  descendants are excluded). Used by the admin "delete category" modal
  to populate the move-target dropdown.

  Each entry is `{category, depth}`, depth-first order — the same shape
  `list_category_tree/2` returns so callers can render the same indent
  rules.
  """
  @spec list_move_target_categories(Category.t()) :: [{Category.t(), non_neg_integer()}]
  def list_move_target_categories(%Category{} = category) do
    # `Tree.subtree_uuids/1` returns raw 16-byte binaries; `list_category_tree/2`
    # returns Ecto-loaded categories whose `:uuid` is the textual form.
    # Normalise both to text via `load_uuid/1` so the membership check fires.
    subtree =
      category.uuid
      |> Tree.subtree_uuids()
      |> Enum.map(&load_uuid/1)
      |> MapSet.new()

    category.catalogue_uuid
    |> list_category_tree(mode: :active)
    |> Enum.reject(fn {cat, _depth} -> MapSet.member?(subtree, cat.uuid) end)
  end

  @doc """
  Returns the categories in a catalogue paired with their tree depth,
  in depth-first display order (position, then name, recursing into
  children). Each entry is `{category, depth}` where depth `0` means a
  root. Used to render flat parent-pickers and indented listings.

  ## Options

    * `:mode` — `:active` (default, excludes deleted categories) or
      `:deleted` (all statuses — the detail view in deleted mode still
      wants deleted categories that contain trashed items).
    * `:exclude_subtree_of` — skip a category and all its descendants
      (e.g. the category being edited — you can't parent it under
      itself or its descendants).
  """
  @spec list_category_tree(Ecto.UUID.t(), keyword()) :: [{Category.t(), non_neg_integer()}]
  def list_category_tree(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    # Plain list (not MapSet) because the exclude subtree is typically
    # a single branch (order of 1–20 uuids) and keeping a list here
    # lets dialyzer type-check the `in` check without tripping on
    # MapSet's opaque struct.
    # `Tree.subtree_uuids/1` returns raw 16-byte binaries; loaded
    # `Category` rows carry textual UUIDs. Normalise both sides via
    # `Ecto.UUID.load/1` so the membership test actually fires.
    exclude_uuids =
      case Keyword.get(opts, :exclude_subtree_of) do
        nil -> []
        uuid -> uuid |> Tree.subtree_uuids() |> Enum.map(&load_uuid/1)
      end

    normalized = normalized_category_rows(catalogue_uuid, mode, exclude_uuids)
    index = Tree.build_children_index(normalized)

    {acc, _} =
      Enum.reduce(Map.get(index, nil, []), {[], index}, fn root, {acc, idx} ->
        {collect_tree(root, idx, 0, acc), idx}
      end)

    Enum.reverse(acc)
  end

  @doc """
  The live (non-deleted) categories of several catalogues in one query,
  in `list_category_tree/2`'s sibling order (position, then name). The
  nesting is left to the caller through `parent_uuid` — for pickers that
  show many catalogues' trees at once, where one `list_category_tree/2`
  per catalogue would be a query each.
  """
  @spec list_live_categories([Ecto.UUID.t()]) :: [Category.t()]
  def list_live_categories([]), do: []

  def list_live_categories(catalogue_uuids) when is_list(catalogue_uuids) do
    from(c in Category,
      where: c.catalogue_uuid in ^catalogue_uuids and c.status != "deleted",
      order_by: [asc: :position, asc: :name]
    )
    |> repo().all()
  end

  defp collect_tree(%Category{} = cat, index, depth, acc) do
    acc = [{cat, depth} | acc]

    index
    |> Map.get(cat.uuid, [])
    |> Enum.reduce(acc, fn child, acc -> collect_tree(child, index, depth + 1, acc) end)
  end

  # Loads the catalogue's categories for `mode`, drops the excluded
  # subtree, and orphan-promotes rows whose parent is missing from the
  # set (deleted ancestor in :active mode, or excluded subtree) to roots
  # by rewriting `parent_uuid` to nil — so they never vanish from the UI.
  # Shared by `list_category_tree/2` and `list_child_categories/3` so the
  # drill-down's level view and the flat tree agree on what's a root.
  defp normalized_category_rows(catalogue_uuid, mode, exclude_uuids) do
    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        # uuid last: two siblings sharing a position and a name would
        # otherwise come back in either order, and a sort that keeps ties
        # in input order (or reverses them) would swap them between renders.
        order_by: [asc: :position, asc: :name, asc: :uuid]
      )

    query =
      case mode do
        :active -> where(query, [c], c.status != "deleted")
        :deleted -> query
      end

    categories =
      query
      |> repo().all()
      |> Enum.reject(&(&1.uuid in exclude_uuids))

    uuid_set = MapSet.new(categories, & &1.uuid)

    Enum.map(categories, fn c ->
      if c.parent_uuid == nil or MapSet.member?(uuid_set, c.parent_uuid) do
        c
      else
        %{c | parent_uuid: nil}
      end
    end)
  end

  @doc """
  Lists the categories shown at one drill level — the direct children of
  `parent_uuid` within the catalogue (`nil` = the root level).

  In `:active` mode (default) the result reuses `list_category_tree/2`'s
  orphan promotion: a category whose parent is deleted (e.g. a child
  restored under a still-trashed parent — `restore_category/2` does not
  cascade) surfaces at the root level so it stays reachable by
  drill-down. In `:deleted` mode it returns the strict set of *deleted*
  direct children (no promotion) — the deleted subtree is navigated by
  drilling into deleted parents.

  Ordered by `position` then `name`.
  """
  @spec list_child_categories(Ecto.UUID.t(), Ecto.UUID.t() | nil, keyword()) :: [Category.t()]
  def list_child_categories(catalogue_uuid, parent_uuid, opts \\ []) do
    case Keyword.get(opts, :mode, :active) do
      :active ->
        catalogue_uuid
        |> normalized_category_rows(:active, [])
        |> Enum.filter(&(&1.parent_uuid == parent_uuid))

      :deleted ->
        base =
          from(c in Category,
            where: c.catalogue_uuid == ^catalogue_uuid and c.status == "deleted",
            order_by: [asc: :position, asc: :name]
          )

        query =
          case parent_uuid do
            nil -> where(base, [c], is_nil(c.parent_uuid))
            uuid -> where(base, [c], c.parent_uuid == ^uuid)
          end

        repo().all(query)
    end
  end

  @doc """
  `%{parent_uuid => n}` of direct child categories per parent within a
  catalogue — the count form of `category_uuids_with_children/2`, for
  the detail table's optional Subcategories column.
  """
  @spec category_children_counts(Ecto.UUID.t(), keyword()) :: %{
          Ecto.UUID.t() => non_neg_integer()
        }
  def category_children_counts(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid and not is_nil(c.parent_uuid),
        group_by: c.parent_uuid,
        select: {c.parent_uuid, count(c.uuid)}
      )

    query =
      case mode do
        :active -> where(query, [c], c.status != "deleted")
        # The deleted view lists only deleted children, so its
        # Subcategories count must match — unfiltered it counted the
        # active children too (restore is non-cascading, so mixed
        # levels are normal).
        :deleted -> where(query, [c], c.status == "deleted")
      end

    query |> repo().all() |> Map.new()
  end

  @doc """
  Returns the set of category UUIDs (within the catalogue, in the given
  `:mode`) that have at least one child category — lets drill cards show
  a "has subcategories" affordance without an N+1 per card.
  """
  @spec category_uuids_with_children(Ecto.UUID.t(), keyword()) :: MapSet.t()
  def category_uuids_with_children(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid and not is_nil(c.parent_uuid),
        select: c.parent_uuid,
        distinct: true
      )

    query =
      case mode do
        :active -> where(query, [c], c.status != "deleted")
        # Match `category_children_counts/2`: restore is non-cascading,
        # so a deleted parent can have only-active children. The deleted
        # view's chevron must not light up for a child list that is empty.
        :deleted -> where(query, [c], c.status == "deleted")
      end

    query |> repo().all() |> MapSet.new()
  end

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

  # New categories append to their level: when the caller supplies no
  # position (the form dropped its Position field), compute max+1 for
  # the (catalogue, parent) level. Without this every new category
  # lands on the schema default 0 and collides with the manual order.
  # Handles string- and atom-keyed attrs without mixing key types
  # (mixed keys make Ecto.Changeset.cast/4 raise).
  defp put_default_category_position(attrs) do
    given = Map.get(attrs, :position) || Map.get(attrs, "position")
    catalogue_uuid = Map.get(attrs, :catalogue_uuid) || Map.get(attrs, "catalogue_uuid")

    if given in [nil, ""] and is_binary(catalogue_uuid) do
      parent_uuid =
        case Map.get(attrs, :parent_uuid) || Map.get(attrs, "parent_uuid") do
          "" -> nil
          parent -> parent
        end

      position = next_category_position(catalogue_uuid, parent_uuid)
      key = if Enum.any?(Map.keys(attrs), &is_binary/1), do: "position", else: :position
      Map.put(attrs, key, position)
    else
      attrs
    end
  end

  @doc """
  Returns the next available position for a new category among its
  siblings. Position is scoped to `(catalogue_uuid, parent_uuid)` — the
  set of categories sharing the same parent within a catalogue — since
  V103's nested-category tree makes a single catalogue-wide ordering
  ambiguous.

  `parent_uuid` defaults to `nil`, i.e. root-level siblings. Returns 0
  if no siblings exist at that level, otherwise `max_position + 1`.
  """
  @spec next_category_position(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: non_neg_integer()
  def next_category_position(catalogue_uuid, parent_uuid \\ nil) do
    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        select: max(c.position)
      )

    query =
      case parent_uuid do
        nil -> where(query, [c], is_nil(c.parent_uuid))
        uuid -> where(query, [c], c.parent_uuid == ^uuid)
      end

    case repo().one(query) do
      nil -> 0
      max_pos -> max_pos + 1
    end
  end

  @doc """
  Re-indexes a sibling group of categories from a list of UUIDs.

  Sibling scope is `(catalogue_uuid, parent_uuid)` — the same scope used
  by `swap_category_positions/2` and `next_category_position/2`. The
  function loads the supplied categories, verifies they all share that
  scope, and writes positions `1..N` in the order given. UUIDs not found
  in the table are ignored; UUIDs that don't share the scope abort the
  whole batch with `{:error, :not_siblings}`.

  Two-pass updates inside a single transaction — the first pass writes
  negative positions to dodge any future unique index on
  `(catalogue_uuid, parent_uuid, position)`; the second pass writes the
  final positive values. If no such index exists today, the cost is one
  extra `UPDATE` per row, which is cheap relative to the LV round-trip
  that triggers the call.
  """
  @spec reorder_categories(Ecto.UUID.t(), Ecto.UUID.t() | nil, [Ecto.UUID.t()], keyword()) ::
          :ok | {:error, :not_siblings | :too_many_uuids | term()}
  def reorder_categories(catalogue_uuid, parent_uuid, ordered_uuids, opts \\ [])
      when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    case validate_and_apply_category_reorder(catalogue_uuid, parent_uuid, ordered_uuids) do
      {:ok, 0} ->
        # No matching rows after dedupe — silent no-op, no audit row.
        :ok

      {:ok, count} ->
        Shared.log_activity(%{
          action: "category.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: List.first(Helpers.dedupe_keep_last(ordered_uuids)),
          parent_catalogue_uuid: catalogue_uuid,
          metadata: %{
            "parent_uuid" => parent_uuid,
            "count" => count
          }
        })

        :ok

      {:error, reason} when reason in [:too_many_uuids, :not_siblings] ->
        Shared.log_reorder_rejected(
          :category,
          reason,
          length(ordered_uuids),
          catalogue_uuid,
          opts
        )

        {:error, reason}

      {:error, reason} ->
        Shared.log_reorder_db_error(
          :category,
          Helpers.dedupe_keep_last(ordered_uuids),
          catalogue_uuid,
          opts
        )

        {:error, reason}
    end
  end

  @doc """
  Re-indexes multiple sibling groups of categories in **one outer
  transaction** — the LV layer hits this when a single drop touches
  more than one parent group.

  Each group is `{parent_uuid_or_nil, [uuid]}`. All groups are
  validated up front (cap + sibling scope) before any writes; if any
  group fails validation, the whole batch returns the error and no
  writes happen.

  Atomicity: a DB-level failure in any group rolls back every group.
  Beats the previous LV-side `Enum.reduce` over per-group calls,
  which committed groups one at a time and could leave partial state.
  """
  @spec reorder_categories_groups(
          Ecto.UUID.t(),
          [{Ecto.UUID.t() | nil, [Ecto.UUID.t()]}],
          keyword()
        ) :: :ok | {:error, :too_many_uuids | :not_siblings | term()}
  def reorder_categories_groups(catalogue_uuid, groups, opts \\ [])
      when is_binary(catalogue_uuid) and is_list(groups) do
    deduped_groups =
      Enum.map(groups, fn {parent_uuid, uuids} ->
        {parent_uuid, Helpers.dedupe_keep_last(uuids)}
      end)

    total_count = deduped_groups |> Enum.flat_map(fn {_p, u} -> u end) |> length()

    if total_count > @reorder_max_uuids do
      Shared.log_reorder_rejected(:category, :too_many_uuids, total_count, catalogue_uuid, opts)
      {:error, :too_many_uuids}
    else
      run_categories_groups_transaction(catalogue_uuid, deduped_groups, total_count, opts)
    end
  end

  defp run_categories_groups_transaction(catalogue_uuid, deduped_groups, total_count, opts) do
    txn_result =
      repo().transaction(fn ->
        lock_catalogue!(catalogue_uuid)

        Enum.reduce_while(deduped_groups, :ok, fn group, _acc ->
          apply_category_group_step(catalogue_uuid, group)
        end)
      end)

    case txn_result do
      {:ok, :ok} ->
        Shared.log_activity(
          %{
            action: "category.reordered",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "category",
            parent_catalogue_uuid: catalogue_uuid,
            metadata: %{
              "groups" => length(deduped_groups),
              "count" => total_count
            }
          },
          opts
        )

        :ok

      {:error, reason} when reason in [:too_many_uuids, :not_siblings] ->
        Shared.log_reorder_rejected(:category, reason, total_count, catalogue_uuid, opts)
        {:error, reason}

      {:error, reason} ->
        Shared.log_reorder_db_error(
          :category,
          Enum.flat_map(deduped_groups, fn {_p, u} -> u end),
          catalogue_uuid,
          opts
        )

        {:error, reason}
    end
  end

  # Step inside `Enum.reduce_while` over groups. Returns the
  # `:cont` / `:halt` tuple the caller's reduce expects, and on error
  # rolls back the outer transaction so partial commits aren't
  # possible.
  defp apply_category_group_step(catalogue_uuid, {parent_uuid, uuids}) do
    case validate_and_apply_category_reorder_in_txn(catalogue_uuid, parent_uuid, uuids) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, repo().rollback(reason)}
    end
  end

  # Validates scope + applies the two-pass write inside its own
  # transaction. Returns `{:ok, count}` on success or `{:error, reason}`
  # without any logging — callers handle logging outside the
  # transaction so audit rows survive a rollback.
  defp validate_and_apply_category_reorder(catalogue_uuid, _parent_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) and
              length(ordered_uuids) > @reorder_max_uuids,
       do: {:error, :too_many_uuids}

  defp validate_and_apply_category_reorder(catalogue_uuid, parent_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

    case category_scope_check(catalogue_uuid, parent_uuid, unique_uuids) do
      :empty -> {:ok, 0}
      :ok -> commit_category_positions(catalogue_uuid, unique_uuids)
      {:error, _} = err -> err
    end
  end

  # Reorders take the catalogue's trash/restore lock: a reorder writes rows
  # one at a time in the caller's order while a trash or restore writes the
  # same rows in scan order, and two transactions taking one set of rows in
  # different orders can deadlock.
  defp commit_category_positions(catalogue_uuid, unique_uuids) do
    reorder = fn ->
      lock_catalogue!(catalogue_uuid)
      write_category_positions(unique_uuids)
    end

    case repo().transaction(reorder) do
      {:ok, _} -> {:ok, length(unique_uuids)}
      {:error, reason} -> {:error, reason}
    end
  end

  # In-transaction variant for `reorder_categories_groups/3` —
  # validates + writes without opening its own savepoint. Returns
  # `:ok` on empty/success, `{:error, reason}` otherwise.
  defp validate_and_apply_category_reorder_in_txn(catalogue_uuid, parent_uuid, unique_uuids)
       when is_binary(catalogue_uuid) and is_list(unique_uuids) do
    case category_scope_check(catalogue_uuid, parent_uuid, unique_uuids) do
      :empty -> :ok
      :ok -> write_category_positions(unique_uuids)
      {:error, _} = err -> err
    end
  end

  defp category_scope_check(catalogue_uuid, parent_uuid, unique_uuids) do
    rows =
      from(c in Category, where: c.uuid in ^unique_uuids)
      |> repo().all()

    cond do
      rows == [] ->
        :empty

      not Enum.all?(rows, fn c ->
        c.catalogue_uuid == catalogue_uuid and c.parent_uuid == parent_uuid
      end) ->
        {:error, :not_siblings}

      true ->
        :ok
    end
  end

  # Future (perf): collapse the two-pass loop below to a single
  # `UPDATE phoenix_kit_cat_categories SET position = v.pos
  #   FROM (VALUES (uuid, pos), …) AS v(uuid, pos)
  #   WHERE phoenix_kit_cat_categories.uuid = v.uuid`
  # round-trip per scope. PG checks unique constraints at statement
  # end, so a CASE-based or VALUES-join UPDATE works even with a
  # future unique index on `(catalogue_uuid, parent_uuid, position)`.
  # Trigger to revisit: `:reorder_max_uuids` config bumped past 1000,
  # or a unique index is added.
  defp write_category_positions(unique_uuids) do
    # Rows are written (and so locked) in uuid order rather than the
    # caller's, the order a subtree trash locks them in.
    pairs = unique_uuids |> Enum.with_index(1) |> Enum.sort_by(fn {uuid, _idx} -> uuid end)

    Enum.each(pairs, fn {uuid, idx} ->
      from(c in Category, where: c.uuid == ^uuid)
      |> repo().update_all(set: [position: -idx])
    end)

    Enum.each(pairs, fn {uuid, idx} ->
      from(c in Category, where: c.uuid == ^uuid)
      |> repo().update_all(set: [position: idx])
    end)

    :ok
  end

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

  @doc "Category counterpart of `item_slug_taken?/3`."
  @spec category_slug_taken?(String.t(), String.t(), keyword()) :: boolean()
  def category_slug_taken?(slug, lang, opts \\ []) do
    Shared.slug_taken?(@category_slugs_table, "category_uuid", slug, lang, opts[:exclude_uuid])
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

  @doc """
  Moves several categories, each with its subtree and items, to another
  catalogue — at its top level, or under `parent_uuid` there. Each move
  is `move_category_to_catalogue/3` with its own guards; one refusal
  does not stop the others.

  A selected category whose ancestor is also selected travels inside
  that ancestor instead of being detached from it; if the ancestor does
  not move, it moves on its own. With the target equal
  to the scope catalogue this is `bulk_move_categories_under/3`.

  `opts[:catalogue_uuid]` is the source scope; categories outside it are
  refused (`:wrong_catalogue_scope`). Per-move broadcasts are muted and
  both catalogues get one batch event each.

  Returns `{:ok, %{moved: n, errors: [{uuid, reason}]}}`.
  """
  @spec bulk_move_categories_to_catalogue(
          [Ecto.UUID.t()],
          Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          keyword()
        ) :: {:ok, %{moved: non_neg_integer(), errors: [{Ecto.UUID.t(), term()}]}}
  def bulk_move_categories_to_catalogue(uuids, target_catalogue_uuid, parent_uuid, opts \\ [])
      when is_list(uuids) do
    if target_catalogue_uuid == opts[:catalogue_uuid] do
      bulk_move_categories_under(uuids, parent_uuid, opts)
    else
      do_bulk_move_categories_to_catalogue(uuids, target_catalogue_uuid, parent_uuid, opts)
    end
  end

  defp do_bulk_move_categories_to_catalogue(uuids, target, parent_uuid, opts) do
    uuids = Enum.uniq(uuids)

    case opts[:catalogue_uuid] do
      scope when is_binary(scope) ->
        run_bulk_category_move(uuids, target, parent_uuid, scope, opts)

      _ ->
        {:ok, %{moved: 0, errors: Enum.map(uuids, &{&1, :missing_catalogue_scope})}}
    end
  end

  defp run_bulk_category_move(uuids, target, parent_uuid, scope, opts) do
    muted = opts |> Keyword.put(:broadcast, false) |> Keyword.put(:parent_uuid, parent_uuid)
    {valid, invalid} = Enum.split_with(uuids, &Shared.valid_uuid?/1)
    rows = from(c in Category, where: c.uuid in ^valid) |> repo().all() |> Map.new(&{&1.uuid, &1})

    # The scope is checked for every entry before anything moves, so an
    # entry that later arrives inside a moved ancestor was this page's.
    {in_scope, refused} =
      Enum.split_with(valid, &match?(%Category{catalogue_uuid: ^scope}, rows[&1]))

    depth = selected_ancestor_counts(in_scope)

    # Outer categories first, then inner ones shallowest first: each inner
    # one either arrived inside its moved ancestor, or — the ancestor
    # refused, or it was lifted out meanwhile — moves on its own.
    {moved, errors, catalogues} =
      in_scope
      |> Enum.sort_by(&Map.get(depth, &1, 0))
      |> Enum.reduce({0, [], MapSet.new()}, fn uuid, {moved, errors, cats} ->
        case move_selected_category(uuid, target, Map.has_key?(depth, uuid), muted) do
          {:ok, :carried} ->
            {moved + 1, errors, cats}

          {:ok, {m, from}} ->
            {moved + 1, errors, cats |> MapSet.put(m.catalogue_uuid) |> MapSet.put(from)}

          {:error, reason} ->
            {moved, [{uuid, bulk_reason(reason)} | errors], cats}
        end
      end)

    if moved > 0 and Keyword.get(opts, :broadcast, true),
      do: Enum.each(catalogues, &broadcast_moved_out/1)

    errors =
      Enum.reverse(errors) ++
        Enum.map(refused, &{&1, if(rows[&1], do: :wrong_catalogue_scope, else: :not_found)}) ++
        Enum.map(invalid, &{&1, :invalid_uuid})

    {:ok, %{moved: moved, errors: errors}}
  end

  # One shape per error entry; a changeset would drag a whole row into
  # the page's error log.
  defp bulk_reason(%Ecto.Changeset{}), do: :invalid
  defp bulk_reason(reason), do: reason

  defp move_selected_category(uuid, target, true = _inner?, opts) do
    case get_category(uuid) do
      %Category{catalogue_uuid: ^target, status: status} when status != "deleted" ->
        {:ok, :carried}

      _ ->
        move_one_category_to_catalogue(uuid, target, opts)
    end
  end

  defp move_selected_category(uuid, target, false, opts),
    do: move_one_category_to_catalogue(uuid, target, opts)

  defp move_one_category_to_catalogue(uuid, target, opts) do
    scope = opts[:catalogue_uuid]

    case get_category(uuid) do
      nil ->
        {:error, :not_found}

      %Category{catalogue_uuid: c} when c != scope ->
        {:error, :wrong_catalogue_scope}

      category ->
        # The scope is re-checked under the lock, so it is the source.
        with {:ok, moved} <- move_category_to_catalogue(category, target, opts),
             do: {:ok, {moved, scope}}
    end
  end

  # For each selected uuid below another selected one: how many selected
  # ancestors it has (its depth within the selection). Top ones are absent.
  defp selected_ancestor_counts(uuids) do
    selected = MapSet.new(uuids)

    Enum.reduce(uuids, %{}, fn uuid, acc ->
      uuid
      |> Tree.subtree_uuids()
      |> Enum.map(&load_uuid/1)
      |> Enum.filter(&(&1 != uuid and MapSet.member?(selected, &1)))
      |> Enum.reduce(acc, fn below, acc -> Map.update(acc, below, 1, &(&1 + 1)) end)
    end)
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
  Bulk soft-deletes categories by UUID with a uniform item disposition
  (cascade / uncategorize / move_to). Each category goes through the
  same logic as `trash_category/2`. Returns `{:ok, %{categories:
  count, items_handled: count}}` or surfaces the first error.
  """
  @spec bulk_trash_categories(
          [Ecto.UUID.t()],
          :cascade | :uncategorize | {:move_to, Ecto.UUID.t()},
          keyword()
        ) ::
          {:ok, %{categories: non_neg_integer(), items_handled: non_neg_integer()}}
          | {:error, term()}
  def bulk_trash_categories([], _disposition, _opts),
    do: {:ok, %{categories: 0, items_handled: 0}}

  def bulk_trash_categories(uuids, disposition, opts) when is_list(uuids) do
    uuids = scope_category_uuids(uuids, opts[:catalogue_uuid])

    # Each step runs `trash_category/2` muted: a broadcast from inside the
    # outer transaction would reach subscribers before the rows commit
    # (and before a later step could roll them back). The trashed
    # `{uuid, catalogue_uuid}` pairs are collected and fanned out once the
    # transaction has committed.
    step_opts = Keyword.put(opts, :broadcast, false)

    Trash.locked_transaction(fn ->
      Trash.lock_catalogues_of!(Category, uuids)

      uuids
      |> ancestors_first()
      |> Enum.reduce_while(%{categories: 0, items_handled: 0, trashed: []}, fn uuid, acc ->
        bulk_trash_category_step(uuid, disposition, step_opts, acc)
      end)
    end)
    |> case do
      {:ok, %{trashed: trashed} = summary} ->
        broadcast_trashed_categories(trashed, opts)
        {:ok, Map.delete(summary, :trashed)}

      error ->
        error
    end
  end

  # A selection holding a category AND one of its descendants trashes the
  # ancestor first, so the descendant is stamped as taken by it — the
  # order the uuids happen to arrive in must not decide what restoring the
  # ancestor brings back.
  #
  # Depths come from one read of the selected categories' catalogues, taken
  # under their locks, not from a recursive ancestor query per selected uuid.
  defp ancestors_first(uuids) do
    parents =
      from(c in Category,
        where:
          c.catalogue_uuid in subquery(
            from(s in Category, where: s.uuid in ^uuids, select: s.catalogue_uuid)
          ),
        select: {c.uuid, c.parent_uuid}
      )
      |> repo().all()
      |> Map.new()

    Enum.sort_by(uuids, &category_depth(&1, parents, 0))
  end

  # Walks parent links up to a root, counting the steps. No real chain has
  # more steps than the catalogues hold categories, so a longer walk is a
  # cycle (which the tree guards forbid) and ends there; a deep chain is never
  # cut short.
  defp category_depth(uuid, parents, depth) do
    case Map.get(parents, uuid) do
      nil -> depth
      _parent_uuid when depth >= map_size(parents) -> depth
      parent_uuid -> category_depth(parent_uuid, parents, depth + 1)
    end
  end

  defp scope_category_uuids(uuids, nil), do: uuids

  defp scope_category_uuids(uuids, catalogue_uuid) do
    repo().all(
      from(c in Category,
        where: c.uuid in ^uuids and c.catalogue_uuid == ^catalogue_uuid,
        select: c.uuid
      )
    )
  end

  # One batch event per touched catalogue (like the other bulk ops), not
  # one per category — N per-row events made every open page reload N
  # times (review finding, 2026-08-24).
  defp broadcast_trashed_categories(trashed, opts) do
    if Keyword.get(opts, :broadcast, true) do
      trashed
      |> Enum.map(fn {_uuid, catalogue_uuid} -> catalogue_uuid end)
      |> Enum.uniq()
      |> Enum.each(fn catalogue_uuid ->
        PubSub.broadcast(:category, nil, catalogue_uuid)
      end)
    end

    :ok
  end

  defp bulk_trash_category_step(uuid, disposition, opts, acc) do
    case Helpers.get_by_uuid(Category, uuid) do
      nil -> {:cont, acc}
      %Category{status: "deleted"} -> {:cont, acc}
      %Category{} = category -> trash_one_in_bulk(category, disposition, opts, acc)
    end
  end

  defp trash_one_in_bulk(category, disposition, opts, acc) do
    case trash_category(category, Keyword.put(opts, :items, disposition)) do
      {:ok, _} ->
        {:cont,
         %{
           acc
           | categories: acc.categories + 1,
             trashed: [{category.uuid, category.catalogue_uuid} | acc.trashed]
         }}

      {:error, reason} ->
        {:halt, repo().rollback(reason)}
    end
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
