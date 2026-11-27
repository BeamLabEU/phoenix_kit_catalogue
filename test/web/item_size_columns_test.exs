defmodule PhoenixKitCatalogue.Web.ItemSizeColumnsTest do
  @moduledoc """
  The V7 size columns on the catalogue detail page's item list: off by
  default, shown in the table and the card view once picked, and sortable
  from the header and the View options sort — items without the value
  last in either direction.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Web.Components
  alias PhoenixKitCatalogue.Web.TableConfig
  alias PhoenixKitCatalogue.Web.ViewConfig

  @base "/en/admin/catalogues"
  @header ~s(th button[phx-click="toggle_sort_items"])

  setup do
    catalogue = fixture_catalogue(%{name: "Sheet goods"})

    sheet = fn name, thickness ->
      fixture_item(%{
        name: name,
        catalogue_uuid: catalogue.uuid,
        unit: "sheet",
        length_mm: 2500,
        width_mm: 1250,
        thickness_mm: thickness,
        pack_size: 40
      })
    end

    %{
      catalogue: catalogue,
      t18: sheet.("P 18", 18),
      t65: sheet.("P 6.5", "6.5"),
      t12: sheet.("P 12", 12),
      bare: fixture_item(%{name: "P bare", catalogue_uuid: catalogue.uuid})
    }
  end

  defp row_text(view, item),
    do: view |> element("#level-items-active tr[data-id='#{item.uuid}']") |> render()

  defp row_order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#level-items-active tbody tr[data-id]")
    |> LazyHTML.attribute("data-id")
  end

  defp open_with_columns(ctx, columns) do
    user = Auth.get_user!(ctx.scope.user.uuid)
    {:ok, _} = ViewConfig.save_columns(user, :detail_items, columns)

    {:ok, view, _html} =
      ctx.conn |> with_scope(ctx.scope) |> live("#{@base}/#{ctx.catalogue.uuid}")

    render_click(view, "set_view", %{"mode" => "table"})
    view
  end

  test "the size columns are optional, sortable and each has a fitting priority" do
    columns = TableConfig.columns(:detail_items)

    for id <- Components.size_columns() do
      column = Enum.find(columns, &(&1.id == id))
      assert column, id
      assert column.sortable?
      refute column.default?
      assert column.label.() == Components.size_column_label(id)
      assert Components.column_priority(id) in [3, 4]
    end
  end

  test "off by default", ctx do
    {:ok, view, _html} = live(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}")
    render_click(view, "set_view", %{"mode" => "table"})

    refute has_element?(view, "#level-items-active th", "Thickness (mm)")
    refute has_element?(view, "#level-items-active th", "Volume (m³)")
  end

  test "picked, they show exact values in the table and “—” for an item without", ctx do
    view = open_with_columns(ctx, ["sku", "thickness_mm", "volume_m3", "pack_size"])

    assert has_element?(view, "#level-items-active th", "Thickness (mm)")
    assert has_element?(view, "#level-items-active th", "Volume (m³)")
    assert has_element?(view, "#level-items-active th", "Pack size")

    assert row_text(view, ctx.t18) =~ "0.05625"
    assert row_text(view, ctx.t65) =~ "6.5"
    assert row_text(view, ctx.t65) =~ "0.0203125"
    refute row_text(view, ctx.t18) =~ "18.000"
    refute row_text(view, ctx.bare) =~ "0.0"
  end

  test "the card view shows them too", ctx do
    view = open_with_columns(ctx, ["thickness_mm", "area_m2"])
    html = render_click(view, "set_view", %{"mode" => "card"})

    assert html =~ "Thickness (mm)"
    assert html =~ "Area (m²)"
    assert html =~ "3.125"
  end

  test "a header sorts by the column; items without the value stay last both ways", ctx do
    view = open_with_columns(ctx, ["thickness_mm"])

    # Headers only sort once the list is out of Manual order.
    render_change(view, "sort_items", %{"sort_by" => "name"})
    assert has_element?(view, ~s(#{@header}[phx-value-by="thickness_mm"]))

    view |> element(~s(#{@header}[phx-value-by="thickness_mm"])) |> render_click()
    assert ViewConfig.load_global_sort(:detail_items) == {"thickness_mm", :asc}
    assert row_order(view) == [ctx.t65.uuid, ctx.t12.uuid, ctx.t18.uuid, ctx.bare.uuid]

    view |> element(~s(#{@header}[phx-value-by="thickness_mm"])) |> render_click()
    assert ViewConfig.load_global_sort(:detail_items) == {"thickness_mm", :desc}
    assert row_order(view) == [ctx.t18.uuid, ctx.t12.uuid, ctx.t65.uuid, ctx.bare.uuid]
  end

  test "the sort select offers the size columns", ctx do
    {:ok, view, html} = live(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}")
    assert html =~ ~s(value="volume_m3")
    assert html =~ ~s(value="thickness_mm")

    render_change(view, "sort_items", %{"sort_by" => "volume_m3"})
    assert ViewConfig.load_global_sort(:detail_items) == {"volume_m3", :asc}
    render_click(view, "set_view", %{"mode" => "table"})
    assert row_order(view) == [ctx.t65.uuid, ctx.t12.uuid, ctx.t18.uuid, ctx.bare.uuid]
  end

  test "a stored sort on a size column survives a reload", ctx do
    {:ok, view, _html} = live(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}")
    render_change(view, "sort_items", %{"sort_by" => "thickness_mm", "sort_dir" => "desc"})

    {:ok, view, _html} = live(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}")
    render_click(view, "set_view", %{"mode" => "table"})
    assert hd(row_order(view)) == ctx.t18.uuid
  end
end
