defmodule PhoenixKitCatalogue.Schemas.Item do
  @moduledoc "Schema for catalogue items — individual products/materials with SKU and pricing."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active inactive discontinued deleted)
  @units ~w(piece m2 running_meter)

  schema "phoenix_kit_cat_items" do
    field(:name, :string)
    field(:description, :string)
    field(:sku, :string)
    field(:price, :decimal)
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
    :price,
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
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> unique_constraint(:sku)
  end
end
