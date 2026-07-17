defmodule PhoenixKitCatalogue.Catalogue.ItemSupplierInfos do
  @moduledoc """
  Context for managing the `phoenix_kit_cat_item_supplier_info` junction table.

  Each row links a catalogue item to a supplier (local or CRM-sourced) and
  carries a snapshot of the supplier's name at write time so the record stays
  readable even after renaming or deletion.

  At most one row per item may have `is_primary: true` — enforced by a partial
  unique index and by `set_primary/1`, which uses a transaction to clear any
  existing primary before promoting the target row.

  ## Price history via validity windows

  The schema carries `valid_from`/`valid_to` date fields. A row is considered
  *current* when `valid_to` is `nil`. `revise_unit_cost/3` implements a
  non-destructive price revision: the current row is closed (`valid_to: today`,
  `is_primary: false`) and a successor row is inserted with the new cost,
  `valid_from: today`, and `valid_to: nil`. This produces an append-only price
  history ordered by `valid_from` descending. The canonical "current" predicate
  is `is_nil(valid_to)`.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Lists *current* supplier-info rows for an item, ordered by position then
  inserted_at.

  A row is current when `valid_to` is `nil`. Closed rows (produced by
  `revise_unit_cost/3`) are excluded; use `history_for_pair/2` to retrieve the
  full history for a specific item/supplier pair.
  """
  @spec list_for_item(Ecto.UUID.t()) :: [ItemSupplierInfo.t()]
  def list_for_item(item_uuid) do
    from(i in ItemSupplierInfo,
      where: i.item_uuid == ^item_uuid and is_nil(i.valid_to),
      order_by: [asc: :position, asc: :inserted_at]
    )
    |> repo().all()
  end

  @doc """
  Returns all rows for an item/supplier pair ordered newest-first.

  Includes both current (`valid_to: nil`) and closed rows so callers can
  display a full price revision history. Ordered by `valid_from` descending
  (nulls last), then `inserted_at` descending.
  """
  @spec history_for_pair(Ecto.UUID.t(), Ecto.UUID.t()) :: [ItemSupplierInfo.t()]
  def history_for_pair(item_uuid, supplier_uuid) do
    from(i in ItemSupplierInfo,
      where: i.item_uuid == ^item_uuid and i.supplier_uuid == ^supplier_uuid,
      order_by: [desc_nulls_last: :valid_from, desc: :inserted_at]
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

  @doc """
  Returns the *current* primary supplier-info row for an item, or `nil` if
  none is marked primary.

  Only current rows (`valid_to: nil`) are considered — closed revision rows
  carry `is_primary: false` by construction and are excluded.
  """
  @spec primary_for_item(Ecto.UUID.t()) :: ItemSupplierInfo.t() | nil
  def primary_for_item(item_uuid) do
    from(i in ItemSupplierInfo,
      where: i.item_uuid == ^item_uuid and i.is_primary == true and is_nil(i.valid_to),
      limit: 1
    )
    |> repo().one()
  end

  @doc """
  Closes the current junction row and inserts a successor with the new unit
  cost, creating an append-only price revision history.

  ## Guards

    * `{:error, :not_current}` — `info.valid_to` is not `nil`; only the current
      row can be revised.
    * `{:ok, info}` (no-op) — `new_cost` equals `info.unit_cost` (or both
      effectively zero when `unit_cost` is `nil`), *and* `opts[:currency]` is
      either absent or matches the row's current currency. A currency-only
      change (same cost, different `:currency`) still creates a revision.

  ## Transaction

  Within a single Ecto.Multi transaction:

  1. The current row is closed: `valid_to` is set to today and `is_primary` is
     forced to `false` via `force_change/3`, freeing the partial-unique index
     inside the tx so the successor can inherit the primary flag.
  2. A successor row is inserted copying `item_uuid`, `supplier_uuid`,
     `supplier_source`, `supplier_name_snapshot`, `supplier_sku`, `currency`,
     `lead_time_days`, `min_order_qty`, `position`, and `metadata` from the
     closed row. `unit_cost` is set to `new_cost`; `valid_from` is today;
     `valid_to` is `nil`; `is_primary` inherits the original row's value.

  ## Options

    * `:actor_uuid` — UUID of the user performing the revision (persisted in the
      activity log).
    * `:source` — free-form source label (e.g. `"goods_receipt"`).
    * `:source_uuid` — UUID of the originating resource (e.g. receipt UUID).
    * `:currency` — when provided and different from the row's currency, the
      successor stores the new currency; both old and new currencies are
      recorded in the activity metadata.

  ## Currency awareness

  The successor always keeps the row's own currency unless `opts[:currency]` is
  given and differs, in which case the new currency is stored and the activity
  log captures both.
  """
  @spec revise_unit_cost(ItemSupplierInfo.t(), Decimal.t(), keyword()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, :not_current | Ecto.Changeset.t()}
  def revise_unit_cost(%ItemSupplierInfo{} = info, new_cost, opts \\ []) do
    caller_currency = opts[:currency]
    currency_unchanged = is_nil(caller_currency) or caller_currency == info.currency

    cond do
      not is_nil(info.valid_to) ->
        {:error, :not_current}

      Decimal.compare(new_cost, info.unit_cost || Decimal.new(0)) == :eq and
          currency_unchanged ->
        {:ok, info}

      true ->
        do_revise_unit_cost(info, new_cost, opts)
    end
  end

  defp do_revise_unit_cost(%ItemSupplierInfo{} = info, new_cost, opts) do
    today = Date.utc_today()
    original_is_primary = info.is_primary

    caller_currency = opts[:currency]

    new_currency =
      if caller_currency && caller_currency != info.currency,
        do: caller_currency,
        else: info.currency

    close_changeset =
      info
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:valid_to, today)
      |> Ecto.Changeset.force_change(:is_primary, false)

    successor_attrs = %{
      item_uuid: info.item_uuid,
      supplier_uuid: info.supplier_uuid,
      supplier_source: info.supplier_source,
      supplier_name_snapshot: info.supplier_name_snapshot,
      supplier_sku: info.supplier_sku,
      unit_cost: new_cost,
      currency: new_currency,
      lead_time_days: info.lead_time_days,
      min_order_qty: info.min_order_qty,
      is_primary: original_is_primary,
      valid_from: today,
      valid_to: nil,
      position: info.position,
      metadata: info.metadata
    }

    result =
      Multi.new()
      |> Multi.update(:close, close_changeset)
      |> Multi.insert(:successor, fn _ ->
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, successor_attrs)
        |> Ecto.Changeset.unique_constraint(:item_uuid,
          name: :phoenix_kit_cat_item_supplier_info_primary_uniq,
          message: "another supplier is already marked primary for this item"
        )
      end)
      |> repo().transaction()

    case result do
      {:ok, %{successor: successor}} ->
        old_cost_str =
          if info.unit_cost, do: Decimal.to_string(info.unit_cost, :normal), else: nil

        currency_meta =
          if caller_currency && caller_currency != info.currency,
            do: %{"old_currency" => info.currency, "new_currency" => new_currency},
            else: %{}

        ActivityLog.log(%{
          action: "item_supplier_info.cost_revised",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item_supplier_info",
          resource_uuid: successor.uuid,
          metadata:
            Map.merge(
              %{
                "item_uuid" => info.item_uuid,
                "supplier_uuid" => info.supplier_uuid,
                "old_cost" => old_cost_str,
                "new_cost" => Decimal.to_string(new_cost, :normal),
                "source" => opts[:source],
                "source_uuid" => opts[:source_uuid]
              },
              currency_meta
            )
        })

        PubSub.broadcast(:item_supplier_info, successor.uuid)
        {:ok, successor}

      {:error, _op, reason, _changes} ->
        {:error, reason}
    end
  end
end
