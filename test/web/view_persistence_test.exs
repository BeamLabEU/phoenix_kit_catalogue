defmodule PhoenixKitCatalogue.Web.ViewPersistenceTest do
  @moduledoc """
  The card/comfy/table choice is ONE per-user preference for the whole
  module (boss via Max, 2026-08-28: it should stay when you switch to a
  different page). Before this, each surface kept its own — and two of
  them kept theirs in the browser's localStorage — so a choice made on
  the catalogues index never reached the catalogue you opened next.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Web.ViewConfig

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "View Pref Cat"})
    fixture_item(%{name: "View Pref Item", catalogue_uuid: catalogue.uuid})
    %{conn: with_scope(conn, scope), catalogue: catalogue, user: scope.user}
  end

  test "choosing a view on the index changes what every other page opens with",
       %{conn: conn, catalogue: catalogue, user: user} do
    {:ok, index, _html} = live(conn, "/en/admin/catalogue")
    render_click(index, "set_view", %{"mode" => "table"})

    # Stored against the user, not the page…
    assert ViewConfig.load_view(reload_user(user)) == "table"

    # …so the detail page, the attributes tab and the PDF library all
    # open in it rather than in whatever they last remembered.
    {:ok, detail, _} = live(conn, "/en/admin/catalogue/#{catalogue.uuid}")
    assert :sys.get_state(detail.pid).socket.assigns.view_mode_pref == "table"

    {:ok, attrs, _} = live(conn, "/en/admin/catalogue/attributes")
    assert :sys.get_state(attrs.pid).socket.assigns.view_mode == "table"

    {:ok, pdfs, _} = live(conn, "/en/admin/catalogue/pdfs")
    assert :sys.get_state(pdfs.pid).socket.assigns.view_mode == "table"
  end

  test "and it travels the other way too", %{conn: conn, catalogue: catalogue, user: user} do
    {:ok, detail, _} = live(conn, "/en/admin/catalogue/#{catalogue.uuid}")
    render_click(detail, "set_view", %{"mode" => "card"})

    assert ViewConfig.load_view(reload_user(user)) == "card"

    {:ok, index, _} = live(conn, "/en/admin/catalogue")
    assert :sys.get_state(index.pid).socket.assigns.view_configs.catalogues.view == "card"
  end

  test "an unknown mode is ignored rather than blanking the page", %{conn: conn, user: user} do
    {:ok, index, _} = live(conn, "/en/admin/catalogue")

    # The payload is client-forgeable, so an unknown mode is ignored by
    # a catch-all rather than crashing the LiveView, and nothing is
    # persisted.
    render_click(index, "set_view", %{"mode" => "sideways"})
    assert ViewConfig.load_view(reload_user(user)) == "comfy"
    assert :sys.get_state(index.pid).socket.assigns.view_configs.catalogues.view == "comfy"
  end

  defp reload_user(%{uuid: uuid}), do: Auth.get_user!(uuid)
  defp reload_user(other), do: other
end
