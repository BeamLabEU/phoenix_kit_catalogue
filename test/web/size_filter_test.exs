defmodule PhoenixKitCatalogue.Web.SizeFilterTest do
  @moduledoc """
  The catalogue detail page's size filter: `Web.SizeFilter` reads and
  writes the `?size=` value, and the page narrows its item list, its
  search and its totals by it.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Web.SizeFilter

  @base "/en/admin/catalogues"

  defp d(value), do: Decimal.new(value)

  describe "SizeFilter" do
    test "decode reads each dimension's bounds, open ends included" do
      assert SizeFilter.decode("t:12-18,l:2500-,w:-1250") == %{
               thickness_mm: {d(12), d(18)},
               length_mm: {d(2500), nil},
               width_mm: {nil, d(1250)}
             }

      assert SizeFilter.decode("t:6.5-6.5") == %{thickness_mm: {d("6.5"), d("6.5")}}
    end

    test "decode drops what it cannot read and never raises" do
      assert SizeFilter.decode("") == %{}
      assert SizeFilter.decode(nil) == %{}
      assert SizeFilter.decode("t:-") == %{}
      assert SizeFilter.decode("x:1-2,t:abc-2,t:1e5-,;drop table") == %{}
      assert SizeFilter.decode("t:12-18,bogus,l:-") == %{thickness_mm: {d(12), d(18)}}
      # Beyond the column's range or precision.
      assert SizeFilter.decode("t:12345678-") == %{}
      assert SizeFilter.decode("t:1.2345-") == %{}
    end

    test "encode is decode's inverse, in a fixed order, without trailing zeros" do
      filter = %{thickness_mm: {d("12.0"), d(18)}, length_mm: {d(2500), nil}}
      assert SizeFilter.encode(filter) == "l:2500-,t:12-18"

      assert SizeFilter.decode(SizeFilter.encode(filter)) |> SizeFilter.encode() ==
               "l:2500-,t:12-18"

      assert SizeFilter.encode(%{}) == ""
    end

    test "from_params takes the form's values, comma decimals too, and ignores the rest" do
      params = %{
        "thickness_mm" => %{"min" => " 6,5 ", "max" => "18"},
        "length_mm" => %{"min" => "", "max" => ""},
        "width_mm" => %{"min" => "wide", "max" => "1250"},
        "depth" => %{"min" => "1"}
      }

      assert SizeFilter.from_params(params) == %{
               thickness_mm: {d("6.5"), d(18)},
               width_mm: {nil, d(1250)}
             }

      assert SizeFilter.from_params("nope") == %{}
      assert SizeFilter.from_params(%{"thickness_mm" => "12"}) == %{}
    end

    test "active counts the dimensions with a rule; input_value shows a bound" do
      filter = SizeFilter.decode("t:12-,w:-1250")
      assert SizeFilter.active(filter) == 2
      assert SizeFilter.input_value(filter, :thickness_mm, :min) == "12"
      assert SizeFilter.input_value(filter, :thickness_mm, :max) == ""
      assert SizeFilter.input_value(filter, :length_mm, :min) == ""
    end
  end

  describe "on the catalogue detail page" do
    setup do
      catalogue = fixture_catalogue(%{name: "Sheet goods"})

      sheet = fn name, thickness ->
        fixture_item(%{
          name: name,
          catalogue_uuid: catalogue.uuid,
          unit: "sheet",
          length_mm: 2500,
          width_mm: 1250,
          thickness_mm: thickness
        })
      end

      %{
        catalogue: catalogue,
        t65: sheet.("Ply 6.5", "6.5"),
        t12: sheet.("Ply 12", 12),
        t18: sheet.("Ply 18", 18),
        bare: fixture_item(%{name: "Ply bare", catalogue_uuid: catalogue.uuid})
      }
    end

    defp shown?(view, item),
      do: has_element?(view, "#level-items-active [data-id='#{item.uuid}']")

    defp open_table(conn, path) do
      {:ok, view, html} = live(conn, path)
      render_click(view, "set_view", %{"mode" => "table"})
      {view, html}
    end

    test "the filter is offered where items have sizes, and not elsewhere", ctx do
      {:ok, _view, html} = live(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}")
      assert html =~ ~s(id="catalogue-size-filter")

      plain = fixture_catalogue(%{name: "Hardware"})
      fixture_item(%{name: "Hinge", catalogue_uuid: plain.uuid})
      {:ok, _view, html} = live(ctx.conn, "#{@base}/#{plain.uuid}")
      refute html =~ ~s(id="catalogue-size-filter")
    end

    test "typing a range narrows the list and lands in the URL", ctx do
      {view, _html} = open_table(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}")
      for item <- [ctx.t65, ctx.t12, ctx.t18, ctx.bare], do: assert(shown?(view, item))

      view
      |> form("#catalogue-size-filter", %{
        "size" => %{"thickness_mm" => %{"min" => "12", "max" => "18"}}
      })
      |> render_change()

      assert_patch(view, "#{@base}/#{ctx.catalogue.uuid}?size=t%3A12-18")

      assert shown?(view, ctx.t12)
      assert shown?(view, ctx.t18)
      refute shown?(view, ctx.t65)
      # An item without the dimension never matches a rule on it.
      refute shown?(view, ctx.bare)
      # The Filters button counts it.
      assert has_element?(view, "button[title='Filters'] .badge", "1")
    end

    test "a filtered link opens filtered, with the bounds in the form", ctx do
      {view, html} = open_table(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}?size=t:-6.5")

      assert shown?(view, ctx.t65)
      refute shown?(view, ctx.t12)
      assert html =~ ~s(id="size-filter-thickness_mm-max")
      assert has_element?(view, "#size-filter-thickness_mm-max[value='6.5']")
    end

    test "the search stays inside the filter", ctx do
      {view, _html} = open_table(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}?size=t:12-&q=Ply")
      html = render_async(view)

      assert html =~ "Ply 12"
      assert html =~ "Ply 18"
      refute html =~ "Ply 6.5"
      refute html =~ "Ply bare"
    end

    test "Clear size removes it", ctx do
      {view, _html} = open_table(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}?size=t:18-18")
      refute shown?(view, ctx.t12)

      view |> element("button[phx-click='clear_size_filter']") |> render_click()
      assert_patch(view, "#{@base}/#{ctx.catalogue.uuid}")

      for item <- [ctx.t65, ctx.t12, ctx.t18, ctx.bare], do: assert(shown?(view, item))
      refute has_element?(view, "button[phx-click='clear_size_filter']")
    end

    test "a forged ?size= is no filter, not a crash", ctx do
      {view, _html} =
        open_table(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}?size=t:abc-,x:1-2,%27;--")

      for item <- [ctx.t65, ctx.t12, ctx.t18, ctx.bare], do: assert(shown?(view, item))
    end

    test "a value that is no size is dropped from the form's push", ctx do
      {view, _html} = open_table(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}")

      render_change(view, "set_size_filter", %{
        "size" => %{"thickness_mm" => %{"min" => "thick", "max" => ""}}
      })

      for item <- [ctx.t65, ctx.t12, ctx.t18, ctx.bare], do: assert(shown?(view, item))
      render_change(view, "set_size_filter", %{"size" => "junk"})
      render_change(view, "set_size_filter", %{})
      assert shown?(view, ctx.t18)
    end

    test "the trash is not filtered and has no size control", ctx do
      {:ok, _} = PhoenixKitCatalogue.Catalogue.trash_item(ctx.t65)

      {:ok, view, _html} = live(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}?size=t:18-18")
      html = render_click(view, "switch_view", %{"mode" => "deleted"})

      assert html =~ "Ply 6.5"
      refute html =~ ~s(id="catalogue-size-filter")
    end
  end
end
