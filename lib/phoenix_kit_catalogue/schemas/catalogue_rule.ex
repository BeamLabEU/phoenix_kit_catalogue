defmodule PhoenixKitCatalogue.Schemas.CatalogueRule do
  @moduledoc """
  Smart-catalogue rule: one row per `(item, referenced_catalogue)` pair.

  Lets an item in a smart catalogue declare "I apply `value` `unit`
  to this other catalogue" (e.g. 5% of Kitchen, flat $20 of Hardware).

  Both `value` and `unit` are nullable — when `NULL`, the rule inherits
  the parent item's `default_value` / `default_unit`. That lets a user
  set "5% across everything" once and only override specific catalogues.

  The `unit` vocabulary is open-ended VARCHAR so consumers can add new
  units without a migration. V1 recognizes `"percent"` and `"flat"`;
  anything else is stored verbatim and left to the consumer to validate.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          uuid: Ecto.UUID.t() | nil,
          item_uuid: Ecto.UUID.t() | nil,
          referenced_catalogue_uuid: Ecto.UUID.t() | nil,
          value: Decimal.t() | nil,
          unit: String.t() | nil,
          position: integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @units ~w(percent flat)

  @spec allowed_units() :: [String.t()]
  def allowed_units, do: @units

  schema "phoenix_kit_cat_item_catalogue_rules" do
    field(:value, :decimal)
    field(:unit, :string)
    field(:position, :integer, default: 0)

    belongs_to(:item, PhoenixKitCatalogue.Schemas.Item,
      foreign_key: :item_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:referenced_catalogue, PhoenixKitCatalogue.Schemas.Catalogue,
      foreign_key: :referenced_catalogue_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:item_uuid, :referenced_catalogue_uuid]
  @optional_fields [:value, :unit, :position]

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:value, greater_than_or_equal_to: 0)
    |> validate_inclusion(:unit, @units ++ [nil])
    |> foreign_key_constraint(:item_uuid)
    |> foreign_key_constraint(:referenced_catalogue_uuid)
    |> unique_constraint([:item_uuid, :referenced_catalogue_uuid],
      name: :phoenix_kit_cat_item_catalogue_rules_pair_index
    )
  end

  @doc """
  Returns the effective `{value, unit}` for a rule, falling back to the
  item's `default_value` / `default_unit` when the rule row has NULL.

  Each leg is independent: a rule can have its own `value` while
  inheriting `unit` from the item default (or vice versa).

  Returns `{nil, nil}` when nothing is set anywhere — which means
  "applies but amount unspecified"; the consumer decides what to do.

  ## Examples

      # Rule with both legs nil → inherits both from item
      rule = %CatalogueRule{value: nil, unit: nil}
      item = %Item{default_value: Decimal.new("5"), default_unit: "percent"}
      effective(rule, item)
      #=> {Decimal.new("5"), "percent"}

      # Rule overrides value, inherits unit
      rule = %CatalogueRule{value: Decimal.new("10"), unit: nil}
      effective(rule, item)
      #=> {Decimal.new("10"), "percent"}
  """
  @spec effective(t(), PhoenixKitCatalogue.Schemas.Item.t() | map() | nil) ::
          {Decimal.t() | nil, String.t() | nil}
  def effective(%__MODULE__{value: rv, unit: ru}, item) do
    {rv || Map.get(item || %{}, :default_value), ru || Map.get(item || %{}, :default_unit)}
  end
end
