defmodule PhoenixKitCatalogue.Schemas.Catalogue do
  @moduledoc "Schema for catalogues — top-level groupings (e.g., Kitchen Furniture, Plumbing)."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active archived deleted)

  schema "phoenix_kit_cat_catalogues" do
    field(:name, :string)
    field(:description, :string)
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})

    has_many(:categories, PhoenixKitCatalogue.Schemas.Category,
      foreign_key: :catalogue_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [:description, :status, :data]

  def changeset(catalogue, attrs) do
    catalogue
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
  end
end
