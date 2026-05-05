defmodule PhoenixKitCatalogue.Paths do
  @moduledoc """
  Centralized path helpers for the Catalogue module.

  All paths go through `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/catalogue"

  # ── Catalogues ───────────────────────────────────────────────────

  def index, do: Routes.path(@base)
  def catalogue_new, do: Routes.path("#{@base}/new")
  def catalogue_detail(uuid), do: Routes.path("#{@base}/#{uuid}")
  def catalogue_edit(uuid), do: Routes.path("#{@base}/#{uuid}/edit")

  # ── Import ───────────────────────────────────────────────────────

  def import, do: Routes.path("#{@base}/import")

  # ── Events ──────────────────────────────────────────────────────

  def events, do: Routes.path("#{@base}/events")

  # ── Manufacturers ────────────────────────────────────────────────

  def manufacturers, do: Routes.path("#{@base}/manufacturers")
  def manufacturer_new, do: Routes.path("#{@base}/manufacturers/new")
  def manufacturer_edit(uuid), do: Routes.path("#{@base}/manufacturers/#{uuid}/edit")

  # ── Suppliers ────────────────────────────────────────────────────

  def suppliers, do: Routes.path("#{@base}/suppliers")
  def supplier_new, do: Routes.path("#{@base}/suppliers/new")
  def supplier_edit(uuid), do: Routes.path("#{@base}/suppliers/#{uuid}/edit")

  # ── Categories ───────────────────────────────────────────────────

  def category_new(catalogue_uuid), do: Routes.path("#{@base}/#{catalogue_uuid}/categories/new")
  def category_edit(uuid), do: Routes.path("#{@base}/categories/#{uuid}/edit")

  # ── Items ────────────────────────────────────────────────────────

  def item_new(catalogue_uuid), do: Routes.path("#{@base}/#{catalogue_uuid}/items/new")
  def item_edit(uuid), do: Routes.path("#{@base}/items/#{uuid}/edit")

  # ── PDF library ──────────────────────────────────────────────────

  def pdfs, do: Routes.path("#{@base}/pdfs")
  def pdf_detail(uuid), do: Routes.path("#{@base}/pdfs/#{uuid}")

  def pdf_detail(uuid, page) when is_integer(page) and page >= 1,
    do: Routes.path("#{@base}/pdfs/#{uuid}?page=#{page}")

  @doc """
  Signed URL under which the raw PDF binary is served. Resolves via
  core's `Storage.URLSigner` — the host app already routes
  `/file/:file_uuid/:variant/:token` through core's `FileController`.
  """
  def pdf_file(%{file_uuid: file_uuid}) when is_binary(file_uuid) do
    PhoenixKit.Modules.Storage.URLSigner.signed_url(file_uuid, "original")
  end

  @doc """
  Returns the PDF.js viewer URL with the file pre-bound and the
  optional page fragment set. The viewer assets are vendored under
  `priv/static/pdfjs/` and served at `/_pdfjs/` by the host
  endpoint's `Plug.Static` mount.
  """
  def pdf_viewer(pdf, page) when is_integer(page) and page >= 1 do
    "/_pdfjs/web/viewer.html?file=" <> URI.encode(pdf_file(pdf)) <>
      "#page=" <> Integer.to_string(page)
  end

  def pdf_viewer(pdf) do
    "/_pdfjs/web/viewer.html?file=" <> URI.encode(pdf_file(pdf))
  end
end
