defmodule PhoenixKitCatalogue.Web.InternalCataloguePopupsTest do
  @moduledoc """
  An `internal` catalogue in the three embeddable components: left out
  even where the host's scope names it (the real host always passes an
  explicit list), shown again with `include_internal`, and reachable "by
  a direct link" — an item already preselected stays usable. Also the
  modal's optional `show_dependencies` row, which never names a target
  the popup hides.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  setup do
    showroom = fixture_catalogue(%{name: "Showroom"})
    nails = fixture_catalogue(%{name: "Nail Stock", internal: true})
    chair = fixture_item(%{name: "Oak chair", sku: "CH-1", catalogue_uuid: showroom.uuid})
    nail = fixture_item(%{name: "Steel nail", sku: "NL-1", catalogue_uuid: nails.uuid})
    %{showroom: showroom, nails: nails, chair: chair, nail: nail}
  end

  defp open(conn, query), do: live(conn, "/test/selector-host?#{query}")
  defp picker(view), do: with_target(view, "#picker")

  describe "ItemSelectorModal" do
    test "a multi-catalogue scope that names an internal catalogue offers no tile for it", ctx do
      {:ok, view, html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}&c2=#{ctx.nails.uuid}")

      # One catalogue is left to offer, so the popup opens in it: its items
      # and no catalogue-first level naming the hidden one.
      assert html =~ "Oak chair"
      refute html =~ "Nail Stock"
      refute html =~ "Steel nail"

      # Searching the whole scope does not reach its items either.
      html = view |> picker() |> render_change("browse_search", %{"search" => "a"})
      assert html =~ "Oak chair"
      refute html =~ "Steel nail"
    end

    test "a crafted drill into the hidden catalogue lists nothing from it", ctx do
      {:ok, view, _html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}&c2=#{ctx.nails.uuid}")

      html = view |> picker() |> render_click("browse_catalogue", %{"uuid" => ctx.nails.uuid})
      refute html =~ "Steel nail"
    end

    test "a scope of only internal catalogues says there is nothing to choose", ctx do
      {:ok, _view, html} = open(conn_of(ctx), "c=#{ctx.nails.uuid}")

      refute html =~ "Steel nail"
      # Neither the tree nor the header names it.
      refute html =~ "Nail Stock"
      assert html =~ "There is nothing to choose from here."
    end

    test "a category scope inside an internal catalogue gets no header naming it", ctx do
      box = fixture_category(ctx.nails, %{name: "Nail box", description: "Boxed nails"})
      {:ok, _view, html} = open(conn_of(ctx), "cat_scope=#{box.uuid}")
      refute html =~ "Boxed nails"

      {:ok, _view, html} = open(conn_of(ctx), "cat_scope=#{box.uuid}&ii=true")
      assert html =~ "Boxed nails"
    end

    test "include_internal shows it again", ctx do
      {:ok, _view, html} = open(conn_of(ctx), "c=#{ctx.nails.uuid}&ii=true")

      assert html =~ "Steel nail"
      refute html =~ "There is nothing to choose from here."
    end

    test "an item already linked (preselected) stays usable", ctx do
      {:ok, view, _html} =
        open(conn_of(ctx), "c=#{ctx.showroom.uuid}&c2=#{ctx.nails.uuid}&pre=#{ctx.nail.uuid}:3")

      view |> picker() |> render_click("confirm", %{})
      assert has_element?(view, "#pick-#{ctx.nail.uuid}", "qty=3")
    end

    test "a preselected internal item's details stay closed (review finding)", ctx do
      {:ok, view, _html} =
        open(conn_of(ctx), "c=#{ctx.showroom.uuid}&c2=#{ctx.nails.uuid}&pre=#{ctx.nail.uuid}:1")

      view |> picker() |> render_click("show_detail", %{"uuid" => ctx.nail.uuid})
      refute has_element?(view, "#picker-detail-card")

      {:ok, view, _html} =
        open(
          conn_of(ctx),
          "c=#{ctx.showroom.uuid}&c2=#{ctx.nails.uuid}&pre=#{ctx.nail.uuid}:1&ii=true"
        )

      view |> picker() |> render_click("show_detail", %{"uuid" => ctx.nail.uuid})
      assert has_element?(view, "#picker-detail-card")
    end

    test "an open details page and the header close when their catalogue becomes internal",
         ctx do
      {:ok, view, html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}")
      assert html =~ "Showroom"

      view |> picker() |> render_click("show_detail", %{"uuid" => ctx.chair.uuid})
      assert has_element?(view, "#picker-detail-card")

      {:ok, _} = Catalogue.update_catalogue(ctx.showroom, %{internal: true})

      eventually(fn ->
        html = render(view)
        not has_element?(view, "#picker-detail-card") and not (html =~ "Showroom")
      end)
    end

    test "becoming internal while open takes the catalogue out on the next refresh", ctx do
      {:ok, view, html} =
        open(conn_of(ctx), "c=#{ctx.showroom.uuid}&c2=#{ctx.nails.uuid}&ii=false")

      refute html =~ "Nail Stock"

      {:ok, _} = Catalogue.update_catalogue(ctx.showroom, %{internal: true})

      eventually(fn -> render(view) =~ "There is nothing to choose from here." end)
    end
  end

  describe "ItemSelectorModal show_dependencies" do
    setup ctx do
      bracket = fixture_item(%{name: "Bracket", catalogue_uuid: ctx.showroom.uuid})

      {:ok, _} =
        Catalogue.put_item_dependencies(ctx.chair, [
          %{target: {:item, bracket.uuid}, quantity: 4},
          %{target: {:item, ctx.nail.uuid}, quantity: "12.5"}
        ])

      :ok
    end

    defp details(view, uuid),
      do: view |> picker() |> render_click("show_detail", %{"uuid" => uuid})

    test "off by default", ctx do
      {:ok, view, _html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}")
      refute details(view, ctx.chair.uuid) =~ "4 × Bracket"
    end

    test "on, the details page lists them and leaves out what the popup hides", ctx do
      {:ok, view, _html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}&deps=true")
      html = details(view, ctx.chair.uuid)

      assert html =~ "Needs"
      assert html =~ "4 × Bracket"
      refute html =~ "Steel nail"
    end

    test "with include_internal the internal target is named too", ctx do
      {:ok, view, _html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}&deps=true&ii=true")
      assert details(view, ctx.chair.uuid) =~ "12.5 × Steel nail"
    end
  end

  describe "CatalogueBrowse" do
    test "a single internal catalogue gets no category chips either", ctx do
      fixture_category(ctx.nails, %{name: "Roofing nails"})

      {:ok, _view, html} = open(conn_of(ctx), "browse=true&c=#{ctx.nails.uuid}")
      refute html =~ "Roofing nails"

      {:ok, _view, html} = open(conn_of(ctx), "browse=true&c=#{ctx.nails.uuid}&ii=true")
      assert html =~ "Roofing nails"
    end

    test "leaves the internal catalogue's items out unless asked", ctx do
      {:ok, _view, html} =
        open(conn_of(ctx), "browse=true&c=#{ctx.showroom.uuid}&c2=#{ctx.nails.uuid}")

      assert html =~ "Oak chair"
      refute html =~ "Steel nail"

      {:ok, _view, html} =
        open(conn_of(ctx), "browse=true&c=#{ctx.showroom.uuid}&c2=#{ctx.nails.uuid}&ii=true")

      assert html =~ "Steel nail"
    end
  end

  describe "ItemPicker" do
    defmodule PickerHost do
      use Phoenix.LiveView

      import PhoenixKitCatalogue.Web.Components, only: [item_picker: 1]

      def mount(_params, session, socket) do
        {:ok,
         assign(socket,
           catalogue_uuids: session["catalogue_uuids"],
           include_internal: session["include_internal"] == true
         ), layout: false}
      end

      def render(assigns) do
        ~H"""
        <.item_picker
          id="host-picker"
          locale="en"
          catalogue_uuids={@catalogue_uuids}
          include_internal={@include_internal}
        />
        """
      end

      def handle_info(_msg, socket), do: {:noreply, socket}
    end

    defp search(conn, session) do
      {:ok, view, _html} = live_isolated(conn, PickerHost, session: session)
      view |> with_target("#host-picker") |> render_hook("query_change", %{"value" => "a"})
    end

    test "searches past the internal catalogue unless asked", ctx do
      both = [ctx.showroom.uuid, ctx.nails.uuid]

      html = search(ctx.conn, %{"catalogue_uuids" => both})
      assert html =~ "Oak chair"
      refute html =~ "Steel nail"

      html = search(ctx.conn, %{"catalogue_uuids" => both, "include_internal" => true})
      assert html =~ "Steel nail"
    end
  end

  defp conn_of(%{conn: conn}), do: conn

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
