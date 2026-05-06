defmodule PhoenixKitCatalogue.Schemas.PdfPage do
  @moduledoc """
  Per-page join row keyed by `(file_uuid, page_number)`.

  Rows reference the file (cascade on file hard delete) and the
  `phoenix_kit_cat_pdf_page_contents` cache by `content_hash`.

  No `text` column here — the actual page text lives in the dedup
  cache. To read page text, join to `:content`.

  No `updated_at` — pages are write-once; re-extraction means
  deleting and re-inserting (or hard-deleting the file and
  re-uploading).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type UUIDv7

  schema "phoenix_kit_cat_pdf_pages" do
    field(:file_uuid, UUIDv7, primary_key: true)
    field(:page_number, :integer, primary_key: true)
    field(:inserted_at, :utc_datetime)

    belongs_to(:content, PhoenixKitCatalogue.Schemas.PdfPageContent,
      foreign_key: :content_hash,
      references: :content_hash,
      type: :string,
      define_field: true
    )
  end

  @required_fields [:file_uuid, :page_number, :content_hash, :inserted_at]

  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t(t())
  def changeset(page, attrs) do
    page
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_number(:page_number, greater_than_or_equal_to: 1)
    |> unique_constraint([:file_uuid, :page_number],
      name: :phoenix_kit_cat_pdf_pages_pkey
    )
  end
end
