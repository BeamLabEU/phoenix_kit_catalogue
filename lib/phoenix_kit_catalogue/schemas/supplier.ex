defmodule PhoenixKitCatalogue.Schemas.Supplier do
  @moduledoc "Schema for suppliers."

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
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

    # Soft cross-reference to the CRM party this supplier projects (V149).
    # Deliberately absent from @optional_fields: it is set by the link action
    # and the backfill task, never by the supplier form.
    field(:crm_company_uuid, UUIDv7)

    has_many(:manufacturer_suppliers, PhoenixKitCatalogue.Schemas.ManufacturerSupplier,
      foreign_key: :supplier_uuid,
      references: :uuid
    )

    has_many(:manufacturers, through: [:manufacturer_suppliers, :manufacturer])

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [:description, :website, :contact_info, :notes, :status, :data]

  # Identity belongs to the CRM party once this row projects one. Status,
  # notes, description and `data` stay catalogue-local and remain editable.
  @crm_owned_fields [:name, :website, :contact_info]

  def changeset(supplier, attrs) do
    supplier
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:website, max: 500)
    |> validate_length(:contact_info, max: 500)
    |> validate_inclusion(:status, @statuses)
    |> reject_crm_owned_changes()
  end

  @doc """
  The changeset the CRM link/unlink/refresh actions use — the ONE write path
  allowed to set `crm_company_uuid` and to stamp the party's identity onto
  this projection.

  Ordinary `changeset/2` refuses identity edits while the row is linked (see
  `reject_crm_owned_changes/1`), which would otherwise make linking
  impossible: the link action's whole job is to copy the party's name and
  website down, because `phoenix_kit_cat_items` still renders THIS row.
  """
  @spec crm_link_changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def crm_link_changeset(supplier, attrs) do
    supplier
    |> cast(attrs, [:crm_company_uuid | @crm_owned_fields])
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:website, max: 500)
    |> validate_length(:contact_info, max: 500)
    |> unique_constraint(:crm_company_uuid,
      name: :phoenix_kit_cat_suppliers_crm_company_uuid_index,
      message: "is already linked to another supplier"
    )
  end

  # A linked row's identity is a copy of the CRM party's, so letting the
  # catalogue form edit it would silently diverge the two with no way to say
  # which is right. Enforced here rather than only in the form because
  # imports and any future API share this changeset.
  defp reject_crm_owned_changes(changeset) do
    if get_field(changeset, :crm_company_uuid) do
      Enum.reduce(@crm_owned_fields, changeset, &reject_if_changed/2)
    else
      changeset
    end
  end

  defp reject_if_changed(field, changeset) do
    if Map.has_key?(changeset.changes, field) do
      add_error(changeset, field, "is managed in CRM for a linked supplier")
    else
      changeset
    end
  end
end
