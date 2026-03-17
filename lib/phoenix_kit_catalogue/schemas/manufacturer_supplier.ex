defmodule PhoenixKitCatalogue.Schemas.ManufacturerSupplier do
  @moduledoc "Join table linking manufacturers to suppliers (many-to-many)."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_cat_manufacturer_suppliers" do
    belongs_to(:manufacturer, PhoenixKitCatalogue.Schemas.Manufacturer,
      foreign_key: :manufacturer_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:supplier, PhoenixKitCatalogue.Schemas.Supplier,
      foreign_key: :supplier_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:manufacturer_uuid, :supplier_uuid]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:manufacturer_uuid, :supplier_uuid])
  end
end
