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
  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}
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

  @doc """
  Creates a supplier-info row.

  When the item has no primary supplier yet, the newly linked row is
  auto-promoted to primary (an item with suppliers but no primary is a
  valid state only when the user explicitly demotes it).
  """
  @spec create(map(), keyword()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, Ecto.Changeset.t(ItemSupplierInfo.t())}
  def create(attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> %ItemSupplierInfo{} |> ItemSupplierInfo.changeset(attrs) |> repo().insert() end,
        fn info ->
          %{
            action: "item_supplier_info.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item_supplier_info",
            resource_uuid: info.uuid,
            metadata: %{
              "item_uuid" => info.item_uuid,
              "supplier_uuid" => info.supplier_uuid,
              "supplier_source" => info.supplier_source
            }
          }
        end
      )

    with {:ok, info} <- result do
      PubSub.broadcast(:item_supplier_info, info.uuid)

      if info.is_primary == false and primary_for_item(info.item_uuid) == nil do
        set_primary(info, opts)
      else
        {:ok, info}
      end
    end
  end

  @doc "Updates a supplier-info row."
  @spec update(ItemSupplierInfo.t(), map(), keyword()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, Ecto.Changeset.t(ItemSupplierInfo.t())}
  def update(%ItemSupplierInfo{} = info, attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> info |> ItemSupplierInfo.changeset(attrs) |> repo().update() end,
        fn updated ->
          %{
            action: "item_supplier_info.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item_supplier_info",
            resource_uuid: updated.uuid,
            metadata: %{"item_uuid" => updated.item_uuid}
          }
        end
      )

    with {:ok, updated} <- result do
      PubSub.broadcast(:item_supplier_info, updated.uuid)
      {:ok, updated}
    end
  end

  @doc "Deletes a supplier-info row."
  @spec delete(ItemSupplierInfo.t(), keyword()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, Ecto.Changeset.t(ItemSupplierInfo.t())}
  def delete(%ItemSupplierInfo{} = info, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> repo().delete(info) end,
        fn deleted ->
          %{
            action: "item_supplier_info.deleted",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item_supplier_info",
            resource_uuid: deleted.uuid,
            metadata: %{
              "item_uuid" => deleted.item_uuid,
              "supplier_uuid" => deleted.supplier_uuid
            }
          }
        end
      )

    with {:ok, deleted} <- result do
      PubSub.broadcast(:item_supplier_info, deleted.uuid)
      {:ok, deleted}
    end
  end

  @doc """
  Promotes a supplier-info row to primary for its item.

  Runs in a transaction: clears `is_primary` on all sibling rows first,
  then sets `is_primary: true` on the target. Respects the partial unique
  index — concurrent callers produce a constraint violation rather than
  double-marking.
  """
  @spec set_primary(ItemSupplierInfo.t(), keyword()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, any()}
  def set_primary(%ItemSupplierInfo{} = info, opts \\ []) do
    Multi.new()
    |> Multi.update_all(
      :clear_primary,
      from(i in ItemSupplierInfo,
        where: i.item_uuid == ^info.item_uuid and i.is_primary == true
      ),
      set: [is_primary: false]
    )
    # force_change: when `info` is already the in-memory primary (e.g. the
    # auto-promoted first row), a plain changeset diffs to empty and the
    # UPDATE is skipped — while clear_primary above has just demoted the DB
    # row, silently leaving the item with no primary at all.
    |> Multi.update(
      :set_primary,
      info
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:is_primary, true)
      |> Ecto.Changeset.unique_constraint(:item_uuid,
        name: :phoenix_kit_cat_item_supplier_info_primary_uniq,
        message: "another supplier is already marked primary for this item"
      )
    )
    |> repo().transaction()
    |> case do
      {:ok, %{set_primary: updated}} ->
        ActivityLog.log(%{
          action: "item_supplier_info.primary_set",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item_supplier_info",
          resource_uuid: updated.uuid,
          metadata: %{"item_uuid" => updated.item_uuid}
        })

        PubSub.broadcast(:item_supplier_info, updated.uuid)
        {:ok, updated}

      {:error, _op, reason, _changes} ->
        {:error, reason}
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
