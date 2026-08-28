defmodule PhoenixKitCatalogue.Web.CardStyleTest do
  @moduledoc """
  Cards look the same wherever they appear (boss via Max, 2026-08-28: use
  the categories style, where the picture is part of the card). Every card
  face in the module leads with the shared media band — item cards used to
  wedge a 48px thumb beside the title, catalogue cards the same, so the
  same product read as a different kind of thing per page.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Web.Components

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Card Style Cat"})

    {:ok, category} =
      PhoenixKitCatalogue.Catalogue.create_category(%{
        name: "Card Cat",
        catalogue_uuid: catalogue.uuid
      })

    item =
      fixture_item(%{
        name: "Card Item",
        catalogue_uuid: catalogue.uuid,
        category_uuid: category.uuid
      })

    %{conn: with_scope(conn, scope), catalogue: catalogue, category: category, item: item}
  end

  test "one band definition, so pages cannot drift apart" do
    # The frame lives in exactly one place; every card face passes it.
    assert Components.card_media_band() =~ "h-24"
    assert Components.card_media_band() =~ "bg-base-200"
    assert Components.card_media_frame() == %{card_media_class: Components.card_media_band()}
  end

  test "item cards lead with the picture", %{conn: conn, catalogue: catalogue, category: category} do
    {:ok, view, _html} =
      live(conn, "/en/admin/catalogue/#{catalogue.uuid}?category=#{category.uuid}")

    html = render(view)

    # The framed figure, and a placeholder for an item with no photo — so
    # a card without a picture keeps the same shape as one with.
    assert html =~ Components.card_media_band()
    assert html =~ "hero-photo"
  end

  test "catalogue cards lead with the picture too", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/catalogue")
    render_click(view, "set_view", %{"mode" => "card"})

    html = render(view)
    assert html =~ Components.card_media_band()
    # Containers get a container placeholder, not a photo icon.
    assert html =~ "hero-book-open"
  end
end
