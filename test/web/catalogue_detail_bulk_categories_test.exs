defmodule PhoenixKitCatalogue.Web.CatalogueDetailBulkCategoriesTest do
  @moduledoc """
  Category selection on the catalogue page uses the same core BulkSelectScope
  toolkit as the item list, so the root level and a category level select
  and act the same way: client-side checkboxes, a toolbar hidden until a
  selection exists, uuids delivered with the action.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub

  @base "/en/admin/catalogue"

  setup do
    cat = fixture_catalogue(%{name: "Bulk cats"})
    a = fixture_category(cat, %{name: "Alpha"})
    b = fixture_category(cat, %{name: "Beta"})
    c = fixture_category(cat, %{name: "Gamma"})
    %{catalogue: cat, a: a, b: b, c: c}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  test "categories render inside a BulkSelectScope with client-side checkboxes and the same toolbar as items",
       %{conn: conn, catalogue: cat, a: a} do
    {:ok, view, html} = live(conn, "#{@base}/#{cat.uuid}")

    assert has_element?(view, "#categories-bulk-root[phx-hook=BulkSelectScope]")
    assert html =~ ~s(data-bulk-role="row" data-uuid="#{a.uuid}")

    assert has_element?(
             view,
             "#categories-bulk-root [data-bulk-action=request_bulk_delete_categories]"
           )

    assert has_element?(
             view,
             "#categories-bulk-root [data-bulk-action=open_categories_reorder_modal]"
           )

    assert has_element?(view, "#categories-select-all")

    # The server-side toggle is gone: nothing left to click round-trip.
    refute html =~ ~s(phx-click="toggle_select_category")
    refute html =~ "request_bulk_restore_categories"
  end

  test "the delete action receives the selection with the event and opens the bulk trash modal",
       %{conn: conn, catalogue: cat, a: a, b: b} do
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    html = render_click(view, "request_bulk_delete_categories", %{"uuids" => [a.uuid, b.uuid]})

    assert assigns(view).trash_modal.bulk
    assert Enum.sort(assigns(view).trash_modal.bulk_uuids) == Enum.sort([a.uuid, b.uuid])
    assert html =~ "Alpha" or html =~ "Beta"
  end

  test "an empty or forged selection is a no-op", %{conn: conn, catalogue: cat} do
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_bulk_delete_categories", %{})
    refute assigns(view).trash_modal

    render_click(view, "request_bulk_delete_categories", %{"uuids" => [42, nil]})
    refute assigns(view).trash_modal
  end

  test "Reorder N selected re-sequences only the selected categories, within their slots",
       %{conn: conn, catalogue: cat, a: a, b: b, c: c} do
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    # Alpha(0) Beta(1) Gamma(2): select Alpha + Gamma and sort them by name
    # descending — Gamma takes slot 0, Alpha takes slot 2, Beta keeps slot 1.
    render_click(view, "open_categories_reorder_modal", %{"uuids" => [a.uuid, c.uuid]})
    assert Enum.sort(assigns(view).categories_reorder_captured) == Enum.sort([a.uuid, c.uuid])

    render_click(view, "apply_categories_reorder", %{"strategy" => "name_desc"})

    names =
      Catalogue.list_categories_for_catalogue(cat.uuid)
      |> Enum.sort_by(& &1.position)
      |> Enum.map(& &1.name)

    assert names == ["Gamma", "Beta", "Alpha"]
    assert assigns(view).categories_reorder_captured == []
    refute assigns(view).show_categories_reorder
    _ = b
  end

  test "Reorder all (no payload, or a single uuid) reorders every sibling",
       %{conn: conn, catalogue: cat, a: a} do
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "open_categories_reorder_modal", %{"uuids" => [a.uuid]})
    assert assigns(view).categories_reorder_captured == []

    render_click(view, "apply_categories_reorder", %{"strategy" => "name_desc"})

    names =
      Catalogue.list_categories_for_catalogue(cat.uuid)
      |> Enum.sort_by(& &1.position)
      |> Enum.map(& &1.name)

    assert names == ["Gamma", "Beta", "Alpha"]
  end

  describe "Move" do
    test "the modal offers every category except the selection's own subtrees",
         %{conn: conn, catalogue: cat, a: a, b: b, c: c} do
      child = fixture_category(cat, %{name: "Alpha child", parent_uuid: a.uuid})
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

      html = render_click(view, "request_bulk_move_categories", %{"uuids" => [a.uuid, b.uuid]})
      modal = assigns(view).bulk_move_categories_modal
      offered = modal.targets |> Enum.map(fn {c, _} -> c.uuid end)

      assert modal.count == 2
      assert html =~ "Move selected categories"
      # Gamma can take them; Alpha, its child and Beta cannot (self / subtree).
      assert offered == [c.uuid]
      refute child.uuid in offered
    end

    test "nesting under a target re-parents each selected category with its subtree",
         %{conn: conn, catalogue: cat, a: a, b: b, c: c} do
      child = fixture_category(cat, %{name: "Alpha child", parent_uuid: a.uuid})
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

      render_click(view, "request_bulk_move_categories", %{"uuids" => [a.uuid, b.uuid]})
      render_click(view, "set_bulk_move_categories_disposition", %{"disposition" => "move_under"})
      render_click(view, "select_bulk_move_categories_target", %{"category_uuid" => c.uuid})
      html = render_click(view, "confirm_bulk_move_categories", %{})

      assert html =~ "Moved 2 categories."
      assert Catalogue.get_category(a.uuid).parent_uuid == c.uuid
      assert Catalogue.get_category(b.uuid).parent_uuid == c.uuid
      assert Catalogue.get_category(child.uuid).parent_uuid == a.uuid
      refute assigns(view).bulk_move_categories_modal
    end

    test "top level promotes nested categories to the root", %{conn: conn, catalogue: cat, a: a} do
      child = fixture_category(cat, %{name: "Alpha child", parent_uuid: a.uuid})
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}?category=#{a.uuid}")

      render_click(view, "request_bulk_move_categories", %{"uuids" => [child.uuid]})
      render_click(view, "confirm_bulk_move_categories", %{})

      assert Catalogue.get_category(child.uuid).parent_uuid == nil
    end

    test "a forged target inside the selection is refused and moves nothing",
         %{conn: conn, catalogue: cat, a: a, b: b} do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

      render_click(view, "request_bulk_move_categories", %{"uuids" => [a.uuid, b.uuid]})
      render_click(view, "set_bulk_move_categories_disposition", %{"disposition" => "move_under"})
      # Bypass the picker: point the selection at one of its own members.
      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.bulk_move_categories_modal.target_uuid, a.uuid)
      end)

      render_click(view, "confirm_bulk_move_categories", %{})

      assert Catalogue.get_category(b.uuid).parent_uuid == nil
      assert assigns(view).bulk_move_categories_modal
    end

    test "the batch move broadcasts one :category event per catalogue, after the loop",
         %{catalogue: cat, a: a, b: b, c: c} do
      CataloguePubSub.subscribe()

      assert {:ok, %{moved: 2, errors: []}} =
               Catalogue.bulk_move_categories_under([a.uuid, b.uuid], c.uuid)

      cat_uuid = cat.uuid
      assert_receive {:catalogue_data_changed, :category, nil, ^cat_uuid}
      refute_receive {:catalogue_data_changed, :category, _, _}, 100
    end
  end
end
