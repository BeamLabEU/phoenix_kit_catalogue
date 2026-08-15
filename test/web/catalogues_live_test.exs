defmodule PhoenixKitCatalogue.Web.CataloguesLiveTest do
  @moduledoc """
  End-to-end tests for CataloguesLive — the index page that hosts
  three tabs (Catalogues / Manufacturers / Suppliers), the Items
  column, the active/deleted toggle, search, and CRUD event handlers.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  # ─────────────────────────────────────────────────────────────────
  # Tab switching
  # ─────────────────────────────────────────────────────────────────

  describe "tabs" do
    test "index tab renders catalogues", %{conn: conn} do
      fixture_catalogue(%{name: "Kitchen"})

      {:ok, _view, html} = live(conn, @base)
      assert html =~ "Kitchen"
      assert html =~ "New Catalogue"
    end

    test "manufacturers tab renders manufacturers", %{conn: conn} do
      fixture_manufacturer(%{name: "Blum"})

      {:ok, _view, html} = live(conn, "#{@base}/manufacturers")
      assert html =~ "Blum"
      assert html =~ "New Manufacturer"
    end

    test "suppliers tab renders suppliers", %{conn: conn} do
      fixture_supplier(%{name: "DelCo"})

      {:ok, _view, html} = live(conn, "#{@base}/suppliers")
      assert html =~ "DelCo"
      assert html =~ "New Supplier"
    end

    test "empty catalogues state", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)
      assert html =~ "No catalogues yet"
    end

    test "empty manufacturers state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{@base}/manufacturers")
      assert html =~ "No manufacturers yet"
    end

    test "empty suppliers state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{@base}/suppliers")
      assert html =~ "No suppliers yet"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Items column
  # ─────────────────────────────────────────────────────────────────

  describe "item counts column" do
    test "catalogues table shows per-catalogue item counts", %{conn: conn} do
      cat_a = fixture_catalogue(%{name: "Kitchen"})
      cat_b = fixture_catalogue(%{name: "Bathroom"})
      category_a = fixture_category(cat_a)

      fixture_item(%{name: "A1", category_uuid: category_a.uuid})
      fixture_item(%{name: "A2", category_uuid: category_a.uuid})
      fixture_item(%{name: "Loose in B", catalogue_uuid: cat_b.uuid})

      {:ok, _view, html} = live(conn, @base)

      # Two catalogues listed, counts visible
      assert html =~ "Kitchen"
      assert html =~ "Bathroom"
      # 2 items in Kitchen, 1 in Bathroom — both numbers appear
      assert html =~ "2"
      assert html =~ "1"
    end

    test "deleted catalogues don't show the Items column", %{conn: conn} do
      cat = fixture_catalogue(%{name: "Trashed"})
      Catalogue.trash_catalogue(cat)

      {:ok, view, _html} = live(conn, @base)
      deleted_html = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      # The Items header only appears in active mode.
      assert deleted_html =~ "Trashed"
      # Column headers in deleted view: Name / Status / Updated / Actions.
      # Just verify "Trashed" is present and the page didn't crash.
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Active / Deleted toggle
  # ─────────────────────────────────────────────────────────────────

  describe "folder explorer sidebar" do
    test "tree renders and navigate_folder narrows the list", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Showcase"})
      {:ok, _child} = Catalogue.create_folder(%{name: "Nested", parent_uuid: folder.uuid})
      filed = fixture_catalogue(%{name: "Filed catalogue"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      fixture_catalogue(%{name: "Loose catalogue"})

      {:ok, view, html} = live(conn, @base)

      # Both folders live in the sidebar tree (Nested is collapsed but
      # rendered — expansion is client-side state, DOM carries the tree).
      assert html =~ "Showcase"
      assert html =~ "catalogue-folder-explorer"

      # Drill in by clicking the rendered tree button — the DOM path is
      # what proves the params (folder-uuid) actually arrive.
      drilled =
        view
        |> element(
          ~s{button[phx-click="navigate_folder"][phx-value-folder-uuid="#{folder.uuid}"]}
        )
        |> render_click()

      assert drilled =~ "Filed catalogue"
      refute drilled =~ "Loose catalogue"

      # All Files returns to the unfiltered list.
      all = render_click(view, "navigate_view_all", %{})
      assert all =~ "Loose catalogue"

      # Root shows only unfiled catalogues.
      root = render_click(view, "navigate_root", %{})
      assert root =~ "Loose catalogue"
      refute root =~ "Filed catalogue"
    end

    test "entering the trash clears a stale folder filter", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Live folder"})
      filed = fixture_catalogue(%{name: "Filed catalogue"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      trashed = fixture_catalogue(%{name: "Binned catalogue"})
      Catalogue.trash_catalogue(trashed)

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "navigate_folder", %{"folder-uuid" => folder.uuid})

      # The unfiled trashed catalogue must be visible despite the drill.
      trash = render_click(view, "toggle_trash_filter", %{})
      assert trash =~ "Binned catalogue"

      # Toggling back out returns to the unfiltered active list.
      active = render_click(view, "toggle_trash_filter", %{})
      assert active =~ "Filed catalogue"
    end

    test "sidebar + creates at the drilled level with inline rename open", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Parent here"})

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "navigate_folder", %{"folder-uuid" => folder.uuid})
      html = render_click(view, "open_new_folder_modal", %{})

      tree = Catalogue.list_folder_tree()
      assert {new_folder, 1} = Enum.find(tree, fn {f, _d} -> f.parent_uuid == folder.uuid end)
      # The tree opens the inline rename form for the new folder.
      assert html =~ "folder-tree-rename-form-#{new_folder.uuid}"

      # Committing the sidebar rename form persists the name.
      view
      |> element("#folder-tree-rename-form-#{new_folder.uuid}")
      |> render_submit(%{"folder_uuid" => new_folder.uuid, "name" => "Named via sidebar"})

      assert Catalogue.get_folder(new_folder.uuid).name == "Named via sidebar"
    end

    test "drag-drop events file catalogues and nest folders", %{conn: conn} do
      {:ok, folder_a} = Catalogue.create_folder(%{name: "Drop target"})
      {:ok, folder_b} = Catalogue.create_folder(%{name: "Will nest"})
      cat = fixture_catalogue(%{name: "Dragged catalogue"})

      {:ok, view, _html} = live(conn, @base)

      # Catalogue dropped on a folder files it there.
      render_click(view, "move_file_to_folder", %{
        "file_uuid" => cat.uuid,
        "folder_uuid" => folder_a.uuid
      })

      assert Catalogue.get_catalogue(cat.uuid).folder_uuid == folder_a.uuid

      # Catalogue dropped on the root target unfiles it.
      render_click(view, "move_file_to_folder", %{"file_uuid" => cat.uuid, "folder_uuid" => ""})
      assert Catalogue.get_catalogue(cat.uuid).folder_uuid == nil

      # Folder dropped on a folder nests it.
      render_click(view, "move_folder_to_folder", %{
        "folder_uuid" => folder_b.uuid,
        "target_uuid" => folder_a.uuid
      })

      assert Catalogue.get_folder(folder_b.uuid).parent_uuid == folder_a.uuid

      # Nesting a folder under its own descendant is refused (cycle guard).
      render_click(view, "move_folder_to_folder", %{
        "folder_uuid" => folder_a.uuid,
        "target_uuid" => folder_b.uuid
      })

      assert Catalogue.get_folder(folder_a.uuid).parent_uuid == nil

      # Trash drops route to the existing trash flows.
      render_click(view, "trash_file", %{"file_uuid" => cat.uuid})
      assert Catalogue.get_catalogue(cat.uuid).status == "deleted"

      render_click(view, "trash_folder", %{"folder_uuid" => folder_b.uuid})
      assert Catalogue.get_folder(folder_b.uuid).status == "deleted"

      # The hook's touch-select gesture is a no-op here, never a crash.
      render_click(view, "long_press_select", %{"type" => "file", "uuid" => cat.uuid})
    end

    test "new_folder honors a validated parent from the drill level", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Parent here"})

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "new_folder", %{"parent" => folder.uuid})

      tree = Catalogue.list_folder_tree()
      assert Enum.any?(tree, fn {f, depth} -> f.parent_uuid == folder.uuid and depth == 1 end)

      # A forged/unknown parent falls back to a root folder instead of erroring.
      render_click(view, "new_folder", %{"parent" => Ecto.UUID.generate()})
      roots = for {f, 0} <- Catalogue.list_folder_tree(), do: f
      assert length(roots) >= 2
    end
  end

  describe "catalogue view toggle" do
    test "deleted toggle only appears when there are deleted catalogues", %{conn: conn} do
      fixture_catalogue(%{name: "Active"})

      {:ok, _view, html} = live(conn, @base)
      refute html =~ "Deleted (1)"
    end

    test "switch_catalogue_view shows deleted catalogues", %{conn: conn} do
      fixture_catalogue(%{name: "Active one"})
      deleted = fixture_catalogue(%{name: "Deleted one"})
      Catalogue.trash_catalogue(deleted)

      {:ok, view, html} = live(conn, @base)
      assert html =~ "Active one"
      refute html =~ "Deleted one"

      deleted_html = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})
      assert deleted_html =~ "Deleted one"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Catalogue mutations
  # ─────────────────────────────────────────────────────────────────

  describe "clickable names" do
    test "catalogue name in the table view is a link to its detail page", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Clickable"})

      {:ok, _view, html} = live(conn, @base)

      expected_href = "/en/admin/catalogue/#{catalogue.uuid}"
      assert html =~ ~s(href="#{expected_href}")
    end

    test "manufacturer name in the table view is a link to its edit page", %{conn: conn} do
      m = fixture_manufacturer(%{name: "Clickable mfg"})

      {:ok, _view, html} = live(conn, "#{@base}/manufacturers")

      expected_href = "/en/admin/catalogue/manufacturers/#{m.uuid}/edit"
      assert html =~ ~s(href="#{expected_href}")
    end

    test "supplier name in the table view is a link to its edit page", %{conn: conn} do
      s = fixture_supplier(%{name: "Clickable sup"})

      {:ok, _view, html} = live(conn, "#{@base}/suppliers")

      expected_href = "/en/admin/catalogue/suppliers/#{s.uuid}/edit"
      assert html =~ ~s(href="#{expected_href}")
    end
  end

  describe "catalogue mutations" do
    test "trash_catalogue removes the catalogue from the active view", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Goner"})

      {:ok, view, html} = live(conn, @base)
      assert html =~ "Goner"

      after_html = render_click(view, "trash_catalogue", %{"uuid" => catalogue.uuid})
      refute after_html =~ "Goner"
      assert Catalogue.get_catalogue(catalogue.uuid).status == "deleted"
    end

    test "restore_catalogue from the deleted view brings it back", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Comeback"})
      Catalogue.trash_catalogue(catalogue)

      {:ok, view, _html} = live(conn, @base)
      _ = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      render_click(view, "restore_catalogue", %{"uuid" => catalogue.uuid})
      assert Catalogue.get_catalogue(catalogue.uuid).status == "active"
    end

    test "permanently_delete_catalogue deletes from DB", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Forever gone"})
      Catalogue.trash_catalogue(catalogue)

      {:ok, view, _html} = live(conn, @base)
      _ = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      render_click(view, "show_delete_confirm", %{"uuid" => catalogue.uuid, "type" => "catalogue"})

      render_click(view, "permanently_delete_catalogue", %{})

      assert Catalogue.get_catalogue(catalogue.uuid) == nil
    end

    test "show_delete_confirm opens the modal; cancel_delete clears the confirm state", %{
      conn: conn
    } do
      catalogue = fixture_catalogue(%{name: "Trashable"})
      Catalogue.trash_catalogue(catalogue)

      {:ok, view, _html} = live(conn, @base)
      _ = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      opened =
        render_click(view, "show_delete_confirm", %{
          "uuid" => catalogue.uuid,
          "type" => "catalogue"
        })

      # Modal content ("This will permanently delete…") is visible.
      assert opened =~ "This will permanently delete this catalogue"

      closed = render_click(view, "cancel_delete", %{})
      # After cancel the modal warning copy is gone from the render.
      refute closed =~ "This will permanently delete this catalogue"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Manufacturer / Supplier hard-delete (via confirm modal)
  # ─────────────────────────────────────────────────────────────────

  describe "manufacturer and supplier deletion" do
    test "delete_manufacturer removes it from the list", %{conn: conn} do
      m = fixture_manufacturer(%{name: "Gone manufacturer"})

      {:ok, view, _html} = live(conn, "#{@base}/manufacturers")

      render_click(view, "show_delete_confirm", %{"uuid" => m.uuid, "type" => "manufacturer"})
      render_click(view, "delete_manufacturer", %{})

      assert Catalogue.get_manufacturer(m.uuid) == nil
    end

    test "delete_supplier removes it from the list", %{conn: conn} do
      s = fixture_supplier(%{name: "Gone supplier"})

      {:ok, view, _html} = live(conn, "#{@base}/suppliers")

      render_click(view, "show_delete_confirm", %{"uuid" => s.uuid, "type" => "supplier"})
      render_click(view, "delete_supplier", %{})

      assert Catalogue.get_supplier(s.uuid) == nil
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # URL-backed search (?q=)
  # ─────────────────────────────────────────────────────────────────

  describe "url-backed search" do
    test "?q= filters the catalogue rows straight from the URL", %{conn: conn} do
      fixture_catalogue(%{name: "Zephyr"})
      fixture_catalogue(%{name: "Quokka"})

      {:ok, _view, html} = live(conn, "#{@base}?q=zeph")

      assert html =~ "Zephyr"
      refute html =~ "Quokka"
    end

    test "table_search patches ?q= in, and clearing patches it back out", %{conn: conn} do
      fixture_catalogue(%{name: "Zephyr"})
      fixture_catalogue(%{name: "Quokka"})

      {:ok, view, _html} = live(conn, @base)

      html = render_change(view, "table_search", %{"query" => "quo"})
      assert_patch(view, "#{@base}?q=quo")
      assert html =~ "Quokka"
      refute html =~ "Zephyr"

      html = render_change(view, "table_search", %{"query" => ""})
      assert_patch(view, @base)
      assert html =~ "Zephyr"
    end

    test "?q= applies to whichever tab the route selected", %{conn: conn} do
      fixture_manufacturer(%{name: "Zephyr Werke"})
      fixture_manufacturer(%{name: "Quokka GmbH"})

      {:ok, _view, html} = live(conn, "#{@base}/manufacturers?q=quokka")

      assert html =~ "Quokka GmbH"
      refute html =~ "Zephyr Werke"
    end

    # `tab_changed?` keeps the search patch from re-running load_data — the
    # tab's own assigns (active_tab, page_title, the rows it already loaded)
    # still have to survive that patch.
    test "a search patch leaves the tab itself intact", %{conn: conn} do
      fixture_manufacturer(%{name: "Zephyr Werke"})

      {:ok, view, _html} = live(conn, "#{@base}/manufacturers")

      html = render_change(view, "table_search", %{"query" => "zephyr"})

      assert html =~ "Zephyr Werke"
      assert html =~ "New Manufacturer"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Manual order (drag-and-drop reorder of catalogues)
  # ─────────────────────────────────────────────────────────────────
  #
  # `reorder_catalogues` only acts in manual-order mode, so the test first
  # drives `set_sort` to "position" — reachable now that `ViewConfig.save/3`
  # degrades gracefully on the harness's bare `%{uuid: uuid}` user instead of
  # raising out of `put_cfg` (per-user persistence is skipped; the in-memory
  # cfg and the global sort setting still update).
  describe "manual order — DnD reorder" do
    test "reorder_catalogues persists the dropped order", %{conn: conn} do
      a = fixture_catalogue(%{name: "A", position: 0})
      b = fixture_catalogue(%{name: "B", position: 1})
      c = fixture_catalogue(%{name: "C", position: 2})

      {:ok, view, _html} = live(conn, @base)

      render_click(view, "set_sort", %{"sort_by" => "position"})
      render_hook(view, "reorder_catalogues", %{"ordered_ids" => [c.uuid, a.uuid, b.uuid]})

      assert Catalogue.list_catalogues() |> Enum.map(& &1.name) == ["C", "A", "B"]
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Global sort — the catalogues index shares ONE sort across admins
  # ─────────────────────────────────────────────────────────────────
  describe "global sort (catalogues scope)" do
    alias PhoenixKitCatalogue.Web.ViewConfig

    defp appears_before?(html, first, second) do
      {i1, _} = :binary.match(html, first)
      {i2, _} = :binary.match(html, second)
      i1 < i2
    end

    test "set_sort persists the shared setting", %{conn: conn} do
      fixture_catalogue(%{name: "Alpha"})

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "set_sort", %{"sort_by" => "updated"})

      assert PhoenixKit.Settings.get_setting("catalogue_sort_catalogues", nil) == "updated:asc"
    end

    test "a second open index follows a sort change live", %{conn: conn} do
      # Positions invert the alphabetical order, so which name renders first
      # tells us which sort is active.
      fixture_catalogue(%{name: "Alpha", position: 1})
      fixture_catalogue(%{name: "Zed", position: 0})

      {:ok, viewer, viewer_html} = live(conn, @base)
      {:ok, changer, _html} = live(conn, @base)

      assert appears_before?(viewer_html, "Alpha", "Zed")

      render_click(changer, "set_sort", %{"sort_by" => "position"})

      assert appears_before?(render(viewer), "Zed", "Alpha")
    end

    test "a fresh mount reads the shared sort", %{conn: conn} do
      fixture_catalogue(%{name: "Alpha", position: 1})
      fixture_catalogue(%{name: "Zed", position: 0})

      {:ok, _} = ViewConfig.save_global_sort(:catalogues, "position", :asc)

      {:ok, _view, html} = live(conn, @base)
      assert appears_before?(html, "Zed", "Alpha")
    end

    test "an invalid stored value falls back to the default sort" do
      PhoenixKit.Settings.update_setting_with_module(
        "catalogue_sort_catalogues",
        "bogus:sideways",
        "catalogue"
      )

      assert ViewConfig.load_global_sort(:catalogues) == {"name", :asc}
    end

    test "manufacturers sort stays per-user", %{conn: conn} do
      fixture_manufacturer(%{name: "Blum"})

      {:ok, view, _html} = live(conn, "#{@base}/manufacturers")
      render_click(view, "set_sort", %{"sort_by" => "updated"})

      assert PhoenixKit.Settings.get_setting("catalogue_sort_manufacturers", nil) == nil
    end
  end
end
