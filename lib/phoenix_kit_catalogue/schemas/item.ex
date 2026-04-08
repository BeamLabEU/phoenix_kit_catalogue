defmodule PhoenixKitCatalogue.Schemas.Item do
  @moduledoc "Schema for catalogue items — individual products/materials with SKU and pricing."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active inactive discontinued deleted)
  @units ~w(piece set pair sheet m2 running_meter)

  def allowed_units, do: @units

  schema "phoenix_kit_cat_items" do
    field(:name, :string)
    field(:description, :string)
    field(:sku, :string)
    field(:base_price, :decimal)
    field(:unit, :string, default: "piece")
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})

    belongs_to(:category, PhoenixKitCatalogue.Schemas.Category,
      foreign_key: :category_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:manufacturer, PhoenixKitCatalogue.Schemas.Manufacturer,
      foreign_key: :manufacturer_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [
    :description,
    :sku,
    :base_price,
    :unit,
    :status,
    :category_uuid,
    :manufacturer_uuid,
    :data
  ]

  def changeset(item, attrs) do
    item
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:sku, max: 100)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:unit, @units)
    |> validate_number(:base_price, greater_than_or_equal_to: 0)
  end

  @doc """
  Calculates the sale price for an item given a markup percentage.

  Returns `nil` if the item has no base price.
  The markup_percentage should be a Decimal (e.g., `Decimal.new("15.0")` for 15%).

  ## Examples

      Item.sale_price(item, Decimal.new("20.0"))  # base_price * 1.20
      Item.sale_price(item, nil)                   # returns base_price unchanged
  """
  def sale_price(%__MODULE__{base_price: nil}, _markup_percentage), do: nil

  def sale_price(%__MODULE__{base_price: base_price}, nil), do: base_price

  def sale_price(%__MODULE__{base_price: base_price}, markup_percentage) do
    multiplier = Decimal.add(Decimal.new("1"), Decimal.div(markup_percentage, Decimal.new("100")))
    Decimal.mult(base_price, multiplier) |> Decimal.round(2)
  end
end
