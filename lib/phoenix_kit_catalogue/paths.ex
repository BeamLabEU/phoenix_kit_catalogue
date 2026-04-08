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
end
