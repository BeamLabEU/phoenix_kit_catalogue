defmodule PhoenixKitCatalogue.Catalogue.ItemSupplierInfos do
  @moduledoc """
  Context for managing the `phoenix_kit_cat_item_supplier_info` junction table.

  Each row links a catalogue item to a supplier (local or CRM-sourced) and
  carries a snapshot of the supplier's name at write time so the record stays
  readable even after renaming or deletion.

  At most one row per item may have `is_primary: true` — enforced by a partial
  unique index and by `set_primary/1`, which uses a transaction to clear any
  existing primary before promoting the target row.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Lists all supplier-info rows for an item, ordered by position then inserted_at."
  @spec list_for_item(Ecto.UUID.t()) :: [ItemSupplierInfo.t()]
  def list_for_item(item_uuid) do
    from(i in ItemSupplierInfo,
      where: i.item_uuid == ^item_uuid,
      order_by: [asc: :position, asc: :inserted_at]
    )
    |> repo().all()
  end

  @doc "Fetches a supplier-info row by UUID. Returns `nil` if not found."
  @spec get(Ecto.UUID.t()) :: ItemSupplierInfo.t() | nil
  def get(uuid), do: repo().get(ItemSupplierInfo, uuid)

  @doc "Creates a supplier-info row."
  @spec create(map()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, Ecto.Changeset.t(ItemSupplierInfo.t())}
  def create(attrs) do
    %ItemSupplierInfo{}
    |> ItemSupplierInfo.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a supplier-info row."
  @spec update(ItemSupplierInfo.t(), map()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, Ecto.Changeset.t(ItemSupplierInfo.t())}
  def update(%ItemSupplierInfo{} = info, attrs) do
    info
    |> ItemSupplierInfo.changeset(attrs)
    |> repo().update()
  end

  @doc "Deletes a supplier-info row."
  @spec delete(ItemSupplierInfo.t()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, Ecto.Changeset.t(ItemSupplierInfo.t())}
  def delete(%ItemSupplierInfo{} = info), do: repo().delete(info)

  @doc """
  Promotes a supplier-info row to primary for its item.

  Runs in a transaction: clears `is_primary` on all sibling rows first,
  then sets `is_primary: true` on the target. Respects the partial unique
  index — concurrent callers produce a constraint violation rather than
  double-marking.
  """
  @spec set_primary(ItemSupplierInfo.t()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, any()}
  def set_primary(%ItemSupplierInfo{} = info) do
    Multi.new()
    |> Multi.update_all(
      :clear_primary,
      from(i in ItemSupplierInfo,
        where: i.item_uuid == ^info.item_uuid and i.is_primary == true
      ),
      set: [is_primary: false]
    )
    |> Multi.update(:set_primary, ItemSupplierInfo.changeset(info, %{is_primary: true}))
    |> repo().transaction()
    |> case do
      {:ok, %{set_primary: updated}} -> {:ok, updated}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  @doc "Returns the primary supplier-info row for an item, or `nil` if none is marked primary."
  @spec primary_for_item(Ecto.UUID.t()) :: ItemSupplierInfo.t() | nil
  def primary_for_item(item_uuid) do
    from(i in ItemSupplierInfo,
      where: i.item_uuid == ^item_uuid and i.is_primary == true,
      limit: 1
    )
    |> repo().one()
  end
end
