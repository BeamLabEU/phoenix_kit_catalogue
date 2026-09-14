defmodule PhoenixKitCatalogue.Web.CatalogueDeletedTabTest do
  @moduledoc """
  A catalogue's Deleted tab is built from the same components as its Active
  tab: categories as cards and table rows with checkboxes, items in the same
  table, a Status column instead of red styling, and Restore / Delete forever
  as the row menus and bulk actions. Its search searches the trash.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  defp trashed_world do
    catalogue = fixture_catalogue()
    live_category = fixture_category(catalogue, %{name: "Live category"})
    fixture_item(%{name: "Live item", category_uuid: live_category.uuid})
    gone = fixture_category(catalogue, %{name: "Gone category"})
    gone_item = fixture_item(%{name: "Gone item", category_uuid: gone.uuid})
    loose = fixture_item(%{name: "Gone loose item", catalogue_uuid: catalogue.uuid})
    {:ok, _} = Catalogue.trash_category(gone, items: :cascade)
    {:ok, _} = Catalogue.trash_item(loose)

    other = fixture_catalogue()
    foreign = fixture_category(other, %{name: "Foreign"})
    {:ok, _} = Catalogue.trash_category(foreign)

    %{catalogue: catalogue, gone: gone, gone_item: gone_item, loose: loose, foreign: foreign}
  end

  defp open_deleted_tab(conn, catalogue) do
    {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
    html = render_click(view, "switch_view", %{"mode" => "deleted"})
    {view, html}
  end

  test "the Deleted tab renders the Active tab's components", %{conn: conn} do
    %{catalogue: catalogue, gone: gone, gone_item: gone_item} = trashed_world()
    {view, html} = open_deleted_tab(conn, catalogue)

    assert :sys.get_state(view.pid).socket.assigns.view_mode == "deleted"

    # Categories: selectable, in the card view too, no red name or badge.
    assert html =~ ~s(data-uuid="#{gone.uuid}")
    assert html =~ "catalogue-categories-cards"
    refute html =~ "text-error/70"
    assert html =~ ~s(data-bulk-action="request_bulk_restore_categories")
    assert html =~ ~s(data-bulk-action="request_bulk_permanent_delete_categories")

    # Items: the Active tab's table, with the trash row menu and bulk actions.
    assert html =~ "level-items-active"
    refute html =~ "level-items-deleted"
    assert html =~ ~s(id="item-row-del-menu-#{gone_item.uuid}")
    assert html =~ ~s(data-bulk-action="request_bulk_restore_items")
  end

  test "bulk restore brings back only this catalogue's trashed categories, with their items",
       %{conn: conn} do
    %{catalogue: catalogue, gone: gone, gone_item: gone_item, foreign: foreign} = trashed_world()
    {view, _html} = open_deleted_tab(conn, catalogue)

    html =
      render_click(view, "request_bulk_restore_categories", %{
        "uuids" => [gone.uuid, foreign.uuid]
      })

    assert html =~ "Restored 1 categories."
    assert Catalogue.get_category(gone.uuid).status == "active"
    assert Catalogue.get_item(gone_item.uuid).status == "active"
    assert Catalogue.get_category(foreign.uuid).status == "deleted"
  end

  test "bulk Delete forever confirms first, then deletes only this catalogue's trashed categories",
       %{conn: conn} do
    %{catalogue: catalogue, gone: gone, gone_item: gone_item, foreign: foreign} = trashed_world()
    {view, _html} = open_deleted_tab(conn, catalogue)

    html =
      render_click(view, "request_bulk_permanent_delete_categories", %{
        "uuids" => [gone.uuid, foreign.uuid]
      })

    assert html =~ "Permanently delete selected categories?"
    assert Catalogue.get_category(gone.uuid)

    html = render_click(view, "confirm_bulk_action", %{})

    assert html =~ "Permanently deleted 1 categories."
    assert is_nil(Catalogue.get_category(gone.uuid))
    assert is_nil(Catalogue.get_item(gone_item.uuid))
    assert Catalogue.get_category(foreign.uuid).status == "deleted"
  end

  # Clearing a selection by changing a BulkSelectScope's id remounts the hook,
  # but LiveView carries the id-keyed table into the new scope with its
  # checkboxes still wired to the old hook — the toolbar then never shows.
  test "selection scopes keep their ids across a bulk op and a level change",
       %{conn: conn} do
    %{catalogue: catalogue, gone: gone} = trashed_world()
    {view, _html} = open_deleted_tab(conn, catalogue)

    assert has_element?(view, "#categories-bulk[phx-hook=BulkSelectScope]")
    assert has_element?(view, "#items-bulk[phx-hook=BulkSelectScope]")

    render_click(view, "request_bulk_restore_categories", %{"uuids" => [gone.uuid]})
    assert_push_event(view, "bulk_select:clear", %{})
    # The trashed loose item is still listed, in the same scope.
    assert has_element?(view, "#items-bulk[phx-hook=BulkSelectScope]")

    render_click(view, "switch_view", %{"mode" => "active"})
    render_patch(view, "#{@base}/#{catalogue.uuid}?category=#{gone.uuid}")
    assert has_element?(view, "#items-bulk[phx-hook=BulkSelectScope]")
  end

  test "search in the Deleted tab finds the trashed items only", %{conn: conn} do
    %{catalogue: catalogue} = trashed_world()
    {view, _html} = open_deleted_tab(conn, catalogue)

    render_change(view, "search", %{"query" => "item"})
    render_async(view)

    names =
      :sys.get_state(view.pid).socket.assigns.search_results
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert names == ["Gone item", "Gone loose item"]
  end

  test "search_items trashed: true matches deleted items of live catalogues" do
    %{catalogue: catalogue, gone_item: gone_item, loose: loose} = trashed_world()

    trashed =
      "item"
      |> Catalogue.search_items(catalogue_uuids: [catalogue.uuid], trashed: true)
      |> Enum.map(& &1.uuid)
      |> Enum.sort()

    assert trashed == Enum.sort([gone_item.uuid, loose.uuid])

    live = Catalogue.search_items("item", catalogue_uuids: [catalogue.uuid])
    assert Enum.map(live, & &1.name) == ["Live item"]
  end
end
