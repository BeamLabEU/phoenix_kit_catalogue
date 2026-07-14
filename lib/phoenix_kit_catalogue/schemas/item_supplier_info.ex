defmodule PhoenixKitCatalogue.Schemas.ItemSupplierInfo do
  @moduledoc """
  Junction table row linking a catalogue item to a supplier.

  Each row stores a snapshot of the supplier's name at write time so the
  record remains readable even when the supplier is later renamed or deleted.
  A partial unique index enforces at most one primary row per item.

  There is intentionally NO uniqueness on `(item_uuid, supplier_uuid)`:
  multiple rows per supplier are allowed so future price revisions can
  coexist via `valid_from`/`valid_to` windows (planned purchase-price
  history). The only uniqueness is the partial index on `is_primary`.

  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @sources ~w(crm_company crm_contact local)
  @currency_regex ~r/^[A-Z]{3}$/

  schema "phoenix_kit_cat_item_supplier_info" do
    belongs_to(:item, PhoenixKitCatalogue.Schemas.Item,
      foreign_key: :item_uuid,
      references: :uuid,
      type: UUIDv7
    )

    # soft UUID reference — no FK constraint to support cross-module suppliers
    field(:supplier_uuid, UUIDv7)
    field(:supplier_source, :string, default: "local")
    field(:supplier_name_snapshot, :string)
    field(:supplier_sku, :string)
    field(:unit_cost, :decimal)
    field(:currency, :string)
    field(:lead_time_days, :integer)
    field(:min_order_qty, :decimal)
    field(:is_primary, :boolean, default: false)
    field(:valid_from, :date)
    field(:valid_to, :date)
    field(:position, :integer, default: 0)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @required_fields [:item_uuid, :supplier_uuid, :supplier_source]
  @optional_fields [
    :supplier_name_snapshot,
    :supplier_sku,
    :unit_cost,
    :currency,
    :lead_time_days,
    :min_order_qty,
    :is_primary,
    :valid_from,
    :valid_to,
    :position,
    :metadata
  ]

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(info, attrs) do
    info
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:supplier_source, @sources)
    |> validate_currency()
    |> validate_number(:unit_cost, greater_than_or_equal_to: 0)
    |> validate_number(:min_order_qty, greater_than_or_equal_to: 0)
    |> validate_number(:lead_time_days, greater_than_or_equal_to: 0)
    |> validate_date_range()
    |> foreign_key_constraint(:item_uuid)
    |> unique_constraint(:item_uuid,
      name: :phoenix_kit_cat_item_supplier_info_primary_uniq,
      message: "another supplier is already marked primary for this item"
    )
  end

  defp validate_currency(changeset) do
    case get_field(changeset, :currency) do
      nil ->
        changeset

      "" ->
        changeset

      _currency ->
        validate_format(changeset, :currency, @currency_regex,
          message: "must be 3 uppercase letters (e.g. EUR)"
        )
    end
  end

  defp validate_date_range(changeset) do
    from = get_field(changeset, :valid_from)
    to = get_field(changeset, :valid_to)

    if from && to && Date.compare(from, to) == :gt do
      add_error(changeset, :valid_to, "must be on or after valid_from")
    else
      changeset
    end
  end
end
