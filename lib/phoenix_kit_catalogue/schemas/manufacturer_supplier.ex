defmodule PhoenixKitCatalogue.Schemas.ManufacturerSupplier do
  @moduledoc """
  Join table linking manufacturers to suppliers (many-to-many).

  Both sides are FEDERATED references since core V180: a `{uuid, source}` pair
  where source is `"local"` (a catalogue directory row) or `"crm_company"` (a
  CRM party). V180 dropped the two foreign keys that made this graph
  local-only, which also dropped their `ON DELETE CASCADE` — so
  `Catalogue.delete_supplier/2` and `delete_manufacturer/2` clear links
  explicitly now.

  The `belongs_to` associations are kept for the local case, which is still
  what a catalogue-standalone install has. **Do not preload them for a CRM-
  sourced row**: the uuid has no matching local record, so the association
  silently yields `nil`. Resolve through `Suppliers.resolve/1` /
  `Manufacturers.resolve/1` instead, exactly as items do.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
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

    field(:manufacturer_source, :string, default: "local")
    field(:supplier_source, :string, default: "local")

    timestamps(type: :utc_datetime)
  end

  @sources ~w(local crm_company)

  @required_fields [:manufacturer_uuid, :supplier_uuid]
  @optional_fields [:manufacturer_source, :supplier_source]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:manufacturer_source, @sources)
    |> validate_inclusion(:supplier_source, @sources)
    |> unique_constraint([:manufacturer_uuid, :supplier_uuid])
  end
end
