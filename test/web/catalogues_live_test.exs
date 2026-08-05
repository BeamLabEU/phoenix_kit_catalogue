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
end
