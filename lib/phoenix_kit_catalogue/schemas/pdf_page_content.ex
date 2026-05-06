defmodule PhoenixKitCatalogue.Schemas.PdfPageContent do
  @moduledoc """
  Content-addressed cache of PDF page text.

  Keyed by `content_hash` (SHA-256 hex of the page's normalized text).
  Same page text appearing in multiple PDFs (cross-referenced supplier
  catalogues, shared boilerplate, repeated legal disclaimers) is stored
  once.

  The GIN trigram index lives on `text` here — duplicates indexed only
  once, so the index stays small as the corpus grows.

  Write-once: pages either reference an existing row or insert a new
  one (insert-on-conflict-do-nothing). Orphaned rows (no `pdf_pages`
  row referencing them) are removed by a catalogue-side GC helper, not
  by FK cascade — `pdf_pages.content_hash → ON DELETE RESTRICT` keeps
  the cache stable during normal upload/delete cycles.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:content_hash, :string, autogenerate: false}

  schema "phoenix_kit_cat_pdf_page_contents" do
    field(:text, :string)
    field(:inserted_at, :utc_datetime)
  end

  @required_fields [:content_hash, :text, :inserted_at]

  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t(t())
  def changeset(content, attrs) do
    content
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_length(:content_hash, is: 64)
  end
end
