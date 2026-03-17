defmodule PhoenixKitCatalogue.Catalogue do
  @moduledoc """
  Context module for managing catalogues, manufacturers, suppliers, categories, and items.
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

  alias PhoenixKit.Modules.Entities.Multilang

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturers
  # ═══════════════════════════════════════════════════════════════════

  def list_manufacturers(opts \\ []) do
    query = from(m in Manufacturer, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [m], m.status == ^status)
      end

    repo().all(query)
  end

  def get_manufacturer(uuid), do: repo().get(Manufacturer, uuid)
  def get_manufacturer!(uuid), do: repo().get!(Manufacturer, uuid)

  def create_manufacturer(attrs) do
    %Manufacturer{}
    |> Manufacturer.changeset(attrs)
    |> repo().insert()
  end

  def update_manufacturer(%Manufacturer{} = manufacturer, attrs) do
    manufacturer
    |> Manufacturer.changeset(attrs)
    |> repo().update()
  end

  def delete_manufacturer(%Manufacturer{} = manufacturer) do
    repo().delete(manufacturer)
  end

  def change_manufacturer(%Manufacturer{} = manufacturer, attrs \\ %{}) do
    Manufacturer.changeset(manufacturer, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Suppliers
  # ═══════════════════════════════════════════════════════════════════

  def list_suppliers(opts \\ []) do
    query = from(s in Supplier, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [s], s.status == ^status)
      end

    repo().all(query)
  end

  def get_supplier(uuid), do: repo().get(Supplier, uuid)
  def get_supplier!(uuid), do: repo().get!(Supplier, uuid)

  def create_supplier(attrs) do
    %Supplier{}
    |> Supplier.changeset(attrs)
    |> repo().insert()
  end

  def update_supplier(%Supplier{} = supplier, attrs) do
    supplier
    |> Supplier.changeset(attrs)
    |> repo().update()
  end

  def delete_supplier(%Supplier{} = supplier) do
    repo().delete(supplier)
  end

  def change_supplier(%Supplier{} = supplier, attrs \\ %{}) do
    Supplier.changeset(supplier, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturer ↔ Supplier links
  # ═══════════════════════════════════════════════════════════════════

  def link_manufacturer_supplier(manufacturer_uuid, supplier_uuid) do
    %ManufacturerSupplier{}
    |> ManufacturerSupplier.changeset(%{
      manufacturer_uuid: manufacturer_uuid,
      supplier_uuid: supplier_uuid
    })
    |> repo().insert()
  end

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

  def list_suppliers_for_manufacturer(manufacturer_uuid) do
    from(s in Supplier,
      join: ms in ManufacturerSupplier,
      on: ms.supplier_uuid == s.uuid,
      where: ms.manufacturer_uuid == ^manufacturer_uuid,
      order_by: [asc: s.name]
    )
    |> repo().all()
  end

  def list_manufacturers_for_supplier(supplier_uuid) do
    from(m in Manufacturer,
      join: ms in ManufacturerSupplier,
      on: ms.manufacturer_uuid == m.uuid,
      where: ms.supplier_uuid == ^supplier_uuid,
      order_by: [asc: m.name]
    )
    |> repo().all()
  end

  def linked_supplier_uuids(manufacturer_uuid) do
    from(ms in ManufacturerSupplier,
      where: ms.manufacturer_uuid == ^manufacturer_uuid,
      select: ms.supplier_uuid
    )
    |> repo().all()
  end

  def linked_manufacturer_uuids(supplier_uuid) do
    from(ms in ManufacturerSupplier,
      where: ms.supplier_uuid == ^supplier_uuid,
      select: ms.manufacturer_uuid
    )
    |> repo().all()
  end

  @doc "Sync the supplier links for a manufacturer to match the given list of supplier UUIDs."
  def sync_manufacturer_suppliers(manufacturer_uuid, supplier_uuids)
      when is_list(supplier_uuids) do
    current = linked_supplier_uuids(manufacturer_uuid) |> MapSet.new()
    desired = MapSet.new(supplier_uuids)

    to_add = MapSet.difference(desired, current)
    to_remove = MapSet.difference(current, desired)

    Enum.each(to_add, &link_manufacturer_supplier(manufacturer_uuid, &1))
    Enum.each(to_remove, &unlink_manufacturer_supplier(manufacturer_uuid, &1))

    :ok
  end

  @doc "Sync the manufacturer links for a supplier to match the given list of manufacturer UUIDs."
  def sync_supplier_manufacturers(supplier_uuid, manufacturer_uuids)
      when is_list(manufacturer_uuids) do
    current = linked_manufacturer_uuids(supplier_uuid) |> MapSet.new()
    desired = MapSet.new(manufacturer_uuids)

    to_add = MapSet.difference(desired, current)
    to_remove = MapSet.difference(current, desired)

    Enum.each(to_add, &link_manufacturer_supplier(&1, supplier_uuid))
    Enum.each(to_remove, &unlink_manufacturer_supplier(&1, supplier_uuid))

    :ok
  end

  # ═══════════════════════════════════════════════════════════════════
  # Catalogues
  # ═══════════════════════════════════════════════════════════════════

  def list_catalogues(opts \\ []) do
    query = from(c in Catalogue, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [c], c.status == ^status)
      end

    repo().all(query)
  end

  def get_catalogue(uuid), do: repo().get(Catalogue, uuid)

  def get_catalogue!(uuid) do
    Catalogue
    |> repo().get!(uuid)
    |> repo().preload(categories: {from(c in Category, order_by: [asc: :position]), [:items]})
  end

  def create_catalogue(attrs) do
    %Catalogue{}
    |> Catalogue.changeset(attrs)
    |> repo().insert()
  end

  def update_catalogue(%Catalogue{} = catalogue, attrs) do
    catalogue
    |> Catalogue.changeset(attrs)
    |> repo().update()
  end

  def delete_catalogue(%Catalogue{} = catalogue) do
    repo().delete(catalogue)
  end

  def change_catalogue(%Catalogue{} = catalogue, attrs \\ %{}) do
    Catalogue.changeset(catalogue, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Categories
  # ═══════════════════════════════════════════════════════════════════

  def list_categories_for_catalogue(catalogue_uuid) do
    from(c in Category,
      where: c.catalogue_uuid == ^catalogue_uuid,
      order_by: [asc: :position, asc: :name],
      preload: [:items]
    )
    |> repo().all()
  end

  def get_category(uuid), do: repo().get(Category, uuid)
  def get_category!(uuid), do: repo().get!(Category, uuid)

  def create_category(attrs) do
    %Category{}
    |> Category.changeset(attrs)
    |> repo().insert()
  end

  def update_category(%Category{} = category, attrs) do
    category
    |> Category.changeset(attrs)
    |> repo().update()
  end

  def delete_category(%Category{} = category) do
    repo().delete(category)
  end

  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

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

  def list_items_for_category(category_uuid) do
    from(i in Item,
      where: i.category_uuid == ^category_uuid,
      order_by: [asc: :name],
      preload: [:manufacturer]
    )
    |> repo().all()
  end

  def list_items_for_catalogue(catalogue_uuid) do
    from(i in Item,
      join: c in Category,
      on: i.category_uuid == c.uuid,
      where: c.catalogue_uuid == ^catalogue_uuid,
      order_by: [asc: c.position, asc: i.name],
      preload: [:category, :manufacturer]
    )
    |> repo().all()
  end

  def get_item(uuid), do: repo().get(Item, uuid)

  def get_item!(uuid) do
    Item
    |> repo().get!(uuid)
    |> repo().preload([:category, :manufacturer])
  end

  def create_item(attrs) do
    %Item{}
    |> Item.changeset(attrs)
    |> repo().insert()
  end

  def update_item(%Item{} = item, attrs) do
    item
    |> Item.changeset(attrs)
    |> repo().update()
  end

  def delete_item(%Item{} = item) do
    repo().delete(item)
  end

  def change_item(%Item{} = item, attrs \\ %{}) do
    Item.changeset(item, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Multilang helpers
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Gets translated field data for a record in a specific language.

  Returns merged data (primary as base + overrides for the language).
  """
  def get_translation(record, lang_code) do
    Multilang.get_language_data(record.data || %{}, lang_code)
  end

  @doc """
  Updates the multilang `data` field for a record with language-specific field data.

  For primary language: stores ALL fields.
  For secondary languages: stores only overrides (differences from primary).
  """
  def set_translation(record, lang_code, field_data, update_fn) do
    new_data = Multilang.put_language_data(record.data || %{}, lang_code, field_data)
    update_fn.(record, %{data: new_data})
  end
end
