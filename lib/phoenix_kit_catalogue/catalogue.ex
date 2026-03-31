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

  defp repo, do: PhoenixKit.RepoHelper.repo()

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
  def create_manufacturer(attrs) do
    %Manufacturer{}
    |> Manufacturer.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a manufacturer with the given attributes."
  def update_manufacturer(%Manufacturer{} = manufacturer, attrs) do
    manufacturer
    |> Manufacturer.changeset(attrs)
    |> repo().update()
  end

  @doc "Hard-deletes a manufacturer from the database."
  def delete_manufacturer(%Manufacturer{} = manufacturer) do
    repo().delete(manufacturer)
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
  def create_supplier(attrs) do
    %Supplier{}
    |> Supplier.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a supplier with the given attributes."
  def update_supplier(%Supplier{} = supplier, attrs) do
    supplier
    |> Supplier.changeset(attrs)
    |> repo().update()
  end

  @doc "Hard-deletes a supplier from the database."
  def delete_supplier(%Supplier{} = supplier) do
    repo().delete(supplier)
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
  def sync_manufacturer_suppliers(manufacturer_uuid, supplier_uuids)
      when is_list(supplier_uuids) do
    repo().transaction(fn ->
      current = linked_supplier_uuids(manufacturer_uuid) |> MapSet.new()
      desired = MapSet.new(supplier_uuids)

      MapSet.difference(desired, current)
      |> Enum.each(&ok_or_rollback(link_manufacturer_supplier(manufacturer_uuid, &1)))

      MapSet.difference(current, desired)
      |> Enum.each(&ok_or_rollback(unlink_manufacturer_supplier(manufacturer_uuid, &1)))

      :synced
    end)
  end

  @doc """
  Syncs the manufacturer links for a supplier to match the given list of manufacturer UUIDs.

  Adds missing links and removes extra ones via set difference.
  Returns `{:ok, :synced}` on success or `{:error, reason}` on the first failure.
  """
  def sync_supplier_manufacturers(supplier_uuid, manufacturer_uuids)
      when is_list(manufacturer_uuids) do
    repo().transaction(fn ->
      current = linked_manufacturer_uuids(supplier_uuid) |> MapSet.new()
      desired = MapSet.new(manufacturer_uuids)

      MapSet.difference(desired, current)
      |> Enum.each(&ok_or_rollback(link_manufacturer_supplier(&1, supplier_uuid)))

      MapSet.difference(current, desired)
      |> Enum.each(&ok_or_rollback(unlink_manufacturer_supplier(&1, supplier_uuid)))

      :synced
    end)
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
  def create_catalogue(attrs) do
    %Catalogue{}
    |> Catalogue.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a catalogue with the given attributes."
  def update_catalogue(%Catalogue{} = catalogue, attrs) do
    catalogue
    |> Catalogue.changeset(attrs)
    |> repo().update()
  end

  @doc "Hard-deletes a catalogue. Prefer `trash_catalogue/1` for soft-delete."
  def delete_catalogue(%Catalogue{} = catalogue) do
    repo().delete(catalogue)
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
  def trash_catalogue(%Catalogue{} = catalogue) do
    repo().transaction(fn ->
      now = DateTime.utc_now()

      from(i in Item,
        join: c in Category,
        on: i.category_uuid == c.uuid,
        where: c.catalogue_uuid == ^catalogue.uuid and i.status != "deleted"
      )
      |> repo().update_all(set: [status: "deleted", updated_at: now])

      from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid and c.status != "deleted")
      |> repo().update_all(set: [status: "deleted", updated_at: now])

      catalogue
      |> Catalogue.changeset(%{status: "deleted"})
      |> repo().update!()
    end)
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
  def restore_catalogue(%Catalogue{} = catalogue) do
    repo().transaction(fn ->
      now = DateTime.utc_now()

      from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid and c.status == "deleted")
      |> repo().update_all(set: [status: "active", updated_at: now])

      from(i in Item,
        join: c in Category,
        on: i.category_uuid == c.uuid,
        where: c.catalogue_uuid == ^catalogue.uuid and i.status == "deleted"
      )
      |> repo().update_all(set: [status: "active", updated_at: now])

      catalogue
      |> Catalogue.changeset(%{status: "active"})
      |> repo().update!()
    end)
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
  def permanently_delete_catalogue(%Catalogue{} = catalogue) do
    repo().transaction(fn ->
      from(i in Item,
        join: c in Category,
        on: i.category_uuid == c.uuid,
        where: c.catalogue_uuid == ^catalogue.uuid
      )
      |> repo().delete_all()

      from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid)
      |> repo().delete_all()

      repo().delete!(catalogue)
    end)
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
  def create_category(attrs) do
    %Category{}
    |> Category.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a category with the given attributes."
  def update_category(%Category{} = category, attrs) do
    category
    |> Category.changeset(attrs)
    |> repo().update()
  end

  @doc "Hard-deletes a category. Prefer `trash_category/1` for soft-delete."
  def delete_category(%Category{} = category) do
    repo().delete(category)
  end

  @doc """
  Soft-deletes a category by setting its status to `"deleted"`.

  **Cascades downward** in a transaction:
  1. All non-deleted items in this category → status `"deleted"`
  2. The category itself → status `"deleted"`

  ## Examples

      {:ok, _} = Catalogue.trash_category(category)
  """
  def trash_category(%Category{} = category) do
    repo().transaction(fn ->
      from(i in Item, where: i.category_uuid == ^category.uuid and i.status != "deleted")
      |> repo().update_all(set: [status: "deleted", updated_at: DateTime.utc_now()])

      category
      |> Category.changeset(%{status: "deleted"})
      |> repo().update!()
    end)
  end

  @doc """
  Restores a soft-deleted category by setting its status to `"active"`.

  **Cascades both directions** in a transaction:
  - **Upward**: if the parent catalogue is deleted, restores it too
  - **Downward**: restores all deleted items in this category

  ## Examples

      {:ok, _} = Catalogue.restore_category(category)
  """
  def restore_category(%Category{} = category) do
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
  end

  @doc """
  Permanently deletes a category and all its items from the database.

  **Cascades downward** in a transaction: hard-deletes all items, then the category.
  This cannot be undone.
  """
  def permanently_delete_category(%Category{} = category) do
    repo().transaction(fn ->
      from(i in Item, where: i.category_uuid == ^category.uuid)
      |> repo().delete_all()

      repo().delete!(category)
    end)
  end

  @doc """
  Moves a category (and all its items) to a different catalogue.

  Automatically assigns the next available position in the target catalogue.

  ## Examples

      {:ok, moved} = Catalogue.move_category_to_catalogue(category, target_catalogue_uuid)
  """
  def move_category_to_catalogue(%Category{} = category, target_catalogue_uuid) do
    next_pos = next_category_position(target_catalogue_uuid)

    category
    |> Category.changeset(%{catalogue_uuid: target_catalogue_uuid, position: next_pos})
    |> repo().update()
  end

  @doc """
  Atomically swaps the positions of two categories within a transaction.

  ## Examples

      {:ok, _} = Catalogue.swap_category_positions(cat_a, cat_b)
  """
  def swap_category_positions(%Category{} = cat_a, %Category{} = cat_b) do
    repo().transaction(fn ->
      pos_a = cat_a.position
      pos_b = cat_b.position

      cat_a |> Category.changeset(%{position: pos_b}) |> repo().update!()
      cat_b |> Category.changeset(%{position: pos_a}) |> repo().update!()
    end)
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
  Lists non-deleted items for a category, ordered by name.

  Preloads manufacturer.
  """
  def list_items_for_category(category_uuid) do
    from(i in Item,
      where: i.category_uuid == ^category_uuid and i.status != "deleted",
      order_by: [asc: :name],
      preload: [:manufacturer]
    )
    |> repo().all()
  end

  @doc """
  Lists non-deleted items for a catalogue (across all categories), ordered by
  category position then item name.

  Preloads category and manufacturer.
  """
  def list_items_for_catalogue(catalogue_uuid) do
    from(i in Item,
      join: c in Category,
      on: i.category_uuid == c.uuid,
      where: c.catalogue_uuid == ^catalogue_uuid and i.status != "deleted",
      order_by: [asc: c.position, asc: i.name],
      preload: [:category, :manufacturer]
    )
    |> repo().all()
  end

  @doc """
  Lists uncategorized items (no category assigned).

  These items are global — they don't belong to any specific catalogue
  since items only link to catalogues through categories.

  ## Options

    * `:mode` — `:active` (default) excludes deleted items;
      `:deleted` returns only deleted items.

  ## Examples

      Catalogue.list_uncategorized_items()
      Catalogue.list_uncategorized_items(mode: :deleted)
  """
  def list_uncategorized_items(opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(i in Item,
        where: is_nil(i.category_uuid),
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

  ## Optional attributes

    * `:description` — text description
    * `:sku` — stock keeping unit (unique, max 100 chars)
    * `:base_price` — decimal, must be >= 0 (cost/purchase price before markup)
    * `:unit` — `"piece"` (default), `"m2"`, or `"running_meter"`
    * `:status` — `"active"` (default), `"inactive"`, `"discontinued"`, or `"deleted"`
    * `:category_uuid` — the parent category (optional)
    * `:manufacturer_uuid` — the manufacturer (optional)
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_item(%{name: "Oak Panel 18mm", base_price: 25.50, sku: "OAK-18"})
      Catalogue.create_item(%{name: "Hinge", category_uuid: cat.uuid, manufacturer_uuid: m.uuid})
  """
  def create_item(attrs) do
    %Item{}
    |> Item.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates an item with the given attributes."
  def update_item(%Item{} = item, attrs) do
    item
    |> Item.changeset(attrs)
    |> repo().update()
  end

  @doc "Hard-deletes an item. Prefer `trash_item/1` for soft-delete."
  def delete_item(%Item{} = item) do
    repo().delete(item)
  end

  @doc """
  Soft-deletes an item by setting its status to `"deleted"`.

  ## Examples

      {:ok, item} = Catalogue.trash_item(item)
  """
  def trash_item(%Item{} = item) do
    item
    |> Item.changeset(%{status: "deleted"})
    |> repo().update()
  end

  @doc """
  Restores a soft-deleted item by setting its status to `"active"`.

  **Cascades upward** in a transaction: if the parent category is deleted,
  restores it too (so the item is visible in the active view).

  ## Examples

      {:ok, item} = Catalogue.restore_item(item)
  """
  def restore_item(%Item{} = item) do
    repo().transaction(fn ->
      maybe_restore_parent_hierarchy(item.category_uuid)

      item
      |> Item.changeset(%{status: "active"})
      |> repo().update!()
    end)
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
  def permanently_delete_item(%Item{} = item) do
    repo().delete(item)
  end

  @doc """
  Bulk soft-deletes all non-deleted items in a category.

  Returns `{count, nil}` where count is the number of items affected.

  ## Examples

      {3, nil} = Catalogue.trash_items_in_category(category_uuid)
  """
  def trash_items_in_category(category_uuid) do
    from(i in Item,
      where: i.category_uuid == ^category_uuid and i.status != "deleted"
    )
    |> repo().update_all(set: [status: "deleted", updated_at: DateTime.utc_now()])
  end

  @doc """
  Moves an item to a different category.

  ## Examples

      {:ok, item} = Catalogue.move_item_to_category(item, new_category_uuid)
  """
  def move_item_to_category(%Item{} = item, category_uuid) do
    item
    |> Item.changeset(%{category_uuid: category_uuid})
    |> repo().update()
  end

  @doc "Returns a changeset for tracking item changes."
  def change_item(%Item{} = item, attrs \\ %{}) do
    Item.changeset(item, attrs)
  end

  @doc """
  Returns pricing info for an item within a catalogue.

  Looks up the catalogue's markup percentage through the item's category,
  then computes the sale price.

  Returns a map with `:base_price`, `:markup_percentage`, and `:price` (sale price).
  Returns `nil` values if the item has no base price.

  ## Examples

      Catalogue.item_pricing(item)
      #=> %{base_price: Decimal.new("100.00"), markup_percentage: Decimal.new("15.0"), price: Decimal.new("115.00")}

      Catalogue.item_pricing(item_without_category)
      #=> %{base_price: Decimal.new("100.00"), markup_percentage: Decimal.new("0"), price: Decimal.new("100.00")}
  """
  def item_pricing(%Item{} = item) do
    item = repo().preload(item, category: :catalogue)

    markup =
      case item.category do
        %{catalogue: %Catalogue{markup_percentage: mp}} when not is_nil(mp) -> mp
        _ -> Decimal.new("0")
      end

    %{
      base_price: item.base_price,
      markup_percentage: markup,
      price: Item.sale_price(item, markup)
    }
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

  ## Examples

      Catalogue.search_items("oak")
      Catalogue.search_items("OAK-18", limit: 10)
  """
  def search_items(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pattern = "%#{sanitize_like(query)}%"

    from(i in Item,
      join: c in Category,
      on: i.category_uuid == c.uuid,
      join: cat in Catalogue,
      on: c.catalogue_uuid == cat.uuid,
      where: i.status != "deleted" and c.status != "deleted" and cat.status != "deleted",
      where:
        ilike(i.name, ^pattern) or
          ilike(i.description, ^pattern) or
          ilike(i.sku, ^pattern),
      order_by: [asc: i.name],
      limit: ^limit,
      preload: [category: :catalogue, manufacturer: []]
    )
    |> repo().all()
  end

  @doc """
  Searches items within a specific catalogue.

  Matches against item name, description, and SKU using case-insensitive
  partial matching. Only returns non-deleted items in non-deleted categories.

  Preloads category and manufacturer.

  Returns a list of items ordered by category position then item name.

  ## Options

    * `:limit` — max results to return (default 50)

  ## Examples

      Catalogue.search_items_in_catalogue(catalogue_uuid, "panel")
      Catalogue.search_items_in_catalogue(catalogue_uuid, "SKU", limit: 25)
  """
  def search_items_in_catalogue(catalogue_uuid, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    pattern = "%#{sanitize_like(query)}%"

    from(i in Item,
      join: c in Category,
      on: i.category_uuid == c.uuid,
      where: c.catalogue_uuid == ^catalogue_uuid,
      where: i.status != "deleted" and c.status != "deleted",
      where:
        ilike(i.name, ^pattern) or
          ilike(i.description, ^pattern) or
          ilike(i.sku, ^pattern),
      order_by: [asc: c.position, asc: i.name],
      limit: ^limit,
      preload: [:category, :manufacturer]
    )
    |> repo().all()
  end

  defp sanitize_like(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ═══════════════════════════════════════════════════════════════════
  # Deleted counts
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Counts deleted items belonging to categories in this catalogue.
  """
  def deleted_item_count_for_catalogue(catalogue_uuid) do
    from(i in Item,
      join: c in Category,
      on: i.category_uuid == c.uuid,
      where: c.catalogue_uuid == ^catalogue_uuid and i.status == "deleted"
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

  The `update_fn` should be the entity's update function (e.g. `&Catalogue.update_catalogue/2`).

  ## Examples

      Catalogue.set_translation(catalogue, "ja", %{"_name" => "キッチン"}, &Catalogue.update_catalogue/2)
  """
  def set_translation(record, lang_code, field_data, update_fn) do
    new_data = Multilang.put_language_data(record.data || %{}, lang_code, field_data)
    update_fn.(record, %{data: new_data})
  end
end
