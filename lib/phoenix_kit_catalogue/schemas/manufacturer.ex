defmodule PhoenixKitCatalogue.Schemas.Manufacturer do
  @moduledoc "Schema for manufacturers."

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
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

    # Soft cross-reference to the CRM party this manufacturer projects (V178).
    # Deliberately absent from @optional_fields: it is set by the link action,
    # never by the manufacturer form.
    field(:crm_company_uuid, UUIDv7)

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

  # Identity belongs to the CRM party once this row projects one. `logo_url`
  # is NOT in this list: the brand mark is catalogue presentation, and CRM
  # has nowhere to store it.
  @crm_owned_fields [:name, :website, :contact_info]

  def changeset(manufacturer, attrs) do
    manufacturer
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:website, max: 500)
    |> validate_length(:contact_info, max: 500)
    |> validate_length(:logo_url, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> reject_crm_owned_changes()
  end

  @doc """
  The changeset the CRM link/unlink/refresh actions use — the ONE write path
  allowed to set `crm_company_uuid` and to stamp the party's identity onto
  this projection. See `PhoenixKitCatalogue.Schemas.Supplier.crm_link_changeset/2`.
  """
  @spec crm_link_changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def crm_link_changeset(manufacturer, attrs) do
    manufacturer
    |> cast(attrs, [:crm_company_uuid | @crm_owned_fields])
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:website, max: 500)
    |> validate_length(:contact_info, max: 500)
    |> unique_constraint(:crm_company_uuid,
      name: :phoenix_kit_cat_manufacturers_crm_company_uuid_index,
      message: "is already linked to another manufacturer"
    )
  end

  # See the twin in `PhoenixKitCatalogue.Schemas.Supplier`.
  defp reject_crm_owned_changes(changeset) do
    if get_field(changeset, :crm_company_uuid) do
      Enum.reduce(@crm_owned_fields, changeset, fn field, acc ->
        if Map.has_key?(acc.changes, field) do
          add_error(acc, field, "is managed in CRM for a linked manufacturer")
        else
          acc
        end
      end)
    else
      changeset
    end
  end
end
