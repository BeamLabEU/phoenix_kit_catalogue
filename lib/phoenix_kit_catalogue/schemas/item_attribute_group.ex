defmodule PhoenixKitCatalogue.Schemas.ItemAttributeGroup do
  @moduledoc """
  Item ↔ attribute-group assignment row.

  A join table from day one: the current one-group-per-item business rule
  is carried by the DB's `UNIQUE (item_uuid)` index (surfaced here as a
  `unique_constraint`), so the planned multi-group future is one index
  swap, not a data migration. The row's own UUID is the durable parent
  future per-item narrowing state will hang off.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_cat_item_attribute_groups" do
    field(:position, :integer, default: 0)

    belongs_to(:item, PhoenixKitCatalogue.Schemas.Item,
      foreign_key: :item_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:attribute_group, PhoenixKitCatalogue.Schemas.AttributeGroup,
      foreign_key: :attribute_group_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:item_uuid, :attribute_group_uuid, :position])
    |> validate_required([:item_uuid, :attribute_group_uuid])
    |> unique_constraint(:item_uuid, name: :phoenix_kit_cat_item_attr_groups_item_index)
    |> foreign_key_constraint(:item_uuid)
    |> foreign_key_constraint(:attribute_group_uuid)
  end
end
