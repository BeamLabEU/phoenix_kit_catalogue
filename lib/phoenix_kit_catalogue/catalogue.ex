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

  alias PhoenixKitCatalogue.Schemas.{
    Catalogue,
    Category,
    Item,
    Manufacturer,
    ManufacturerSupplier,
    Supplier
  }

  alias PhoenixKit.Utils.Multilang

  require Logger

  @module_key "catalogue"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp log_activity(attrs) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
    end
  rescue
    e ->
      Logger.warning("[Catalogue] Failed to log activity: #{Exception.message(e)}")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturers
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists all manufacturers, ordered by name.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
      When nil (default), returns all manufacturers.

  ## Examples

      Catalogue.list_manufacturers()
      Catalogue.list_manufacturers(status: "active")
  """
  def list_manufacturers(opts \\ []) do
    query = from(m in Manufacturer, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [m], m.status == ^status)
      end

    repo().all(query)
  end

  @doc "Fetches a manufacturer by UUID. Returns `nil` if not found."
  def get_manufacturer(uuid), do: repo().get(Manufacturer, uuid)

  @doc "Fetches a manufacturer by UUID. Raises `Ecto.NoResultsError` if not found."
  def get_manufacturer!(uuid), do: repo().get!(Manufacturer, uuid)

  @doc """
  Creates a manufacturer.

  ## Required attributes

    * `:name` — manufacturer name (1-255 chars)

  ## Optional attributes

    * `:description`, `:website`, `:contact_info`, `:logo_url`, `:notes`
    * `:status` — `"active"` (default) or `"inactive"`
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_manufacturer(%{name: "Blum", website: "https://blum.com"})
  """
  def create_manufacturer(attrs, opts \\ []) do
    case %Manufacturer{} |> Manufacturer.changeset(attrs) |> repo().insert() do
      {:ok, manufacturer} = ok ->
        log_activity(%{
          action: "manufacturer.created",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "manufacturer",
          resource_uuid: manufacturer.uuid,
          metadata: %{"name" => manufacturer.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Updates a manufacturer with the given attributes."
  def update_manufacturer(%Manufacturer{} = manufacturer, attrs, opts \\ []) do
    case manufacturer |> Manufacturer.changeset(attrs) |> repo().update() do
      {:ok, updated} = ok ->
        log_activity(%{
          action: "manufacturer.updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "manufacturer",
          resource_uuid: updated.uuid,
          metadata: %{"name" => updated.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Hard-deletes a manufacturer from the database."
  def delete_manufacturer(%Manufacturer{} = manufacturer, opts \\ []) do
    case repo().delete(manufacturer) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "manufacturer.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "manufacturer",
          resource_uuid: manufacturer.uuid,
          metadata: %{"name" => manufacturer.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Returns a changeset for tracking manufacturer changes."
  def change_manufacturer(%Manufacturer{} = manufacturer, attrs \\ %{}) do
    Manufacturer.changeset(manufacturer, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Suppliers
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists all suppliers, ordered by name.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).

  ## Examples

      Catalogue.list_suppliers()
      Catalogue.list_suppliers(status: "active")
  """
  def list_suppliers(opts \\ []) do
    query = from(s in Supplier, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [s], s.status == ^status)
      end

    repo().all(query)
  end

  @doc "Fetches a supplier by UUID. Returns `nil` if not found."
  def get_supplier(uuid), do: repo().get(Supplier, uuid)

  @doc "Fetches a supplier by UUID. Raises `Ecto.NoResultsError` if not found."
  def get_supplier!(uuid), do: repo().get!(Supplier, uuid)

  @doc """
  Creates a supplier.

  ## Required attributes

    * `:name` — supplier name (1-255 chars)

  ## Optional attributes

    * `:description`, `:website`, `:contact_info`, `:notes`
    * `:status` — `"active"` (default) or `"inactive"`
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_supplier(%{name: "Regional Distributors"})
  """
  def create_supplier(attrs, opts \\ []) do
    case %Supplier{} |> Supplier.changeset(attrs) |> repo().insert() do
      {:ok, supplier} = ok ->
        log_activity(%{
          action: "supplier.created",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "supplier",
          resource_uuid: supplier.uuid,
          metadata: %{"name" => supplier.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Updates a supplier with the given attributes."
  def update_supplier(%Supplier{} = supplier, attrs, opts \\ []) do
    case supplier |> Supplier.changeset(attrs) |> repo().update() do
      {:ok, updated} = ok ->
        log_activity(%{
          action: "supplier.updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "supplier",
          resource_uuid: updated.uuid,
          metadata: %{"name" => updated.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Hard-deletes a supplier from the database."
  def delete_supplier(%Supplier{} = supplier, opts \\ []) do
    case repo().delete(supplier) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "supplier.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "supplier",
          resource_uuid: supplier.uuid,
          metadata: %{"name" => supplier.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Returns a changeset for tracking supplier changes."
  def change_supplier(%Supplier{} = supplier, attrs \\ %{}) do
    Supplier.changeset(supplier, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturer ↔ Supplier links
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Creates a many-to-many link between a manufacturer and a supplier.

  Returns `{:error, changeset}` if the link already exists (unique constraint).
  """
  def link_manufacturer_supplier(manufacturer_uuid, supplier_uuid) do
    %ManufacturerSupplier{}
    |> ManufacturerSupplier.changeset(%{
      manufacturer_uuid: manufacturer_uuid,
      supplier_uuid: supplier_uuid
    })
    |> repo().insert()
  end

  @doc """
  Removes the link between a manufacturer and a supplier.

  Returns `{:error, :not_found}` if the link doesn't exist.
  """
  def unlink_manufacturer_supplier(manufacturer_uuid, supplier_uuid) do
    query =
      from(ms in ManufacturerSupplier,
        where: ms.manufacturer_uuid == ^manufacturer_uuid and ms.supplier_uuid == ^supplier_uuid
      )

    case repo().one(query) do
      nil -> {:error, :not_found}
      record -> repo().delete(record)
    end
  end

  @doc "Lists all suppliers linked to a manufacturer, ordered by name."
  def list_suppliers_for_manufacturer(manufacturer_uuid) do
    from(s in Supplier,
      join: ms in ManufacturerSupplier,
      on: ms.supplier_uuid == s.uuid,
      where: ms.manufacturer_uuid == ^manufacturer_uuid,
      order_by: [asc: s.name]
    )
    |> repo().all()
  end

  @doc "Lists all manufacturers linked to a supplier, ordered by name."
  def list_manufacturers_for_supplier(supplier_uuid) do
    from(m in Manufacturer,
      join: ms in ManufacturerSupplier,
      on: ms.manufacturer_uuid == m.uuid,
      where: ms.supplier_uuid == ^supplier_uuid,
      order_by: [asc: m.name]
    )
    |> repo().all()
  end

  @doc "Returns a list of supplier UUIDs linked to a manufacturer."
  def linked_supplier_uuids(manufacturer_uuid) do
    from(ms in ManufacturerSupplier,
      where: ms.manufacturer_uuid == ^manufacturer_uuid,
      select: ms.supplier_uuid
    )
    |> repo().all()
  end

  @doc "Returns a list of manufacturer UUIDs linked to a supplier."
  def linked_manufacturer_uuids(supplier_uuid) do
    from(ms in ManufacturerSupplier,
      where: ms.supplier_uuid == ^supplier_uuid,
      select: ms.manufacturer_uuid
    )
    |> repo().all()
  end

  @doc """
  Syncs the supplier links for a manufacturer to match the given list of supplier UUIDs.

  Adds missing links and removes extra ones via set difference.
  Returns `{:ok, :synced}` on success or `{:error, reason}` on the first failure.
  """
  def sync_manufacturer_suppliers(manufacturer_uuid, supplier_uuids, opts \\ [])
      when is_list(supplier_uuids) do
    current = linked_supplier_uuids(manufacturer_uuid) |> MapSet.new()
    desired = MapSet.new(supplier_uuids)
    added = MapSet.difference(desired, current)
    removed = MapSet.difference(current, desired)

    result =
      repo().transaction(fn ->
        Enum.each(added, &ok_or_rollback(link_manufacturer_supplier(manufacturer_uuid, &1)))
        Enum.each(removed, &ok_or_rollback(unlink_manufacturer_supplier(manufacturer_uuid, &1)))
        :synced
      end)

    with {:ok, :synced} <- result do
      if MapSet.size(added) > 0 or MapSet.size(removed) > 0 do
        log_activity(%{
          action: "manufacturer.suppliers_synced",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "manufacturer",
          resource_uuid: manufacturer_uuid,
          metadata: %{
            "added_count" => MapSet.size(added),
            "removed_count" => MapSet.size(removed)
          }
        })
      end

      result
    end
  end

  @doc """
  Syncs the manufacturer links for a supplier to match the given list of manufacturer UUIDs.

  Adds missing links and removes extra ones via set difference.
  Returns `{:ok, :synced}` on success or `{:error, reason}` on the first failure.
  """
  def sync_supplier_manufacturers(supplier_uuid, manufacturer_uuids, opts \\ [])
      when is_list(manufacturer_uuids) do
    current = linked_manufacturer_uuids(supplier_uuid) |> MapSet.new()
    desired = MapSet.new(manufacturer_uuids)
    added = MapSet.difference(desired, current)
    removed = MapSet.difference(current, desired)

    result =
      repo().transaction(fn ->
        Enum.each(added, &ok_or_rollback(link_manufacturer_supplier(&1, supplier_uuid)))
        Enum.each(removed, &ok_or_rollback(unlink_manufacturer_supplier(&1, supplier_uuid)))
        :synced
      end)

    with {:ok, :synced} <- result do
      if MapSet.size(added) > 0 or MapSet.size(removed) > 0 do
        log_activity(%{
          action: "supplier.manufacturers_synced",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "supplier",
          resource_uuid: supplier_uuid,
          metadata: %{
            "added_count" => MapSet.size(added),
            "removed_count" => MapSet.size(removed)
          }
        })
      end

      result
    end
  end

  defp ok_or_rollback({:ok, _}), do: :ok
  defp ok_or_rollback({:error, reason}), do: repo().rollback(reason)

  # ═══════════════════════════════════════════════════════════════════
  # Catalogues
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists catalogues, ordered by name. Excludes deleted by default.

  ## Options

    * `:status` — when provided, returns only catalogues with this exact status
      (e.g. `"active"`, `"archived"`, `"deleted"`).
      When nil (default), returns all non-deleted catalogues.

  ## Examples

      Catalogue.list_catalogues()                     # active + archived
      Catalogue.list_catalogues(status: "deleted")    # only deleted
      Catalogue.list_catalogues(status: "active")     # only active
  """
  def list_catalogues(opts \\ []) do
    query = from(c in Catalogue, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [c], c.status != "deleted")
        status -> where(query, [c], c.status == ^status)
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

  This cannot be undone.

  ## Examples

      {:ok, _} = Catalogue.permanently_delete_catalogue(catalogue)
  """
  def permanently_delete_catalogue(%Catalogue{} = catalogue, opts \\ []) do
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
        metadata: %{"name" => catalogue.name}
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
    if has_attr?(attrs, :category_uuid) do
      attrs |> fetch_attr(:category_uuid) |> blank_to_nil()
    else
      item && Map.get(item, :category_uuid)
    end
  end

  # An empty-string `category_uuid` arrives from form params; normalize it
  # to `nil` so the changeset treats it as "clear category" instead of
  # tripping a malformed FK lookup.
  defp normalize_blank_category(attrs) do
    if has_attr?(attrs, :category_uuid) and fetch_attr(attrs, :category_uuid) == "" do
      put_attr(attrs, :category_uuid, nil)
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
        put_attr(attrs, :catalogue_uuid, cat_uuid)

      nil ->
        # Target category doesn't exist — leave attrs as-is so the
        # changeset's FK constraint surfaces a clear error.
        attrs
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp has_attr?(attrs, key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key))
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, to_string(key))
    end
  end

  defp put_attr(attrs, key, value) do
    cond do
      Map.has_key?(attrs, key) ->
        Map.put(attrs, key, value)

      Map.has_key?(attrs, to_string(key)) ->
        Map.put(attrs, to_string(key), value)

      # Neither form exists — insert using the same key style as the rest
      # of the map. Mixing atom and string keys yields an
      # `Ecto.CastError` inside `Ecto.Changeset.cast/4`, which is what
      # form-submitted (string-keyed) params will hit otherwise.
      string_keyed?(attrs) ->
        Map.put(attrs, to_string(key), value)

      true ->
        Map.put(attrs, key, value)
    end
  end

  defp string_keyed?(attrs) when map_size(attrs) == 0, do: false

  defp string_keyed?(attrs) do
    attrs |> Map.keys() |> hd() |> is_binary()
  end

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

  @doc "Returns a changeset for tracking item changes."
  def change_item(%Item{} = item, attrs \\ %{}) do
    Item.changeset(item, attrs)
  end

  @doc """
  Returns pricing info for an item within a catalogue.

  Looks up the catalogue's markup percentage directly on the item, then
  computes the sale price. Never raises — if the catalogue can't be
  loaded (e.g. DB hiccup, connection timeout), falls back to 0% markup
  and logs a warning so the caller still gets a renderable result
  instead of crashing a template.

  Returns a map with:

    * `:base_price` — the item's stored base price (or `nil` if unset)
    * `:catalogue_markup` — the parent catalogue's `markup_percentage`
      (the inherited default for items without an override)
    * `:item_markup` — the item's `markup_percentage` override, or
      `nil` when the item inherits from the catalogue
    * `:markup_percentage` — the markup actually applied to compute
      `:price` — the item's override if set, otherwise the catalogue's
    * `:price` — the computed sale price (or `nil` if no base price)

  Returns `nil` for `:price` if the item has no base price.

  ## Examples

      # Item inherits the catalogue's markup
      Catalogue.item_pricing(item)
      #=> %{
      #=>   base_price: Decimal.new("100.00"),
      #=>   catalogue_markup: Decimal.new("15.0"),
      #=>   item_markup: nil,
      #=>   markup_percentage: Decimal.new("15.0"),
      #=>   price: Decimal.new("115.00")
      #=> }

      # Item overrides to 50%
      Catalogue.item_pricing(item_with_override)
      #=> %{
      #=>   base_price: Decimal.new("100.00"),
      #=>   catalogue_markup: Decimal.new("15.0"),
      #=>   item_markup: Decimal.new("50.0"),
      #=>   markup_percentage: Decimal.new("50.0"),
      #=>   price: Decimal.new("150.00")
      #=> }
  """
  def item_pricing(%Item{} = item) do
    catalogue_markup = safe_markup_for_item(item)
    effective = Item.effective_markup(item, catalogue_markup)

    %{
      base_price: item.base_price,
      catalogue_markup: catalogue_markup,
      item_markup: item.markup_percentage,
      markup_percentage: effective,
      price: Item.sale_price(item, catalogue_markup)
    }
  end

  defp safe_markup_for_item(item) do
    case item.catalogue do
      %Catalogue{markup_percentage: mp} when not is_nil(mp) ->
        mp

      %Ecto.Association.NotLoaded{} ->
        load_catalogue_markup(item)

      _ ->
        Decimal.new("0")
    end
  end

  defp load_catalogue_markup(item) do
    case repo().preload(item, [:catalogue]) do
      %Item{catalogue: %Catalogue{markup_percentage: mp}} when not is_nil(mp) -> mp
      _ -> Decimal.new("0")
    end
  rescue
    e ->
      Logger.warning(
        "[Catalogue] Failed to load catalogue for item_pricing/1 (item #{item.uuid}): " <>
          Exception.message(e)
      )

      Decimal.new("0")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Search
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Searches items across all non-deleted catalogues.

  Matches against item name, description, and SKU using case-insensitive
  partial matching. Only returns non-deleted items in non-deleted categories
  of non-deleted catalogues.

  Preloads category (with catalogue) and manufacturer.

  Returns a list of items ordered by name.

  ## Options

    * `:limit` — max results to return (default 50)
    * `:offset` — number of results to skip, for paging (default 0)

  ## Examples

      Catalogue.search_items("oak")
      Catalogue.search_items("OAK-18", limit: 10)
      Catalogue.search_items("oak", limit: 100, offset: 100)
  """
  def search_items(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    pattern = "%#{sanitize_like(query)}%"

    from(i in Item,
      join: cat in Catalogue,
      on: i.catalogue_uuid == cat.uuid,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where: i.status != "deleted" and cat.status != "deleted",
      where: is_nil(c.uuid) or c.status != "deleted",
      where:
        ilike(i.name, ^pattern) or
          ilike(i.description, ^pattern) or
          ilike(i.sku, ^pattern) or
          fragment("?::text ILIKE ?", i.data, ^pattern),
      order_by: [asc: i.name, asc: i.uuid],
      limit: ^limit,
      offset: ^offset,
      preload: [:catalogue, category: :catalogue, manufacturer: []]
    )
    |> repo().all()
  end

  @doc """
  Returns the total number of items across all non-deleted catalogues
  that match a search query, using the same matching rules as
  `search_items/2`. Runs independently of `:limit`/`:offset`.

  ## Examples

      Catalogue.count_search_items("oak")
      #=> 1204
  """
  def count_search_items(query) do
    pattern = "%#{sanitize_like(query)}%"

    from(i in Item,
      join: cat in Catalogue,
      on: i.catalogue_uuid == cat.uuid,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where: i.status != "deleted" and cat.status != "deleted",
      where: is_nil(c.uuid) or c.status != "deleted",
      where:
        ilike(i.name, ^pattern) or
          ilike(i.description, ^pattern) or
          ilike(i.sku, ^pattern) or
          fragment("?::text ILIKE ?", i.data, ^pattern),
      select: count(i.uuid)
    )
    |> repo().one()
  end

  @doc """
  Searches items within a specific catalogue.

  Matches against item name, description, and SKU using case-insensitive
  partial matching. Only returns non-deleted items in non-deleted categories.

  Preloads category and manufacturer.

  Returns a list of items ordered by category position then item name.

  ## Options

    * `:limit` — max results to return (default 50)
    * `:offset` — number of results to skip, for paging (default 0)

  ## Examples

      Catalogue.search_items_in_catalogue(catalogue_uuid, "panel")
      Catalogue.search_items_in_catalogue(catalogue_uuid, "SKU", limit: 25)
      Catalogue.search_items_in_catalogue(catalogue_uuid, "panel", limit: 100, offset: 100)
  """
  def search_items_in_catalogue(catalogue_uuid, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    pattern = "%#{sanitize_like(query)}%"

    from(i in Item,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where: i.catalogue_uuid == ^catalogue_uuid,
      where: i.status != "deleted",
      where: is_nil(c.uuid) or c.status != "deleted",
      where:
        ilike(i.name, ^pattern) or
          ilike(i.description, ^pattern) or
          ilike(i.sku, ^pattern) or
          fragment("?::text ILIKE ?", i.data, ^pattern),
      order_by: [asc_nulls_last: c.position, asc: i.name, asc: i.uuid],
      limit: ^limit,
      offset: ^offset,
      preload: [:catalogue, category: :catalogue, manufacturer: []]
    )
    |> repo().all()
  end

  @doc """
  Returns the total number of items in a catalogue that match a search
  query, using the same matching rules as `search_items_in_catalogue/3`.

  Useful for paginating or driving "N of M" summaries alongside paged
  search results. Runs independently of `:limit`/`:offset` — this is the
  unbounded total.

  ## Examples

      Catalogue.count_search_items_in_catalogue(catalogue_uuid, "panel")
      #=> 237
  """
  def count_search_items_in_catalogue(catalogue_uuid, query) do
    pattern = "%#{sanitize_like(query)}%"

    from(i in Item,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where: i.catalogue_uuid == ^catalogue_uuid,
      where: i.status != "deleted",
      where: is_nil(c.uuid) or c.status != "deleted",
      where:
        ilike(i.name, ^pattern) or
          ilike(i.description, ^pattern) or
          ilike(i.sku, ^pattern) or
          fragment("?::text ILIKE ?", i.data, ^pattern),
      select: count(i.uuid)
    )
    |> repo().one()
  end

  @doc """
  Searches items within a specific category.

  Matches against item name, description, and SKU using case-insensitive
  partial matching. Only returns non-deleted items.

  Preloads category (with catalogue) and manufacturer.

  ## Options

    * `:limit` — max results to return (default 50)
    * `:offset` — number of results to skip, for paging (default 0)

  ## Examples

      Catalogue.search_items_in_category(category_uuid, "panel")
      Catalogue.search_items_in_category(category_uuid, "panel", limit: 100, offset: 100)
  """
  def search_items_in_category(category_uuid, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    pattern = "%#{sanitize_like(query)}%"

    from(i in Item,
      where: i.category_uuid == ^category_uuid,
      where: i.status != "deleted",
      where:
        ilike(i.name, ^pattern) or
          ilike(i.description, ^pattern) or
          ilike(i.sku, ^pattern) or
          fragment("?::text ILIKE ?", i.data, ^pattern),
      order_by: [asc: i.name, asc: i.uuid],
      limit: ^limit,
      offset: ^offset,
      preload: [:catalogue, category: :catalogue, manufacturer: []]
    )
    |> repo().all()
  end

  @doc """
  Returns the total number of non-deleted items in a category that
  match a search query, using the same matching rules as
  `search_items_in_category/3`. Runs independently of `:limit`/`:offset`.

  ## Examples

      Catalogue.count_search_items_in_category(category_uuid, "panel")
      #=> 42
  """
  def count_search_items_in_category(category_uuid, query) do
    pattern = "%#{sanitize_like(query)}%"

    from(i in Item,
      where: i.category_uuid == ^category_uuid,
      where: i.status != "deleted",
      where:
        ilike(i.name, ^pattern) or
          ilike(i.description, ^pattern) or
          ilike(i.sku, ^pattern) or
          fragment("?::text ILIKE ?", i.data, ^pattern),
      select: count(i.uuid)
    )
    |> repo().one()
  end

  defp sanitize_like(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Counts
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Counts non-deleted items in a catalogue, including items without a category.
  """
  def item_count_for_catalogue(catalogue_uuid) do
    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status != "deleted"
    )
    |> repo().aggregate(:count)
  end

  @doc """
  Returns a map of `%{catalogue_uuid => non_deleted_item_count}` for all catalogues.

  Single-query batch version of `item_count_for_catalogue/1` — avoids N+1 when
  displaying item counts alongside a catalogue list. Includes items both in
  categories and directly attached to a catalogue (uncategorized).
  """
  def item_counts_by_catalogue do
    from(i in Item,
      where: i.status != "deleted" and not is_nil(i.catalogue_uuid),
      group_by: i.catalogue_uuid,
      select: {i.catalogue_uuid, count(i.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc "Counts non-deleted categories for a catalogue."
  def category_count_for_catalogue(catalogue_uuid) do
    from(c in Category,
      where: c.catalogue_uuid == ^catalogue_uuid and c.status != "deleted"
    )
    |> repo().aggregate(:count)
  end

  @doc """
  Returns a map of `catalogue_uuid => non_deleted_category_count`, in a
  single query. Useful for displaying category counts alongside a
  catalogue list (e.g. in the import wizard's catalogue picker) without
  N+1 lookups.
  """
  def category_counts_by_catalogue do
    from(c in Category,
      where: c.status != "deleted",
      group_by: c.catalogue_uuid,
      select: {c.catalogue_uuid, count(c.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Counts deleted items in a catalogue, including items without a category.
  """
  def deleted_item_count_for_catalogue(catalogue_uuid) do
    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status == "deleted"
    )
    |> repo().aggregate(:count)
  end

  @doc "Counts deleted categories for a catalogue."
  def deleted_category_count_for_catalogue(catalogue_uuid) do
    from(c in Category,
      where: c.catalogue_uuid == ^catalogue_uuid and c.status == "deleted"
    )
    |> repo().aggregate(:count)
  end

  @doc """
  Total count of deleted entities (items + categories) for a catalogue.

  Used to determine whether to show the "Deleted" tab.
  """
  def deleted_count_for_catalogue(catalogue_uuid) do
    deleted_item_count_for_catalogue(catalogue_uuid) +
      deleted_category_count_for_catalogue(catalogue_uuid)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Multilang helpers
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Gets translated field data for a record in a specific language.

  Returns merged data (primary language as base + overrides for the requested language).

  ## Examples

      data = Catalogue.get_translation(catalogue, "ja")
      # => %{"_name" => "キッチン", "_description" => "..."}
  """
  def get_translation(record, lang_code) do
    Multilang.get_language_data(record.data || %{}, lang_code)
  end

  @doc """
  Updates the multilang `data` field for a record with language-specific field data.

  For primary language: stores ALL fields.
  For secondary languages: stores only overrides (differences from primary).

  The `update_fn` should be the entity's update function. It receives `(record, attrs)` for
  2-arity or `(record, attrs, opts)` for 3-arity when activity logging opts are provided.

  ## Examples

      Catalogue.set_translation(catalogue, "ja", %{"_name" => "キッチン"}, &Catalogue.update_catalogue/2)
      Catalogue.set_translation(catalogue, "ja", %{"_name" => "キッチン"}, &Catalogue.update_catalogue/3, actor_uuid: user.uuid)
  """
  def set_translation(record, lang_code, field_data, update_fn, opts \\ []) do
    new_data = Multilang.put_language_data(record.data || %{}, lang_code, field_data)

    if opts == [] do
      update_fn.(record, %{data: new_data})
    else
      update_fn.(record, %{data: new_data}, opts)
    end
  end
end
