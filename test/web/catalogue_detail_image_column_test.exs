defmodule PhoenixKitCatalogue.Web.CatalogueDetailImageColumnTest do
  @moduledoc """
  The managed "Image" column (`TableConfig.columns/1`'s `"image"` id,
  off by default) on the catalogue detail page's item and category
  tables — a plain opt-in twin of the automatic photo column
  (`any_media_thumb?/2` / `featured_thumb/1`) that an admin turns on
  through the Columns modal like any other field.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  defp url(uuid), do: "#{@base}/#{uuid}"

  test "the Image column is offered in the Columns modal but off by default", %{conn: conn} do
    catalogue = fixture_catalogue(%{name: "Img cols"})
    fixture_item(%{name: "Widget", catalogue_uuid: catalogue.uuid})

    {:ok, view, html} = live(conn, url(catalogue.uuid) <> "?mode=items")
    refute html =~ ~s(phx-value-column_id="image")

    opened = render_click(view, "show_column_modal", %{})
    assert opened =~ ~s(phx-value-column_id="image")
    assert opened =~ ~s(phx-value-scope="detail_items")
  end

  test "adding it renders the item's featured image via the small storage variant",
       %{conn: conn} do
    catalogue = fixture_catalogue(%{name: "Img item"})

    item =
      fixture_item(%{name: "Widget", catalogue_uuid: catalogue.uuid})

    {:ok, item} =
      Catalogue.update_item(item, %{data: %{"featured_image_uuid" => UUIDv7.generate()}})

    {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")
    render_click(view, "show_column_modal", %{})

    updated =
      render_click(view, "add_column", %{"column_id" => "image", "scope" => "detail_items"})

    assert updated =~ "/small/"
    assert updated =~ item.data["featured_image_uuid"]
  end

  test "an item with no featured image renders empty space, not a broken image", %{conn: conn} do
    catalogue = fixture_catalogue(%{name: "Img item empty"})
    fixture_item(%{name: "Widget", catalogue_uuid: catalogue.uuid})

    {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")
    render_click(view, "show_column_modal", %{})

    updated =
      render_click(view, "add_column", %{"column_id" => "image", "scope" => "detail_items"})

    assert updated =~ "Widget"
    refute updated =~ "/small/"
  end

  test "adding it renders the category's featured image via the small storage variant",
       %{conn: conn} do
    catalogue = fixture_catalogue(%{name: "Img category"})
    category = fixture_category(catalogue, %{name: "Configurable"})

    {:ok, category} =
      Catalogue.update_category(category, %{
        data: %{"featured_image_uuid" => UUIDv7.generate()}
      })

    {:ok, view, _html} = live(conn, url(catalogue.uuid))
    render_click(view, "show_column_modal", %{})

    updated =
      render_click(view, "add_column", %{
        "column_id" => "image",
        "scope" => "detail_categories"
      })

    assert updated =~ "/small/"
    assert updated =~ category.data["featured_image_uuid"]
  end
end
