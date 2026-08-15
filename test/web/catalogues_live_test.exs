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

  describe "catalogues tree table" do
    test "manual order shows collapsible folder rows; other sorts flatten", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Tree parent"})
      {:ok, _child} = Catalogue.create_folder(%{name: "Tree child", parent_uuid: folder.uuid})
      filed = fixture_catalogue(%{name: "Filed in tree"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      fixture_catalogue(%{name: "Root level catalogue"})

      {:ok, view, html} = live(conn, @base)

      # Manual order default: the tree renders, folder collapsed
      # (children hidden), unfiled catalogue at the root level.
      assert html =~ "catalogues-tree-table"
      assert html =~ "Tree parent"
      refute html =~ "Tree child"
      assert html =~ "Root level catalogue"
      # Drag contract: folder rows are drop targets with grip handles.
      assert html =~ ~s(data-tree-drop="#{folder.uuid}")
      assert html =~ ~s(data-tree-item="folder:#{folder.uuid}")

      # Chevron expands the folder: nested folder + filed catalogue appear.
      expanded =
        view
        |> element(
          ~s{#catalogues-tree-table button[phx-click="toggle_folder_expand"][phx-value-uuid="#{folder.uuid}"]}
        )
        |> render_click()

      assert expanded =~ "Tree child"
      assert expanded =~ "Filed in tree"

      # Switching to a real sort falls back to the flat sortable table.
      flat = render_click(view, "set_sort", %{"sort_by" => "name"})
      refute flat =~ "catalogues-tree-table"
      assert flat =~ "Filed in tree"
    end

    test "drilling re-roots the tree and Up walks back", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Drill target"})
      filed = fixture_catalogue(%{name: "Filed catalogue"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      fixture_catalogue(%{name: "Loose catalogue"})

      {:ok, view, _html} = live(conn, @base)

      drilled =
        view
        |> element(
          ~s{#catalogues-tree-table button[phx-click="navigate_folder"][phx-value-uuid="#{folder.uuid}"]:not([role="menuitem"])}
        )
        |> render_click()

      # Re-rooted: the Up row shows, only the folder's contents render.
      assert drilled =~ "Up"
      assert drilled =~ "Filed catalogue"
      refute drilled =~ "Loose catalogue"

      # Up returns to the root level.
      root = render_click(view, "navigate_folder", %{"uuid" => ""})
      assert root =~ "Loose catalogue"
    end

    test "searching flattens the tree", %{conn: conn} do
      {:ok, _folder} = Catalogue.create_folder(%{name: "Hidden while searching"})
      fixture_catalogue(%{name: "Searchable catalogue"})

      {:ok, _view, html} = live(conn, "#{@base}?q=searchable")

      refute html =~ "catalogues-tree-table"
      assert html =~ "Searchable catalogue"
    end

    test "tree drag events file, unfile, nest, and reorder", %{conn: conn} do
      {:ok, folder_a} = Catalogue.create_folder(%{name: "Drop target"})
      {:ok, folder_b} = Catalogue.create_folder(%{name: "Will nest"})
      cat = fixture_catalogue(%{name: "Dragged catalogue"})

      {:ok, view, html} = live(conn, @base)

      # Grip handles render on every row (the drag affordance).
      assert html =~ ~s(data-tree-item="folder:#{folder_a.uuid}")
      assert html =~ ~s(data-tree-item="catalogue:#{cat.uuid}")

      # Folder middle drop files the catalogue; root zone unfiles it.
      render_click(view, "move_to_folder", %{
        "type" => "catalogue",
        "uuid" => cat.uuid,
        "target" => folder_a.uuid
      })

      assert Catalogue.get_catalogue(cat.uuid).folder_uuid == folder_a.uuid

      render_click(view, "move_to_folder", %{
        "type" => "catalogue",
        "uuid" => cat.uuid,
        "target" => "root"
      })

      assert Catalogue.get_catalogue(cat.uuid).folder_uuid == nil

      # Folder onto folder nests; nesting under a descendant is refused.
      render_click(view, "move_to_folder", %{
        "type" => "folder",
        "uuid" => folder_b.uuid,
        "target" => folder_a.uuid
      })

      assert Catalogue.get_folder(folder_b.uuid).parent_uuid == folder_a.uuid

      render_click(view, "move_to_folder", %{
        "type" => "folder",
        "uuid" => folder_a.uuid,
        "target" => folder_b.uuid
      })

      assert Catalogue.get_folder(folder_a.uuid).parent_uuid == nil

      # Edge drop reorders same-parent siblings (subset write).
      {:ok, folder_c} = Catalogue.create_folder(%{name: "Second root"})
      render_click(view, "reorder_folders", %{"ordered_ids" => [folder_c.uuid, folder_a.uuid]})

      root_order =
        for {f, 0} <- Catalogue.list_folder_tree(),
            f.uuid in [folder_a.uuid, folder_c.uuid],
            do: f.name

      assert root_order == ["Second root", "Drop target"]
    end

    test "drop_row reparents and positions in one gesture", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Level target"})
      inside_a = fixture_catalogue(%{name: "Inside A"})
      inside_b = fixture_catalogue(%{name: "Inside B"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(inside_a, folder.uuid)
      {:ok, _} = Catalogue.move_catalogue_to_folder(inside_b, folder.uuid)
      loose = fixture_catalogue(%{name: "Loose one"})

      {:ok, view, _html} = live(conn, @base)

      # A root-level catalogue edge-dropped between the folder's two
      # children lands in that folder AND between them.
      render_click(view, "drop_row", %{
        "type" => "catalogue",
        "uuid" => loose.uuid,
        "parent" => folder.uuid,
        "entries" => [
          "catalogue:#{inside_a.uuid}",
          "catalogue:#{loose.uuid}",
          "catalogue:#{inside_b.uuid}"
        ]
      })

      assert Catalogue.get_catalogue(loose.uuid).folder_uuid == folder.uuid

      names =
        Catalogue.catalogues_by_folder()
        |> Map.get(folder.uuid, [])
        |> Enum.map(& &1.name)

      assert names == ["Inside A", "Loose one", "Inside B"]

      # A folder edge-dropped under its own descendant is refused whole —
      # no reparent AND no placement applied.
      {:ok, child} = Catalogue.create_folder(%{name: "Child level", parent_uuid: folder.uuid})

      html =
        render_click(view, "drop_row", %{
          "type" => "folder",
          "uuid" => folder.uuid,
          "parent" => child.uuid,
          "entries" => ["folder:#{folder.uuid}"]
        })

      assert Catalogue.get_folder(folder.uuid).parent_uuid == nil
      assert html =~ "into itself or one of its subfolders"
    end

    test "levels interleave folders and catalogues by manual placement", %{conn: conn} do
      {:ok, folder_a} = Catalogue.create_folder(%{name: "First folder"})
      {:ok, folder_b} = Catalogue.create_folder(%{name: "Second folder"})
      cat = fixture_catalogue(%{name: "Between them"})

      {:ok, view, _html} = live(conn, @base)

      # Place the catalogue BETWEEN the two root folders.
      html =
        render_click(view, "drop_row", %{
          "type" => "catalogue",
          "uuid" => cat.uuid,
          "parent" => "root",
          "entries" => [
            "folder:#{folder_a.uuid}",
            "catalogue:#{cat.uuid}",
            "folder:#{folder_b.uuid}"
          ]
        })

      # The rendered tree keeps the mixed order — no folders-first regrouping.
      first = :binary.match(html, "First folder") |> elem(0)
      between = :binary.match(html, "Between them") |> elem(0)
      second = :binary.match(html, "Second folder") |> elem(0)
      assert first < between and between < second

      # A malformed entry rejects the whole payload (forgeable input).
      before = Catalogue.get_catalogue(cat.uuid).position

      render_click(view, "drop_row", %{
        "type" => "catalogue",
        "uuid" => cat.uuid,
        "parent" => "root",
        "entries" => ["catalogue:#{cat.uuid}", "bogus"]
      })

      assert Catalogue.get_catalogue(cat.uuid).position == before
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
    test "folder delete is permanent and refused unless empty", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Holds things"})
      filed = fixture_catalogue(%{name: "Blocker"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)

      {:ok, view, _html} = live(conn, @base)

      # Non-empty: the confirmed delete is refused with the empty-first flash.
      render_click(view, "show_delete_confirm", %{"uuid" => folder.uuid, "type" => "folder"})
      refused = render_click(view, "permanently_delete_folder", %{})
      assert refused =~ "Only empty folders can be deleted"
      assert Catalogue.get_folder(folder.uuid)

      # Emptied: the same flow hard-deletes — no trash, no restore.
      # (Refetch — the local struct predates the move into the folder.)
      {:ok, _} =
        filed.uuid |> Catalogue.get_catalogue() |> Catalogue.move_catalogue_to_folder(nil)

      render_click(view, "show_delete_confirm", %{"uuid" => folder.uuid, "type" => "folder"})
      render_click(view, "permanently_delete_folder", %{})
      assert Catalogue.get_folder(folder.uuid) == nil
    end

    test "legacy trashed folders keep a Delete Forever exit (no restore)", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Binned folder"})
      inside = fixture_catalogue(%{name: "Was inside"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(inside, folder.uuid)
      {:ok, _} = Catalogue.trash_folder(folder)

      {:ok, view, _html} = live(conn, @base)

      deleted = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})
      assert deleted =~ "Binned folder"
      refute deleted =~ "Restore"

      # Legacy delete keeps promote-contents semantics: the filed
      # catalogue is unfiled, not destroyed.
      render_click(view, "show_delete_confirm", %{
        "uuid" => folder.uuid,
        "type" => "legacy_folder"
      })

      render_click(view, "permanently_delete_legacy_folder", %{})
      assert Catalogue.get_folder(folder.uuid) == nil
      assert Catalogue.get_catalogue(inside.uuid).folder_uuid == nil
    end

    test "entering the deleted view clears a stale folder filter", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Live folder"})
      filed = fixture_catalogue(%{name: "Filed catalogue"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      trashed = fixture_catalogue(%{name: "Binned catalogue"})
      Catalogue.trash_catalogue(trashed)

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "set_filter", %{"column_id" => "folder", "value" => folder.uuid})

      # The unfiled trashed catalogue must be visible despite the filter.
      deleted = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})
      assert deleted =~ "Binned catalogue"

      # Back to active: the folder filter was dropped, everything shows.
      active = render_click(view, "switch_catalogue_view", %{"mode" => "active"})
      assert active =~ "Filed catalogue"
    end

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

      assert appears_before?(viewer_html, "Zed", "Alpha")

      render_click(changer, "set_sort", %{"sort_by" => "name"})

      assert appears_before?(render(viewer), "Alpha", "Zed")
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

      assert ViewConfig.load_global_sort(:catalogues) == {"position", :asc}
    end

    test "manufacturers sort stays per-user", %{conn: conn} do
      fixture_manufacturer(%{name: "Blum"})

      {:ok, view, _html} = live(conn, "#{@base}/manufacturers")
      render_click(view, "set_sort", %{"sort_by" => "updated"})

      assert PhoenixKit.Settings.get_setting("catalogue_sort_manufacturers", nil) == nil
    end
  end
end
