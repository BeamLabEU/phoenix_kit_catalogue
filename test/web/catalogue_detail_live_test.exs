defmodule PhoenixKitCatalogue.Web.CatalogueDetailLiveTest do
  @moduledoc """
  End-to-end tests for CatalogueDetailLive — infinite scroll paging,
  view-mode toggle, search, item mutations preserving scroll, category
  reorder/trash/restore/permanent_delete, not-found redirect.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  defp url(uuid), do: "#{@base}/#{uuid}"

  # ─────────────────────────────────────────────────────────────────
  # Mount / render
  # ─────────────────────────────────────────────────────────────────

  describe "mount" do
    test "renders catalogue name and header actions in active mode", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Kitchen"})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "Kitchen"
      assert html =~ "Add Item"
      assert html =~ "Add Category"
    end

    test "redirects to the index when the catalogue doesn't exist", %{conn: conn} do
      bogus = "00000000-0000-0000-0000-000000000000"

      {:error, {:live_redirect, %{to: to}}} = live(conn, url(bogus))
      assert to == @base
    end

    test "renders the empty-state card when there are no categories or items", %{conn: conn} do
      catalogue = fixture_catalogue()

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "No categories or items yet"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Infinite scroll
  # ─────────────────────────────────────────────────────────────────

  describe "infinite scroll" do
    test "initial mount loads the first category's card", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "First", position: 0})
      _cat_b = fixture_category(catalogue, %{name: "Second", position: 1})

      for i <- 1..3 do
        fixture_item(%{name: "A#{i}", category_uuid: cat_a.uuid})
      end

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "First"
      assert html =~ "A1"
    end

    test "load_more event advances to the next category", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "First", position: 0})
      cat_b = fixture_category(catalogue, %{name: "Second", position: 1})

      fixture_item(%{name: "A only", category_uuid: cat_a.uuid})
      fixture_item(%{name: "B only", category_uuid: cat_b.uuid})

      {:ok, view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "First"
      assert html =~ "A only"
      # The second category hasn't been loaded yet.
      refute html =~ "Second"

      # Fire the load_more event the sentinel would normally push.
      html_after = render_click(view, "load_more", %{})
      assert html_after =~ "Second"
      assert html_after =~ "B only"
    end

    test "paging fills a single large category across multiple load_more calls", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)

      # @per_page is 100 — create 150 so two loads are needed.
      for i <- 1..150 do
        fixture_item(%{
          name: "Item #{String.pad_leading("#{i}", 3, "0")}",
          category_uuid: category.uuid
        })
      end

      {:ok, view, first_html} = live(conn, url(catalogue.uuid))

      # First batch should contain items 001..100 but not 101.
      assert first_html =~ "Item 001"
      assert first_html =~ "Item 100"
      refute first_html =~ "Item 150"

      html_after = render_click(view, "load_more", %{})
      assert html_after =~ "Item 101"
      assert html_after =~ "Item 150"
    end

    test "uncategorized items load as the final card", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "Cat A"})

      fixture_item(%{name: "In Category", category_uuid: cat_a.uuid})
      fixture_item(%{name: "Loose Item", catalogue_uuid: catalogue.uuid})

      {:ok, view, first_html} = live(conn, url(catalogue.uuid))

      assert first_html =~ "Cat A"
      assert first_html =~ "In Category"
      # Uncategorized not loaded on the first batch because the
      # category was loaded first.
      refute first_html =~ "Uncategorized"

      html_after = render_click(view, "load_more", %{})
      assert html_after =~ "Uncategorized"
      assert html_after =~ "Loose Item"
    end

    test "category card shows the total item count, not the loaded count", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)

      for i <- 1..120 do
        fixture_item(%{name: "I#{i}", category_uuid: category.uuid})
      end

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      # Badge shows total (120), not the first batch (100)
      assert html =~ "120"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # View mode (active / deleted tabs)
  # ─────────────────────────────────────────────────────────────────

  describe "view_mode toggle" do
    test "switch_view resets the cursor and reloads with deleted items", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      active = fixture_item(%{name: "Active item", category_uuid: category.uuid})
      deleted = fixture_item(%{name: "Deleted item", category_uuid: category.uuid})
      Catalogue.trash_item(deleted)

      {:ok, view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "Active item"
      refute html =~ "Deleted item"

      html_after = render_click(view, "switch_view", %{"mode" => "deleted"})

      assert html_after =~ "Deleted item"
      refute html_after =~ active.uuid
    end

    test "Active tab badge shows the non-deleted item count", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "A", category_uuid: category.uuid})
      fixture_item(%{name: "B", category_uuid: category.uuid})
      gone = fixture_item(%{name: "Gone", category_uuid: category.uuid})
      Catalogue.trash_item(gone)

      {:ok, _view, html} = live(conn, url(catalogue.uuid))
      # Active (2) and Deleted (1) tabs are present; check the Active count appears.
      assert html =~ "Active"
      assert html =~ "(2)"
      assert html =~ "Deleted"
      assert html =~ "(1)"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Item mutations (local updates — scroll is preserved)
  # ─────────────────────────────────────────────────────────────────

  describe "item mutations" do
    test "delete_item removes the item from the card without a full reload", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Doomed", category_uuid: category.uuid})
      fixture_item(%{name: "Survivor", category_uuid: category.uuid})

      {:ok, view, html} = live(conn, url(catalogue.uuid))
      assert html =~ "Doomed"

      html_after = render_click(view, "delete_item", %{"uuid" => item.uuid})

      refute html_after =~ "Doomed"
      assert html_after =~ "Survivor"
      # DB reflects the trash (status = "deleted")
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "restore_item (in deleted view) removes it from the deleted list", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Comeback", category_uuid: category.uuid})
      Catalogue.trash_item(item)

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      # Jump to the deleted tab to see the item
      html = render_click(view, "switch_view", %{"mode" => "deleted"})
      assert html =~ "Comeback"

      html_after = render_click(view, "restore_item", %{"uuid" => item.uuid})
      refute html_after =~ "Comeback"
      assert Catalogue.get_item(item.uuid).status == "active"
    end

    test "delete_item with a bogus uuid doesn't crash and leaves existing items untouched", %{
      conn: conn
    } do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      survivor = fixture_item(%{name: "Survivor", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      html =
        render_click(view, "delete_item", %{"uuid" => "00000000-0000-0000-0000-000000000000"})

      # Page still renders; survivor is still listed.
      assert html =~ "Survivor"
      assert Catalogue.get_item(survivor.uuid).status == "active"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Category mutations
  # ─────────────────────────────────────────────────────────────────

  describe "clickable names" do
    test "category name is a link to the category edit page in active mode", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Clickable category"})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      expected_href = "/en/admin/catalogue/categories/#{category.uuid}/edit"
      assert html =~ ~s(href="#{expected_href}")
      assert html =~ "Clickable category"
    end

    test "category name is plain text in deleted mode", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Deleted category"})
      Catalogue.trash_category(category)

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      html = render_click(view, "switch_view", %{"mode" => "deleted"})

      # In deleted mode the h3 renders, not the edit link
      refute html =~ "/en/admin/catalogue/categories/#{category.uuid}/edit"
      assert html =~ "Deleted category"
    end

    test "item name in the card body is a link to the item edit page", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Clickable item", category_uuid: category.uuid})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      expected_href = "/en/admin/catalogue/items/#{item.uuid}/edit"
      assert html =~ ~s(href="#{expected_href}")
      assert html =~ "Clickable item"
    end
  end

  describe "category mutations" do
    test "trash_category removes the category card", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "Trashable", position: 0})
      _cat_b = fixture_category(catalogue, %{name: "Staying", position: 1})

      {:ok, view, html} = live(conn, url(catalogue.uuid))
      assert html =~ "Trashable"

      html_after = render_click(view, "trash_category", %{"uuid" => cat_a.uuid})
      refute html_after =~ "Trashable"
      assert html_after =~ "Staying"
    end

    test "restore_category in deleted mode brings it back and auto-flips to active", %{
      conn: conn
    } do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Brought Back"})
      Catalogue.trash_category(category)

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      _deleted_html = render_click(view, "switch_view", %{"mode" => "deleted"})

      html_after = render_click(view, "restore_category", %{"uuid" => category.uuid})
      # Either the category is now shown in the page (if we're still on
      # deleted mode and there are other deleted things) or the view
      # auto-flipped back to active. Either way it must now be visible.
      assert html_after =~ "Brought Back"
    end

    test "move_category_up swaps positions", %{conn: conn} do
      catalogue = fixture_catalogue()
      first = fixture_category(catalogue, %{name: "First", position: 0})
      second = fixture_category(catalogue, %{name: "Second", position: 1})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      render_click(view, "move_category_up", %{"uuid" => second.uuid})

      assert Catalogue.get_category(first.uuid).position == 1
      assert Catalogue.get_category(second.uuid).position == 0
    end

    test "move_category_up on the topmost category is a no-op", %{conn: conn} do
      catalogue = fixture_catalogue()
      first = fixture_category(catalogue, %{name: "First", position: 0})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      render_click(view, "move_category_up", %{"uuid" => first.uuid})

      assert Catalogue.get_category(first.uuid).position == 0
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Search
  # ─────────────────────────────────────────────────────────────────

  describe "search" do
    test "search shows matching items and hides the infinite-scroll cards", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Hidden while searching"})
      fixture_item(%{name: "Oak panel", category_uuid: category.uuid})
      fixture_item(%{name: "Pine board", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      html_after = render_change(view, "search", %{"query" => "oak"})

      # Search results visible
      assert html_after =~ "Oak panel"
      # Pine board excluded from results
      refute html_after =~ "Pine board"
    end

    test "empty search query falls back to normal paged view", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Only item", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      _after_search = render_change(view, "search", %{"query" => "anything"})
      html_after = render_change(view, "search", %{"query" => ""})

      # Back to the normal view
      assert html_after =~ "Only item"
    end

    test "clear_search restores the paged view", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      _ = render_change(view, "search", %{"query" => "nothing matches"})
      html_after = render_click(view, "clear_search", %{})

      assert html_after =~ "Item"
    end
  end
end
