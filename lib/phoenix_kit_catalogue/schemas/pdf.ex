defmodule PhoenixKitCatalogue.Schemas.Pdf do
  @moduledoc """
  Per-upload row in the catalogue's PDF library.

  Thin layer on top of `phoenix_kit_files` (core's storage). One row
  per "user uploaded this name". Two uploads of identical content with
  different filenames produce two rows sharing one `file_uuid` (and
  one extraction, and one set of cached page rows).

  Lifecycle (`status` column, workspace soft-delete convention):
  `"active"` — visible in the library
  `"trashed"` — moved to trash; `trashed_at` set; rows hidden by
                default but recoverable.

  The `file_uuid` FK is `ON DELETE RESTRICT` — core's prune cannot
  remove a file referenced by any catalogue row. Catalogue's
  permanent-delete flow checks the per-file refcount and only hands
  off to core's `Storage.trash_file/1` when no PDF row remains.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active trashed)

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  schema "phoenix_kit_cat_pdfs" do
    field(:file_uuid, UUIDv7)
    field(:original_filename, :string)
    field(:byte_size, :integer)
    field(:status, :string, default: "active")
    field(:trashed_at, :utc_datetime)

    belongs_to(:extraction, PhoenixKitCatalogue.Schemas.PdfExtraction,
      foreign_key: :file_uuid,
      references: :file_uuid,
      type: UUIDv7,
      define_field: false
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:file_uuid, :original_filename]
  @optional_fields [:byte_size, :status, :trashed_at]

  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t(t())
  def changeset(pdf, attrs) do
    pdf
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:original_filename, max: 500)
    |> validate_inclusion(:status, @statuses)
  end

  @spec trash_changeset(t()) :: Ecto.Changeset.t(t())
  def trash_changeset(pdf) do
    change(pdf, status: "trashed", trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @spec restore_changeset(t()) :: Ecto.Changeset.t(t())
  def restore_changeset(pdf) do
    change(pdf, status: "active", trashed_at: nil)
  end
end
