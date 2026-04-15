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
    # Per-item markup override. `nil` means "inherit from the parent
    # catalogue's markup_percentage" (the pre-V97 default behavior); any
    # Decimal (including 0) overrides the catalogue's value for this item.
    field(:markup_percentage, :decimal)
    field(:unit, :string, default: "piece")
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})

    belongs_to(:catalogue, PhoenixKitCatalogue.Schemas.Catalogue,
      foreign_key: :catalogue_uuid,
      references: :uuid,
      type: UUIDv7
    )

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

  @required_fields [:name, :catalogue_uuid]
  @optional_fields [
    :description,
    :sku,
    :base_price,
    :markup_percentage,
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
    |> validate_number(:markup_percentage, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:catalogue_uuid)
    |> foreign_key_constraint(:category_uuid)
  end

  @doc """
  Calculates the sale price for an item.

  `catalogue_markup` is the fallback markup used when the item has no
  override of its own. The item's `markup_percentage` takes precedence
  if set (including an explicit `0`, which means "sell at base price
  even if the catalogue has a markup"). A `nil` catalogue_markup with a
  `nil` item override returns the base price unchanged.

  Returns `nil` if the item has no base price. Both percentage values
  should be `Decimal`s (e.g., `Decimal.new("15.0")` for 15%).

  ## Examples

      # Item has no override — inherits catalogue's 20%
      Item.sale_price(%Item{base_price: Decimal.new("100"), markup_percentage: nil}, Decimal.new("20"))
      #=> Decimal.new("120.00")

      # Item explicitly overrides to 50% — catalogue markup is ignored
      Item.sale_price(%Item{base_price: Decimal.new("100"), markup_percentage: Decimal.new("50")}, Decimal.new("20"))
      #=> Decimal.new("150.00")

      # Item override of 0 means "sell at base price" even if catalogue marks up
      Item.sale_price(%Item{base_price: Decimal.new("100"), markup_percentage: Decimal.new("0")}, Decimal.new("20"))
      #=> Decimal.new("100.00")
  """
  def sale_price(%__MODULE__{base_price: nil}, _catalogue_markup), do: nil

  def sale_price(%__MODULE__{base_price: base_price} = item, catalogue_markup) do
    case effective_markup(item, catalogue_markup) do
      nil ->
        base_price

      markup ->
        multiplier = Decimal.add(Decimal.new("1"), Decimal.div(markup, Decimal.new("100")))
        base_price |> Decimal.mult(multiplier) |> Decimal.round(2)
    end
  end

  @doc """
  Returns the markup percentage that actually applies to an item — the
  item's own `markup_percentage` if set, otherwise `catalogue_markup`.

  `nil` on both sides means "no markup at all" and the item should be
  sold at its base price. Callers that only need to *display* which
  markup is active (without computing a price) can use this directly.
  """
  def effective_markup(%__MODULE__{markup_percentage: nil}, catalogue_markup),
    do: catalogue_markup

  def effective_markup(%__MODULE__{markup_percentage: override}, _catalogue_markup),
    do: override
end
