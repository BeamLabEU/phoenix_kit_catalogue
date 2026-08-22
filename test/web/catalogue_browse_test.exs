defmodule PhoenixKitCatalogue.Web.Components.CatalogueBrowseTest do
  @moduledoc """
  The embeddable browse surface, driven through the same test host as the
  picker — same scope rules, no selection chrome, one generic message.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  setup do
    cat = fixture_catalogue(%{name: "Browse Cat"})
    other = fixture_catalogue(%{name: "Other Cat"})
    {:ok, item} = Catalogue.create_item(%{name: "Widget", sku: "W-1", catalogue_uuid: cat.uuid})
    {:ok, _} = Catalogue.create_item(%{name: "Elsewhere", catalogue_uuid: other.uuid})
    %{cat: cat, item: item}
  end

  test "renders the scoped grid with no picker chrome", %{conn: conn, cat: cat} do
    {:ok, _view, html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")

    assert html =~ "Widget"
    refute html =~ "Elsewhere"
    # No tray, no confirm — browse only.
    refute html =~ "Confirm selection"
  end

  test "item click reports the generic message to the host", %{
    conn: conn,
    cat: cat,
    item: item
  } do
    {:ok, view, _html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")

    view |> element("#surface-card-#{item.uuid} > button") |> render_click()
    html = render(view)

    assert html =~ ~s(id="clicked")
    assert html =~ "Widget|W-1"
  end

  test "search narrows the surface", %{conn: conn, cat: cat} do
    {:ok, view, _html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")

    html =
      view
      |> with_target("#surface")
      |> render_change("browse_search", %{"search" => "zzz-no-match"})

    refute html =~ "Widget"
    assert html =~ "No items match your search."
  end
end
