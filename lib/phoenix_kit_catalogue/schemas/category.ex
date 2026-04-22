defmodule PhoenixKitCatalogue.Schemas.Category do
  @moduledoc "Schema for categories within a catalogue."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active deleted)

  schema "phoenix_kit_cat_categories" do
    field(:name, :string)
    field(:description, :string)
    field(:position, :integer, default: 0)
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})

    belongs_to(:catalogue, PhoenixKitCatalogue.Schemas.Catalogue,
      foreign_key: :catalogue_uuid,
      references: :uuid,
      type: UUIDv7
    )

    # Nullable self-FK — NULL = root category. Cycle detection and
    # same-catalogue enforcement happen in the Catalogue context because
    # they require DB lookups; the changeset only catches self-parent.
    belongs_to(:parent, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid,
      type: UUIDv7
    )

    has_many(:children, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid
    )

    has_many(:items, PhoenixKitCatalogue.Schemas.Item,
      foreign_key: :category_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name, :catalogue_uuid]
  @optional_fields [:description, :position, :status, :data, :parent_uuid]

  def changeset(category, attrs) do
    category
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> validate_not_self_parent()
    |> foreign_key_constraint(:parent_uuid)
  end

  defp validate_not_self_parent(changeset) do
    uuid = get_field(changeset, :uuid)
    parent = get_field(changeset, :parent_uuid)

    if uuid != nil and parent != nil and uuid == parent do
      add_error(changeset, :parent_uuid, "category cannot be its own parent")
    else
      changeset
    end
  end
end
