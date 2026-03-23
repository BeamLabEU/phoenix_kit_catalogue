defmodule PhoenixKitCatalogue.Schemas.Manufacturer do
  @moduledoc "Schema for manufacturers."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active inactive)

  schema "phoenix_kit_cat_manufacturers" do
    field(:name, :string)
    field(:description, :string)
    field(:website, :string)
    field(:contact_info, :string)
    field(:logo_url, :string)
    field(:notes, :string)
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})

    has_many(:manufacturer_suppliers, PhoenixKitCatalogue.Schemas.ManufacturerSupplier,
      foreign_key: :manufacturer_uuid,
      references: :uuid
    )

    has_many(:suppliers, through: [:manufacturer_suppliers, :supplier])

    has_many(:items, PhoenixKitCatalogue.Schemas.Item,
      foreign_key: :manufacturer_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [:description, :website, :contact_info, :logo_url, :notes, :status, :data]

  def changeset(manufacturer, attrs) do
    manufacturer
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:website, max: 500)
    |> validate_length(:contact_info, max: 500)
    |> validate_length(:logo_url, max: 500)
    |> validate_inclusion(:status, @statuses)
  end
end
