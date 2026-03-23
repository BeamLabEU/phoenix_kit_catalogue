defmodule PhoenixKitCatalogue.Schemas.Supplier do
  @moduledoc "Schema for suppliers."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active inactive)

  schema "phoenix_kit_cat_suppliers" do
    field(:name, :string)
    field(:description, :string)
    field(:website, :string)
    field(:contact_info, :string)
    field(:notes, :string)
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})

    has_many(:manufacturer_suppliers, PhoenixKitCatalogue.Schemas.ManufacturerSupplier,
      foreign_key: :supplier_uuid,
      references: :uuid
    )

    has_many(:manufacturers, through: [:manufacturer_suppliers, :manufacturer])

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [:description, :website, :contact_info, :notes, :status, :data]

  def changeset(supplier, attrs) do
    supplier
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:website, max: 500)
    |> validate_length(:contact_info, max: 500)
    |> validate_inclusion(:status, @statuses)
  end
end
