defmodule PhoenixKitCatalogue.Schemas.AttributeGroup do
  @moduledoc """
  Schema for attribute groups — reusable, translatable sets of product
  characteristics ("Idea doors": Color, Trim, Surface…).

  Groups are global (cross-catalogue). `name` holds the primary-language
  display text; other languages live in `data` per the module's multilang
  convention. `status` `"archived"` is not deletion: an archived group
  stays readable on items that hold it but leaves the assignment picker.
  A group referenced by any item cannot be hard-deleted (RESTRICT FK from
  the assignment table); unreferenced groups delete via the context's
  explicit transactional cascade.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active archived)

  schema "phoenix_kit_cat_attribute_groups" do
    field(:name, :string)
    field(:data, :map, default: %{})
    field(:status, :string, default: "active")
    field(:position, :integer, default: 0)

    has_many(:attributes, PhoenixKitCatalogue.Schemas.Attribute,
      foreign_key: :group_uuid,
      references: :uuid,
      preload_order: [asc: :position]
    )

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :data, :status, :position])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
  end
end
