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
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{
    ActivityLog,
    Counts,
    Helpers,
    Links,
    Manufacturers,
    PubSub,
    Rules,
    Search,
    Suppliers,
    Translations
  }

  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}

  require Logger

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # `log_activity/1` was extracted to `PhoenixKitCatalogue.Catalogue.ActivityLog`
  # so the per-section submodules can share it without circular imports.
  # Internal callers in the remaining sections still use this thin
  # alias for diff churn minimization.
  # `log_activity/1` writes an audit-log entry **and** fans out a
  # `{:catalogue_data_changed, kind, uuid}` event so list LVs subscribed
  # via `PubSub.subscribe/0` re-fetch. The two are coupled here because
  # every write in this module that's worth auditing is also worth
  # signalling — keeping them paired prevents accidental "I logged but
  # forgot to broadcast" drift. Submodules under
  # `PhoenixKitCatalogue.Catalogue.*` call `ActivityLog.log/1` and
  # `PubSub.broadcast/2` directly to keep their dependencies explicit.
  defp log_activity(attrs) do
    ActivityLog.log(attrs)
    broadcast_for(attrs)
  end

  defp broadcast_for(%{resource_type: "catalogue", resource_uuid: uuid}),
    do: PubSub.broadcast(:catalogue, uuid)

  defp broadcast_for(%{resource_type: "category", resource_uuid: uuid}),
    do: PubSub.broadcast(:category, uuid)

  defp broadcast_for(%{resource_type: "item", resource_uuid: uuid}),
    do: PubSub.broadcast(:item, uuid)

  defp broadcast_for(%{resource_type: "manufacturer", resource_uuid: uuid}),
    do: PubSub.broadcast(:manufacturer, uuid)

  defp broadcast_for(%{resource_type: "supplier", resource_uuid: uuid}),
    do: PubSub.broadcast(:supplier, uuid)

  defp broadcast_for(%{resource_type: "smart_rule", resource_uuid: uuid}),
    do: PubSub.broadcast(:smart_rule, uuid)

  defp broadcast_for(_attrs), do: :ok

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

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturer ↔ Supplier links — see PhoenixKitCatalogue.Catalogue.Links
  # ═══════════════════════════════════════════════════════════════════

  defdelegate link_manufacturer_supplier(manufacturer_uuid, supplier_uuid), to: Links
  defdelegate unlink_manufacturer_supplier(manufacturer_uuid, supplier_uuid), to: Links
  defdelegate list_suppliers_for_manufacturer(manufacturer_uuid), to: Links
  defdelegate list_manufacturers_for_supplier(supplier_uuid), to: Links
  defdelegate linked_supplier_uuids(manufacturer_uuid), to: Links
  defdelegate linked_manufacturer_uuids(supplier_uuid), to: Links

  defdelegate sync_manufacturer_suppliers(manufacturer_uuid, supplier_uuids, opts \\ []),
    to: Links

  defdelegate sync_supplier_manufacturers(supplier_uuid, manufacturer_uuids, opts \\ []),
    to: Links

  # ═══════════════════════════════════════════════════════════════════
  # Catalogues
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists catalogues, ordered by name. Excludes deleted by default.

  ## Options

    * `:status` — when provided, returns only catalogues with this exact status
      (e.g. `"active"`, `"archived"`, `"deleted"`).
      When nil (default), returns all non-deleted catalogues.
    * `:kind` — when provided, filters to a specific kind (`:standard`, `:smart`,
      or their string equivalents). When nil (default), returns all kinds.

  ## Examples

      Catalogue.list_catalogues()                     # active + archived
      Catalogue.list_catalogues(status: "deleted")    # only deleted
      Catalogue.list_catalogues(status: "active")     # only active
      Catalogue.list_catalogues(kind: :smart)         # only smart catalogues
      Catalogue.list_catalogues(kind: :standard)      # only standard catalogues
  """
  def list_catalogues(opts \\ []) do
    query = from(c in Catalogue, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [c], c.status != "deleted")
        status -> where(query, [c], c.status == ^status)
      end

    query =
      case Keyword.get(opts, :kind) do
        nil -> query
        kind -> where(query, [c], c.kind == ^to_string(kind))
      end

    repo().all(query)
  end

  @doc """
  Lists catalogues whose name starts with `prefix`, case-insensitive.

  Anchored at the start of the name — this is a *prefix* match
  (`name ILIKE 'prefix%'`), not a contains match. LIKE metacharacters
  (`%`, `_`) in the prefix are escaped.

  Excludes deleted catalogues by default. Useful for narrowing a search
  scope: pair with `search_items/2`'s `:catalogue_uuids` to search only
  the matched catalogues.

  ## Options

    * `:status` — when provided, returns only catalogues with this exact status.
      Defaults to non-deleted (active + archived).
    * `:limit` — max results (no limit by default).

  ## Examples

      Catalogue.list_catalogues_by_name_prefix("Kit")
      #=> [%Catalogue{name: "Kitchen Furniture"}, %Catalogue{name: "Kits"}]

      Catalogue.list_catalogues_by_name_prefix("Kit", limit: 5)
      Catalogue.list_catalogues_by_name_prefix("", limit: 10)  # returns first 10

      # Compose with search
      uuids =
        "Kit"
        |> Catalogue.list_catalogues_by_name_prefix()
        |> Enum.map(& &1.uuid)

      Catalogue.search_items("oak", catalogue_uuids: uuids)
  """
  def list_catalogues_by_name_prefix(prefix, opts \\ []) when is_binary(prefix) do
    pattern = "#{Helpers.sanitize_like(prefix)}%"

    query =
      from(c in Catalogue,
        where: ilike(c.name, ^pattern),
        order_by: [asc: :name]
      )

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [c], c.status != "deleted")
        status -> where(query, [c], c.status == ^status)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        lim -> limit(query, ^lim)
      end

    repo().all(query)
  end

  @doc "Returns the count of soft-deleted catalogues."
  def deleted_catalogue_count do
    from(c in Catalogue, where: c.status == "deleted")
    |> repo().aggregate(:count)
  end

  @doc "Fetches a catalogue by UUID without preloads. Returns `nil` if not found."
  def get_catalogue(uuid), do: repo().get(Catalogue, uuid)

  @doc """
  Fetches a catalogue by UUID without preloading categories or items.
  Raises `Ecto.NoResultsError` if not found. Prefer this over
  `get_catalogue!/2` in read paths that don't need the nested preloads
  (e.g. the infinite-scroll detail view, which pages categories and
  items separately).
  """
  def fetch_catalogue!(uuid), do: repo().get!(Catalogue, uuid)

  @doc """
  Fetches a catalogue by UUID with preloaded categories and items.
  Raises `Ecto.NoResultsError` if not found.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
      - `:active` — preloads non-deleted categories with non-deleted items
      - `:deleted` — preloads all categories with only deleted items
        (so you can see which categories contain trashed items)

  ## Examples

      Catalogue.get_catalogue!(uuid)                  # active view
      Catalogue.get_catalogue!(uuid, mode: :deleted)  # deleted view
  """
  def get_catalogue!(uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    {category_query, item_query} =
      case mode do
        :active ->
          {from(c in Category, where: c.status != "deleted", order_by: [asc: :position]),
           from(i in Item, where: i.status != "deleted", order_by: [asc: :name])}

        :deleted ->
          {from(c in Category, order_by: [asc: :position]),
           from(i in Item, where: i.status == "deleted", order_by: [asc: :name])}
      end

    Catalogue
    |> repo().get!(uuid)
    |> repo().preload(categories: {category_query, [items: item_query]})
  end

  @doc """
  Creates a catalogue.

  ## Required attributes

    * `:name` — catalogue name (1-255 chars)

  ## Optional attributes

    * `:description` — text description
    * `:status` — `"active"` (default), `"archived"`, or `"deleted"`
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_catalogue(%{name: "Kitchen Furniture"})
  """
  def create_catalogue(attrs, opts \\ []) do
    case %Catalogue{} |> Catalogue.changeset(attrs) |> repo().insert() do
      {:ok, catalogue} = ok ->
        log_activity(%{
          action: "catalogue.created",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: catalogue.uuid,
          metadata: %{"name" => catalogue.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Updates a catalogue with the given attributes."
  def update_catalogue(%Catalogue{} = catalogue, attrs, opts \\ []) do
    case catalogue |> Catalogue.changeset(attrs) |> repo().update() do
      {:ok, updated} = ok ->
        log_activity(%{
          action: "catalogue.updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: updated.uuid,
          metadata: %{"name" => updated.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Hard-deletes a catalogue. Prefer `trash_catalogue/1` for soft-delete."
  def delete_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    case repo().delete(catalogue) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "catalogue.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: catalogue.uuid,
          metadata: %{"name" => catalogue.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes a catalogue by setting its status to `"deleted"`.

  **Cascades downward** in a transaction:
  1. All non-deleted items in the catalogue's categories → status `"deleted"`
  2. All non-deleted categories → status `"deleted"`
  3. The catalogue itself → status `"deleted"`

  ## Examples

      {:ok, catalogue} = Catalogue.trash_catalogue(catalogue)
  """
  def trash_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()

        from(i in Item,
          where: i.catalogue_uuid == ^catalogue.uuid and i.status != "deleted"
        )
        |> repo().update_all(set: [status: "deleted", updated_at: now])

        from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid and c.status != "deleted")
        |> repo().update_all(set: [status: "deleted", updated_at: now])

        catalogue
        |> Catalogue.changeset(%{status: "deleted"})
        |> repo().update!()
      end)

    with {:ok, updated} <- result do
      log_activity(%{
        action: "catalogue.trashed",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "catalogue",
        resource_uuid: catalogue.uuid,
        metadata: %{"name" => catalogue.name}
      })

      {:ok, updated}
    end
  end

  @doc """
  Restores a soft-deleted catalogue by setting its status to `"active"`.

  **Cascades downward** in a transaction:
  1. All deleted categories → status `"active"`
  2. All deleted items in those categories → status `"active"`
  3. The catalogue itself → status `"active"`

  ## Examples

      {:ok, catalogue} = Catalogue.restore_catalogue(catalogue)
  """
  def restore_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()

        from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid and c.status == "deleted")
        |> repo().update_all(set: [status: "active", updated_at: now])

        from(i in Item,
          where: i.catalogue_uuid == ^catalogue.uuid and i.status == "deleted"
        )
        |> repo().update_all(set: [status: "active", updated_at: now])

        catalogue
        |> Catalogue.changeset(%{status: "active"})
        |> repo().update!()
      end)

    with {:ok, updated} <- result do
      log_activity(%{
        action: "catalogue.restored",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "catalogue",
        resource_uuid: catalogue.uuid,
        metadata: %{"name" => catalogue.name}
      })

      {:ok, updated}
    end
  end

  @doc """
  Permanently deletes a catalogue and all its contents from the database.

  **Cascades downward** in a transaction:
  1. Hard-deletes all items in the catalogue's categories
  2. Hard-deletes all categories
  3. Hard-deletes the catalogue

  Refuses with `{:error, {:referenced_by_smart_items, count}}` when one or
  more smart-catalogue items still have rules pointing at this catalogue.
  V102's `ON DELETE CASCADE` would silently wipe those rule rows;
  callers should resolve the references explicitly (or remove the rules)
  before retrying. Use `:force` to bypass this guard at your own risk.

  This cannot be undone.

  ## Options

    * `:actor_uuid` — UUID to attribute on the activity log
    * `:force` — when `true`, deletes even if smart-rule references exist

  ## Examples

      {:ok, _} = Catalogue.permanently_delete_catalogue(catalogue)
      {:error, {:referenced_by_smart_items, 3}} =
        Catalogue.permanently_delete_catalogue(catalogue_with_refs)
  """
  @spec permanently_delete_catalogue(Catalogue.t(), keyword()) ::
          {:ok, Catalogue.t()}
          | {:error, {:referenced_by_smart_items, non_neg_integer()}}
          | {:error, term()}
  def permanently_delete_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    ref_count = catalogue_reference_count(catalogue.uuid)

    if ref_count > 0 and not force? do
      {:error, {:referenced_by_smart_items, ref_count}}
    else
      do_permanently_delete_catalogue(catalogue, ref_count, opts)
    end
  end

  defp do_permanently_delete_catalogue(catalogue, ref_count, opts) do
    result =
      repo().transaction(fn ->
        from(i in Item, where: i.catalogue_uuid == ^catalogue.uuid)
        |> repo().delete_all()

        from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid)
        |> repo().delete_all()

        repo().delete!(catalogue)
      end)

    with {:ok, _} <- result do
      log_activity(%{
        action: "catalogue.permanently_deleted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "catalogue",
        resource_uuid: catalogue.uuid,
        metadata: %{
          "name" => catalogue.name,
          "smart_rules_cascaded" => ref_count
        }
      })

      result
    end
  end

  @doc "Returns a changeset for tracking catalogue changes."
  def change_catalogue(%Catalogue{} = catalogue, attrs \\ %{}) do
    Catalogue.changeset(catalogue, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Categories
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists non-deleted categories for a catalogue, ordered by position then name.

  Preloads items (non-deleted only).
  """
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
  Lists a page of items for a single category, ordered by name.

  Used by the infinite-scroll detail view; returns at most `:limit`
  items starting at `:offset`. Preloads `:catalogue` and `:manufacturer`
  so the table cell renderers can access them without extra queries.

  ## Options

    * `:mode` — `:active` (default, excludes deleted items) or `:deleted`
      (only deleted items)
    * `:offset` — default `0`
    * `:limit` — default `50`
  """
  def list_items_for_category_paged(category_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(i in Item,
        where: i.category_uuid == ^category_uuid,
        order_by: [asc: :name],
        offset: ^offset,
        limit: ^limit,
        preload: [:catalogue, :manufacturer]
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().all(query)
  end

  @doc """
  Lists a page of uncategorized items for a catalogue, ordered by name.

  Same shape as `list_items_for_category_paged/2`, but for items where
  `category_uuid IS NULL AND catalogue_uuid = ?`. Used as the final
  section of the infinite-scroll detail view.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
    * `:offset` — default `0`
    * `:limit` — default `50`
  """
  def list_uncategorized_items_paged(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid),
        order_by: [asc: :name],
        offset: ^offset,
        limit: ^limit,
        preload: [:catalogue, :manufacturer]
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().all(query)
  end

  @doc """
  Counts non-deleted uncategorized items for a catalogue (items with
  `category_uuid IS NULL`). Used to decide whether the infinite-scroll
  detail view needs to show an "Uncategorized" card at all.
  """
  def uncategorized_count_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid)
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().aggregate(query, :count)
  end

  @doc """
  Counts items in a single category (ignoring its catalogue scope).

  Used by the infinite-scroll detail view to show the total under each
  category header (the number in `"Category Name (N items)"`) without
  loading the items themselves.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
  """
  def item_count_for_category(category_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query = from(i in Item, where: i.category_uuid == ^category_uuid)

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().aggregate(query, :count)
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
  """
  def item_counts_by_category_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(i in Item,
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
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Lists all non-deleted categories across all non-deleted catalogues.

  Category names are prefixed with their catalogue name (e.g. `"Kitchen / Frames"`).
  Useful for item move dropdowns.
  """
  def list_all_categories do
    from(c in Category,
      join: cat in Catalogue,
      on: c.catalogue_uuid == cat.uuid,
      where: c.status != "deleted" and cat.status != "deleted",
      order_by: [asc: cat.name, asc: c.position, asc: c.name],
      select: %{c | name: fragment("? || ' / ' || ?", cat.name, c.name)}
    )
    |> repo().all()
  end

  @doc "Fetches a category by UUID. Returns `nil` if not found."
  def get_category(uuid), do: repo().get(Category, uuid)

  @doc "Fetches a category by UUID. Raises `Ecto.NoResultsError` if not found."
  def get_category!(uuid), do: repo().get!(Category, uuid)

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
  def create_category(attrs, opts \\ []) do
    case %Category{} |> Category.changeset(attrs) |> repo().insert() do
      {:ok, category} = ok ->
        log_activity(%{
          action: "category.created",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          metadata: %{"name" => category.name, "catalogue_uuid" => category.catalogue_uuid}
        })

        ok

      error ->
        error
    end
  end

  @doc "Updates a category with the given attributes."
  def update_category(%Category{} = category, attrs, opts \\ []) do
    case category |> Category.changeset(attrs) |> repo().update() do
      {:ok, updated} = ok ->
        log_activity(%{
          action: "category.updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: updated.uuid,
          metadata: %{"name" => updated.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Hard-deletes a category. Prefer `trash_category/1` for soft-delete."
  def delete_category(%Category{} = category, opts \\ []) do
    case repo().delete(category) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "category.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          metadata: %{"name" => category.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes a category by setting its status to `"deleted"`.

  **Cascades downward** in a transaction:
  1. All non-deleted items in this category → status `"deleted"`
  2. The category itself → status `"deleted"`

  ## Examples

      {:ok, _} = Catalogue.trash_category(category)
  """
  def trash_category(%Category{} = category, opts \\ []) do
    result =
      repo().transaction(fn ->
        from(i in Item, where: i.category_uuid == ^category.uuid and i.status != "deleted")
        |> repo().update_all(set: [status: "deleted", updated_at: DateTime.utc_now()])

        category
        |> Category.changeset(%{status: "deleted"})
        |> repo().update!()
      end)

    with {:ok, updated} <- result do
      log_activity(%{
        action: "category.trashed",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "category",
        resource_uuid: category.uuid,
        metadata: %{"name" => category.name, "catalogue_uuid" => category.catalogue_uuid}
      })

      {:ok, updated}
    end
  end

  @doc """
  Restores a soft-deleted category by setting its status to `"active"`.

  **Cascades both directions** in a transaction:
  - **Upward**: if the parent catalogue is deleted, restores it too
  - **Downward**: restores all deleted items in this category

  ## Examples

      {:ok, _} = Catalogue.restore_category(category)
  """
  def restore_category(%Category{} = category, opts \\ []) do
    result =
      repo().transaction(fn ->
        case repo().get(Catalogue, category.catalogue_uuid) do
          %Catalogue{status: "deleted"} = cat ->
            cat |> Catalogue.changeset(%{status: "active"}) |> repo().update!()

          _ ->
            :ok
        end

        from(i in Item, where: i.category_uuid == ^category.uuid and i.status == "deleted")
        |> repo().update_all(set: [status: "active", updated_at: DateTime.utc_now()])

        category
        |> Category.changeset(%{status: "active"})
        |> repo().update!()
      end)

    with {:ok, updated} <- result do
      log_activity(%{
        action: "category.restored",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "category",
        resource_uuid: category.uuid,
        metadata: %{"name" => category.name, "catalogue_uuid" => category.catalogue_uuid}
      })

      {:ok, updated}
    end
  end

  @doc """
  Permanently deletes a category and all its items from the database.

  **Cascades downward** in a transaction: hard-deletes all items, then the category.
  This cannot be undone.
  """
  def permanently_delete_category(%Category{} = category, opts \\ []) do
    result =
      repo().transaction(fn ->
        from(i in Item, where: i.category_uuid == ^category.uuid)
        |> repo().delete_all()

        repo().delete!(category)
      end)

    with {:ok, _} <- result do
      log_activity(%{
        action: "category.permanently_deleted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "category",
        resource_uuid: category.uuid,
        metadata: %{"name" => category.name, "catalogue_uuid" => category.catalogue_uuid}
      })

      result
    end
  end

  @doc """
  Moves a category (and all its items) to a different catalogue.

  Automatically assigns the next available position in the target catalogue.

  ## Examples

      {:ok, moved} = Catalogue.move_category_to_catalogue(category, target_catalogue_uuid)
  """
  def move_category_to_catalogue(%Category{} = category, target_catalogue_uuid, opts \\ []) do
    source_catalogue_uuid = category.catalogue_uuid
    next_pos = next_category_position(target_catalogue_uuid)

    result =
      repo().transaction(fn ->
        # Take an exclusive row lock on the category being moved. This
        # serializes concurrent `create_item`/`update_item` calls that
        # read the same category via `FOR SHARE` in
        # `put_catalogue_from_effective_category/2`: while we hold the
        # lock they block, and once we commit they read the new
        # `catalogue_uuid`. No item can slip in with a stale
        # `catalogue_uuid` between our items-update and our commit.
        repo().one!(from(c in Category, where: c.uuid == ^category.uuid, lock: "FOR UPDATE"))

        {items_updated, _} =
          from(i in Item, where: i.category_uuid == ^category.uuid)
          |> repo().update_all(
            set: [catalogue_uuid: target_catalogue_uuid, updated_at: DateTime.utc_now()]
          )

        moved =
          category
          |> Category.changeset(%{catalogue_uuid: target_catalogue_uuid, position: next_pos})
          |> repo().update!()

        {moved, items_updated}
      end)

    case result do
      {:ok, {moved, items_updated}} ->
        log_activity(%{
          action: "category.moved",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: moved.uuid,
          metadata: %{
            "name" => moved.name,
            "from_catalogue_uuid" => source_catalogue_uuid,
            "to_catalogue_uuid" => target_catalogue_uuid,
            "items_cascaded" => items_updated
          }
        })

        {:ok, moved}

      error ->
        error
    end
  end

  @doc """
  Atomically swaps the positions of two categories within a transaction.

  ## Examples

      {:ok, _} = Catalogue.swap_category_positions(cat_a, cat_b)
  """
  @spec swap_category_positions(Category.t(), Category.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def swap_category_positions(%Category{} = cat_a, %Category{} = cat_b, opts \\ []) do
    result =
      repo().transaction(fn ->
        pos_a = cat_a.position
        pos_b = cat_b.position

        cat_a |> Category.changeset(%{position: pos_b}) |> repo().update!()
        cat_b |> Category.changeset(%{position: pos_a}) |> repo().update!()
      end)

    with {:ok, _} <- result do
      log_activity(%{
        action: "category.positions_swapped",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "category",
        resource_uuid: cat_a.uuid,
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
  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

  @doc """
  Returns the next available position for a new category in a catalogue.

  Returns 0 if no categories exist, otherwise `max_position + 1`.
  """
  def next_category_position(catalogue_uuid) do
    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        select: max(c.position)
      )

    case repo().one(query) do
      nil -> 0
      max_pos -> max_pos + 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Items
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists all non-deleted items across all catalogues, ordered by name.

  Preloads category (with catalogue) and manufacturer.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
      When nil (default), returns all non-deleted items.
    * `:limit` — max results to return (default: no limit)

  ## Examples

      Catalogue.list_items()                          # all non-deleted
      Catalogue.list_items(status: "active")          # only active
      Catalogue.list_items(limit: 100)                # first 100
  """
  def list_items(opts \\ []) do
    query =
      from(i in Item,
        order_by: [asc: :name],
        preload: [:catalogue, category: :catalogue, manufacturer: []]
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

    repo().all(query)
  end

  @doc """
  Lists non-deleted items for a category, ordered by name.

  Preloads category (with catalogue) and manufacturer.
  """
  def list_items_for_category(category_uuid) do
    from(i in Item,
      where: i.category_uuid == ^category_uuid and i.status != "deleted",
      order_by: [asc: :name],
      preload: [:catalogue, category: :catalogue, manufacturer: []]
    )
    |> repo().all()
  end

  @doc """
  Lists non-deleted items for a catalogue, ordered by category position then
  item name. Includes uncategorized items (those with no category) at the end.

  Preloads catalogue, category (with catalogue) and manufacturer.
  """
  def list_items_for_catalogue(catalogue_uuid) do
    from(i in Item,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status != "deleted",
      order_by: [asc_nulls_last: c.position, asc: i.name],
      preload: [:catalogue, category: :catalogue, manufacturer: []]
    )
    |> repo().all()
  end

  @doc """
  Lists uncategorized items (no category assigned) for a specific catalogue.

  ## Options

    * `:mode` — `:active` (default) excludes deleted items;
      `:deleted` returns only deleted items.

  ## Examples

      Catalogue.list_uncategorized_items(catalogue_uuid)
      Catalogue.list_uncategorized_items(catalogue_uuid, mode: :deleted)
  """
  def list_uncategorized_items(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid),
        order_by: [asc: i.name],
        preload: [:manufacturer]
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().all(query)
  end

  @doc "Fetches an item by UUID without preloads. Returns `nil` if not found."
  def get_item(uuid), do: repo().get(Item, uuid)

  @doc """
  Fetches an item by UUID with preloaded category and manufacturer.
  Raises `Ecto.NoResultsError` if not found.
  """
  def get_item!(uuid) do
    Item
    |> repo().get!(uuid)
    |> repo().preload([:category, :manufacturer])
  end

  @doc """
  Creates an item.

  ## Required attributes

    * `:name` — item name (1-255 chars)
    * `:catalogue_uuid` — the parent catalogue (required). Auto-derived from
      `:category_uuid` when omitted and a category is provided.

  ## Optional attributes

    * `:description` — text description
    * `:sku` — stock keeping unit (unique, max 100 chars)
    * `:base_price` — decimal, must be >= 0 (cost/purchase price before markup)
    * `:unit` — `"piece"` (default), `"m2"`, or `"running_meter"`
    * `:status` — `"active"` (default), `"inactive"`, `"discontinued"`, or `"deleted"`
    * `:category_uuid` — the parent category (optional — leave nil for uncategorized items)
    * `:manufacturer_uuid` — the manufacturer (optional)
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_item(%{name: "Oak Panel 18mm", catalogue_uuid: cat.uuid, base_price: 25.50})
      Catalogue.create_item(%{name: "Hinge", category_uuid: category.uuid, manufacturer_uuid: m.uuid})
  """
  def create_item(attrs, opts \\ []) do
    skip_derive? = Keyword.get(opts, :skip_derive, false)

    # We run derivation + insert in the same transaction so that the
    # `FOR SHARE` row lock inside `put_catalogue_from_effective_category`
    # is held until the INSERT commits. That closes the race with a
    # concurrent `move_category_to_catalogue/3` (which takes `FOR UPDATE`
    # on the same row): while the move holds the exclusive lock, our
    # derive waits; once we hold the shared lock, the move waits — so an
    # item can never be inserted with a stale `catalogue_uuid` mid-move.
    result =
      repo().transaction(fn ->
        attrs = if skip_derive?, do: attrs, else: derive_catalogue_uuid(nil, attrs)

        case %Item{} |> Item.changeset(attrs) |> repo().insert() do
          {:ok, item} -> item
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, item} ->
        log_activity(%{
          action: "item.created",
          mode: opts[:mode] || "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: item.uuid,
          metadata: %{"name" => item.name, "sku" => item.sku || ""}
        })

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
      attrs |> Helpers.fetch_attr(:category_uuid) |> blank_to_nil()
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

  # If the effective category exists, pin `catalogue_uuid` to that
  # category's catalogue — this is the single source of truth and
  # overrides any stale value the caller might have passed. If no
  # category exists in the resulting state, leave `catalogue_uuid`
  # alone; `validate_required` enforces it ends up set.
  #
  # The `FOR SHARE` row lock closes the move_category race: see the
  # comment in `create_item/2`. Must be invoked inside a transaction
  # for the lock to persist until the insert/update commits.
  defp put_catalogue_from_effective_category(attrs, nil), do: attrs

  defp put_catalogue_from_effective_category(attrs, category_uuid)
       when is_binary(category_uuid) do
    query = from(c in Category, where: c.uuid == ^category_uuid, lock: "FOR SHARE")

    case repo().one(query) do
      %Category{catalogue_uuid: cat_uuid} ->
        Helpers.put_attr(attrs, :catalogue_uuid, cat_uuid)

      nil ->
        # Target category doesn't exist — leave attrs as-is so the
        # changeset's FK constraint surfaces a clear error.
        attrs
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  @doc "Updates an item with the given attributes."
  def update_item(%Item{} = item, attrs, opts \\ []) do
    skip_derive? = Keyword.get(opts, :skip_derive, false)

    result =
      repo().transaction(fn ->
        attrs = if skip_derive?, do: attrs, else: derive_catalogue_uuid(item, attrs)

        case item |> Item.changeset(attrs) |> repo().update() do
          {:ok, updated} -> updated
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, updated} ->
        log_activity(%{
          action: "item.updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: updated.uuid,
          metadata: %{"name" => updated.name, "sku" => updated.sku || ""}
        })

        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc "Hard-deletes an item. Prefer `trash_item/1` for soft-delete."
  def delete_item(%Item{} = item, opts \\ []) do
    case repo().delete(item) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "item.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: item.uuid,
          metadata: %{"name" => item.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes an item by setting its status to `"deleted"`.

  ## Examples

      {:ok, item} = Catalogue.trash_item(item)
  """
  def trash_item(%Item{} = item, opts \\ []) do
    case item |> Item.changeset(%{status: "deleted"}) |> repo().update() do
      {:ok, trashed} = ok ->
        log_activity(%{
          action: "item.trashed",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: trashed.uuid,
          metadata: %{"name" => trashed.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Restores a soft-deleted item by setting its status to `"active"`.

  **Cascades upward** in a transaction: if the parent category is deleted,
  restores it too (so the item is visible in the active view).

  ## Examples

      {:ok, item} = Catalogue.restore_item(item)
  """
  def restore_item(%Item{} = item, opts \\ []) do
    result =
      repo().transaction(fn ->
        maybe_restore_parent_hierarchy(item.category_uuid)

        item
        |> Item.changeset(%{status: "active"})
        |> repo().update!()
      end)

    with {:ok, restored} <- result do
      log_activity(%{
        action: "item.restored",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        resource_uuid: restored.uuid,
        metadata: %{"name" => restored.name}
      })

      {:ok, restored}
    end
  end

  defp maybe_restore_parent_hierarchy(nil), do: :ok

  defp maybe_restore_parent_hierarchy(category_uuid) do
    case repo().get(Category, category_uuid) do
      %Category{status: "deleted"} = cat ->
        maybe_restore_parent_catalogue(cat.catalogue_uuid)
        cat |> Category.changeset(%{status: "active"}) |> repo().update!()

      _ ->
        :ok
    end
  end

  defp maybe_restore_parent_catalogue(catalogue_uuid) do
    case repo().get(Catalogue, catalogue_uuid) do
      %Catalogue{status: "deleted"} = cat ->
        cat |> Catalogue.changeset(%{status: "active"}) |> repo().update!()

      _ ->
        :ok
    end
  end

  @doc """
  Permanently deletes an item from the database. This cannot be undone.

  ## Examples

      {:ok, _} = Catalogue.permanently_delete_item(item)
  """
  def permanently_delete_item(%Item{} = item, opts \\ []) do
    case repo().delete(item) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "item.permanently_deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: item.uuid,
          metadata: %{"name" => item.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Bulk soft-deletes all non-deleted items in a category.

  Returns `{count, nil}` where count is the number of items affected.

  ## Examples

      {3, nil} = Catalogue.trash_items_in_category(category_uuid)
  """
  def trash_items_in_category(category_uuid, opts \\ []) do
    {count, _} =
      from(i in Item,
        where: i.category_uuid == ^category_uuid and i.status != "deleted"
      )
      |> repo().update_all(set: [status: "deleted", updated_at: DateTime.utc_now()])

    if count > 0 do
      log_activity(%{
        action: "item.bulk_trashed",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        metadata: %{"category_uuid" => category_uuid, "count" => count}
      })
    end

    {count, nil}
  end

  @doc """
  Moves an item to a different category.

  If the target category lives in a different catalogue, the item's
  `catalogue_uuid` is updated to match. Passing `nil` for `category_uuid`
  detaches the item from any category while keeping it in its current
  catalogue.

  ## Examples

      {:ok, item} = Catalogue.move_item_to_category(item, new_category_uuid)
      {:ok, item} = Catalogue.move_item_to_category(item, nil)  # make uncategorized
  """
  def move_item_to_category(%Item{} = item, category_uuid, opts \\ []) do
    from_category_uuid = item.category_uuid

    with {:ok, attrs} <- resolve_move_attrs(category_uuid),
         {:ok, moved} <- item |> Item.changeset(attrs) |> repo().update() do
      log_activity(%{
        action: "item.moved",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        resource_uuid: moved.uuid,
        metadata: %{
          "name" => moved.name,
          "from_category_uuid" => from_category_uuid,
          "to_category_uuid" => category_uuid
        }
      })

      {:ok, moved}
    end
  end

  defp resolve_move_attrs(nil), do: {:ok, %{category_uuid: nil}}

  defp resolve_move_attrs(category_uuid) when is_binary(category_uuid) do
    case repo().get(Category, category_uuid) do
      %Category{catalogue_uuid: cat_uuid} ->
        {:ok, %{category_uuid: category_uuid, catalogue_uuid: cat_uuid}}

      nil ->
        {:error, :category_not_found}
    end
  end

  @doc """
  Moves an item to a different catalogue, clearing its category.

  Primarily used for **smart** items, where categories don't apply —
  the "where does this item live?" question reduces to "which catalogue?".
  Sets both `catalogue_uuid` and `category_uuid` in one update so the
  item becomes uncategorized within its new catalogue.

  Returns `{:error, :catalogue_not_found}` if the target catalogue UUID
  doesn't resolve, `{:error, :same_catalogue}` if it's already there, or
  `{:error, changeset}` on validation failure. Logs an `item.moved`
  activity with from/to catalogue metadata.

  ## Examples

      {:ok, item} = Catalogue.move_item_to_catalogue(item, other_smart.uuid)
  """
  @spec move_item_to_catalogue(Item.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Item.t()}
          | {:error, :catalogue_not_found | :same_catalogue | Ecto.Changeset.t(Item.t())}
  def move_item_to_catalogue(%Item{} = item, catalogue_uuid, opts \\ [])
      when is_binary(catalogue_uuid) do
    from_catalogue_uuid = item.catalogue_uuid

    cond do
      catalogue_uuid == from_catalogue_uuid ->
        {:error, :same_catalogue}

      is_nil(repo().get(Catalogue, catalogue_uuid)) ->
        {:error, :catalogue_not_found}

      true ->
        attrs = %{catalogue_uuid: catalogue_uuid, category_uuid: nil}

        with {:ok, moved} <- item |> Item.changeset(attrs) |> repo().update() do
          log_activity(%{
            action: "item.moved",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            resource_uuid: moved.uuid,
            metadata: %{
              "name" => moved.name,
              "from_catalogue_uuid" => from_catalogue_uuid,
              "to_catalogue_uuid" => catalogue_uuid,
              "from_category_uuid" => item.category_uuid,
              "to_category_uuid" => nil
            }
          })

          {:ok, moved}
        end
    end
  end

  @doc "Returns a changeset for tracking item changes."
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
  defdelegate list_items_referencing_catalogue(catalogue_uuid), to: Rules
  defdelegate catalogue_reference_count(catalogue_uuid), to: Rules
  defdelegate change_catalogue_rule(rule, attrs \\ %{}), to: Rules
  defdelegate create_catalogue_rule(attrs, opts \\ []), to: Rules
  defdelegate update_catalogue_rule(rule, attrs, opts \\ []), to: Rules
  defdelegate delete_catalogue_rule(rule, opts \\ []), to: Rules

  # ═══════════════════════════════════════════════════════════════════
  # Search — see PhoenixKitCatalogue.Catalogue.Search
  # ═══════════════════════════════════════════════════════════════════

  defdelegate search_items(query, opts \\ []), to: Search
  defdelegate count_search_items(query, opts \\ []), to: Search
  defdelegate search_items_in_catalogue(catalogue_uuid, query, opts \\ []), to: Search
  defdelegate count_search_items_in_catalogue(catalogue_uuid, query), to: Search
  defdelegate search_items_in_category(category_uuid, query, opts \\ []), to: Search
  defdelegate count_search_items_in_category(category_uuid, query), to: Search

  # ═══════════════════════════════════════════════════════════════════
  # Counts — see PhoenixKitCatalogue.Catalogue.Counts
  # ═══════════════════════════════════════════════════════════════════

  defdelegate item_count_for_catalogue(catalogue_uuid), to: Counts
  defdelegate item_counts_by_catalogue(), to: Counts
  defdelegate category_count_for_catalogue(catalogue_uuid), to: Counts
  defdelegate category_counts_by_catalogue(), to: Counts
  defdelegate deleted_item_count_for_catalogue(catalogue_uuid), to: Counts
  defdelegate deleted_category_count_for_catalogue(catalogue_uuid), to: Counts
  defdelegate deleted_count_for_catalogue(catalogue_uuid), to: Counts

  # ═══════════════════════════════════════════════════════════════════
  # Multilang helpers — see PhoenixKitCatalogue.Catalogue.Translations
  # ═══════════════════════════════════════════════════════════════════

  defdelegate get_translation(record, lang_code), to: Translations

  defdelegate set_translation(record, lang_code, field_data, update_fn, opts \\ []),
    to: Translations
end
