defmodule PhoenixKitCatalogue.Schemas.PdfExtraction do
  @moduledoc """
  Extraction state for one unique PDF file content.

  Keyed by `file_uuid` (PK) — one row per unique
  `phoenix_kit_files.uuid`, regardless of how many times that content
  was uploaded under different filenames. The worker's state machine
  lives here, not on `Pdf`, so two uploads of the same content share
  one extraction job + one extracted page set.

  Status flow: `pending → extracting → extracted | scanned_no_text |
  failed`. Cascades on the file row's hard delete.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:file_uuid, UUIDv7, autogenerate: false}
  @foreign_key_type UUIDv7

  @statuses ~w(pending extracting extracted scanned_no_text failed)

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  schema "phoenix_kit_cat_pdf_extractions" do
    field(:extraction_status, :string, default: "pending")
    field(:page_count, :integer)
    field(:extracted_at, :utc_datetime)
    field(:error_message, :string)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:file_uuid]
  @optional_fields [:extraction_status, :page_count, :extracted_at, :error_message]

  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t(t())
  def changeset(extraction, attrs) do
    extraction
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:extraction_status, @statuses)
    |> validate_number(:page_count, greater_than_or_equal_to: 0)
  end

  @spec status_changeset(t(), map()) :: Ecto.Changeset.t(t())
  def status_changeset(extraction, attrs) do
    extraction
    |> cast(attrs, [:extraction_status, :page_count, :extracted_at, :error_message])
    |> validate_inclusion(:extraction_status, @statuses)
    |> validate_number(:page_count, greater_than_or_equal_to: 0)
  end
end
