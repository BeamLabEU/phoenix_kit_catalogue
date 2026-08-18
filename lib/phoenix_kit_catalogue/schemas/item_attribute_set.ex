defmodule PhoenixKitCatalogue.Schemas.ItemAttributeSet do
  @moduledoc """
  Join row: an item's attachment of one attribute SET (a managed
  entities blueprint — "Ikea colors"). Items attach any number of sets,
  ordered by `position`.

  `set_uuid` references `phoenix_kit_entities.uuid` with **no FK** — the
  entities delete path consults the catalogue's registered delete guard
  (`AttributeSets.deletion_guard/1`) and the catalogue cleans orphans off
  entities PubSub events; see the V176 migration moduledoc for why a
  hard cross-module FK is wrong here.

  `data` is reserved per-attachment state (see the 2026-08-18 design
  doc's Future directions): known future keys are
  `"disabled_value_slugs"` and `"selected_value_slug"`. Readers must
  tolerate unknown keys; this schema only round-trips the map.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type UUIDv7

  schema "phoenix_kit_cat_item_attribute_sets" do
    field(:item_uuid, UUIDv7, primary_key: true)
    field(:set_uuid, Ecto.UUID, primary_key: true)
    field(:position, :integer, default: 0)
    field(:data, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:item_uuid, :set_uuid, :position, :data])
    |> validate_required([:item_uuid, :set_uuid])
    |> unique_constraint([:item_uuid, :set_uuid],
      name: :phoenix_kit_cat_item_attribute_sets_pkey
    )
    |> foreign_key_constraint(:item_uuid)
  end
end
