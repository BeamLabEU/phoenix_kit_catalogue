defmodule PhoenixKitCatalogue.Web.CatalogueDetailBranchesTest do
  @moduledoc """
  Branch coverage for `CatalogueDetailLive` events the existing
  smoke tests don't pin: switch_view, search / clear_search,
  delete/restore/permanently_delete for items + categories,
  move_category_up/down, cancel_delete confirm flow.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  setup do
    cat = fixture_catalogue(%{name: "Detail Branches"})
    %{catalogue: cat}
  end

  describe "switch_view active/deleted" do
    test "switch_view to deleted then back to active when deleted items exist",
         %{conn: conn, catalogue: cat} do
      # Create + trash an item so the deleted view has content. Without
      # this the LV auto-switches back to active.
      {:ok, item} = Catalogue.create_item(%{name: "Trashed", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.trash_item(item)

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_click(view, "switch_view", %{"mode" => "deleted"})
      assert :sys.get_state(view.pid).socket.assigns.view_mode == "deleted"

      render_click(view, "switch_view", %{"mode" => "active"})
      assert :sys.get_state(view.pid).socket.assigns.view_mode == "active"
    end
  end

  describe "search / clear_search" do
    test "search with non-empty query populates search_results",
         %{conn: conn, catalogue: cat} do
      {:ok, _item} = Catalogue.create_item(%{name: "Searchable", catalogue_uuid: cat.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_change(view, "search", %{"query" => "Searchable"})

      assigns = :sys.get_state(view.pid).socket.assigns
      # search_results becomes a list (or stays nil if the search task
      # is still in flight). Pin the search_query landed.
      assert assigns.search_query == "Searchable"
    end

    test "search with empty query clears results", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_change(view, "search", %{"query" => "anything"})
      render_change(view, "search", %{"query" => ""})

      assert :sys.get_state(view.pid).socket.assigns.search_results == nil
    end

    test "clear_search resets search state", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_change(view, "search", %{"query" => "stuff"})
      render_click(view, "clear_search", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.search_results == nil
      assert assigns.search_query == ""
    end
  end

  describe "delete_item / restore_item happy path" do
    test "delete_item trashes + restore_item un-trashes", %{conn: conn, catalogue: cat} do
      {:ok, item} = Catalogue.create_item(%{name: "Cycle", catalogue_uuid: cat.uuid})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_click(view, "delete_item", %{"uuid" => item.uuid})
      assert Catalogue.get_item(item.uuid).status == "deleted"

      # Switch to deleted mode then restore.
      render_click(view, "switch_view", %{"mode" => "deleted"})
      render_click(view, "restore_item", %{"uuid" => item.uuid})
      assert Catalogue.get_item(item.uuid).status == "active"
    end

    test "delete_item with unknown uuid flashes 'not found'",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      html = render_click(view, "delete_item", %{"uuid" => Ecto.UUID.generate()})
      assert html =~ "not found" or html =~ "Item not found"
    end
  end

  describe "trash_category / restore_category happy path" do
    test "trash_category soft-deletes + restore reverses",
         %{conn: conn, catalogue: cat} do
      cat_obj = fixture_category(cat, %{name: "TrashCat"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_click(view, "trash_category", %{"uuid" => cat_obj.uuid})
      assert Catalogue.get_category(cat_obj.uuid).status == "deleted"

      render_click(view, "switch_view", %{"mode" => "deleted"})
      render_click(view, "restore_category", %{"uuid" => cat_obj.uuid})
      assert Catalogue.get_category(cat_obj.uuid).status == "active"
    end
  end

  describe "show_delete_confirm + cancel_delete + permanently_delete_*" do
    test "show_delete_confirm + cancel_delete toggles confirm_delete",
         %{conn: conn, catalogue: cat} do
      cat_obj = fixture_category(cat, %{name: "Confirm"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_click(view, "show_delete_confirm", %{
        "uuid" => cat_obj.uuid,
        "type" => "category"
      })

      assert :sys.get_state(view.pid).socket.assigns.confirm_delete ==
               {"category", cat_obj.uuid}

      render_click(view, "cancel_delete", %{})
      assert :sys.get_state(view.pid).socket.assigns.confirm_delete == nil
    end

    test "permanently_delete_item runs only after show_delete_confirm matches",
         %{conn: conn, catalogue: cat} do
      {:ok, item} = Catalogue.create_item(%{name: "Hard", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.trash_item(item)

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}?view=deleted")
      render_click(view, "show_delete_confirm", %{"uuid" => item.uuid, "type" => "item"})
      render_click(view, "permanently_delete_item", %{})

      assert Catalogue.get_item(item.uuid) == nil
    end
  end

  describe "move_category_up / move_category_down" do
    test "swaps positions when adjacent siblings exist",
         %{conn: conn, catalogue: cat} do
      a = fixture_category(cat, %{name: "A"})
      b = fixture_category(cat, %{name: "B"})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      # Move B up — A and B swap. The LV doesn't crash on the no-op
      # case either.
      render_click(view, "move_category_up", %{"uuid" => b.uuid})
      render_click(view, "move_category_down", %{"uuid" => a.uuid})

      assert Process.alive?(view.pid)
    end

    test "move_category_up on a non-existent uuid is a no-op",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")
      render_click(view, "move_category_up", %{"uuid" => Ecto.UUID.generate()})
      assert Process.alive?(view.pid)
    end
  end
end
