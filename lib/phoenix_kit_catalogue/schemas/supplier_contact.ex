defmodule PhoenixKitCatalogue.Schemas.SupplierContact do
  @moduledoc """
  One way to reach a supplier: an email address, a phone number, a person,
  a web address, a postal address, or anything else (`other`), with an
  optional `label` ("Sales", "After hours").

  A supplier has any number per kind and at most one `is_primary` per kind
  (a partial unique index, V8). The supplier's old free-text
  `contact_info` column stays, and is kept as the one-line summary of the
  primaries — see `PhoenixKitCatalogue.Catalogue.SupplierContacts`, the
  only writer of either.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{
          uuid: Ecto.UUID.t() | nil,
          supplier_uuid: Ecto.UUID.t() | nil,
          kind: String.t() | nil,
          value: String.t() | nil,
          label: String.t() | nil,
          is_primary: boolean(),
          position: integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  # Mirrors the V8 CHECK. Keep the two in step. The order is the order the
  # primaries appear in in the `contact_info` summary.
  @kinds ~w(person phone email url address other)

  @max_value_length 500
  @max_label_length 255

  schema "phoenix_kit_cat_supplier_contacts" do
    field(:kind, :string)
    field(:value, :string)
    field(:label, :string)
    field(:is_primary, :boolean, default: false)
    field(:position, :integer, default: 0)

    belongs_to(:supplier, PhoenixKitCatalogue.Schemas.Supplier,
      foreign_key: :supplier_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  @doc "The contact kinds, in summary order."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The longest value a contact takes (the column's own limit)."
  @spec max_value_length() :: pos_integer()
  def max_value_length, do: @max_value_length

  @doc """
  Human-facing name of a kind, translated. An unknown string passes
  through.
  """
  @spec kind_label(term()) :: String.t()
  def kind_label("person"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Person")
  def kind_label("phone"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Phone")
  def kind_label("email"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Email")
  def kind_label("url"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Web address")
  def kind_label("address"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Address")
  def kind_label("other"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Other")
  def kind_label(other) when is_binary(other), do: other
  def kind_label(_), do: ""

  @doc """
  The kind a free-text contact most likely is — `"email"`, `"url"`,
  `"phone"` or `"other"` — for text that arrives without one (the legacy
  `contact_info` column). The same rules as the V8 backfill's SQL `CASE`,
  so a value classified here and one classified by the migration agree.
  """
  @spec classify(String.t()) :: String.t()
  def classify(text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/ -> "email"
      text =~ ~r/^(https?:\/\/|www\.)\S+$/i -> "url"
      text =~ ~r/^\+?[0-9(][0-9 ().\/-]{5,}$/ -> "phone"
      true -> "other"
    end
  end

  @doc """
  Casts and checks one contact: a known kind, a non-blank value within
  `max_value_length/0`, a label within 255 characters, an email that looks
  like one. The primary-per-kind index maps back to an error on
  `:is_primary`.
  """
  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:supplier_uuid, :kind, :value, :label, :is_primary, :position])
    |> update_change(:value, &String.trim/1)
    |> update_change(:label, &blank_to_nil/1)
    |> validate_required([:supplier_uuid, :kind, :value])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:value, max: @max_value_length)
    |> validate_length(:label, max: @max_label_length)
    |> validate_email()
    |> foreign_key_constraint(:supplier_uuid)
    |> unique_constraint(:is_primary,
      name: :phoenix_kit_cat_supplier_contacts_primary_per_kind_index,
      message: "another contact of this kind is already primary"
    )
  end

  defp validate_email(changeset) do
    if get_field(changeset, :kind) == "email" do
      validate_format(changeset, :value, ~r/^[^\s@]+@[^\s@]+$/,
        message: "must be an email address"
      )
    else
      changeset
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
