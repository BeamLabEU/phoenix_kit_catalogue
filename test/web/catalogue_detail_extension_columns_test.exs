defmodule PhoenixKitCatalogue.Web.CatalogueDetailExtensionColumnsTest do
  @moduledoc """
  End-to-end coverage for the catalogue detail page's item/category
  tables picking up a shop-extension's contributed column (the
  duck-typed `item_columns/0` / `category_columns/0` slot on
  `PhoenixKitCatalogue.Extension`, discovered via
  `PhoenixKitCatalogue.Extensions.columns/1`) — plus the managed
  "Image" column both tables gained alongside it.

  Mutates the process-global `PhoenixKit.ModuleRegistry`, so
  `async: false` — same pattern as `PhoenixKitCatalogue.ExtensionsTest`.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Test.BrokenColumnsModule
  alias PhoenixKitCatalogue.Test.FakeModule
  alias PhoenixKitCatalogue.Web.ViewConfig

  @base "/en/admin/catalogue"

  defp url(uuid), do: "#{@base}/#{uuid}"

  describe "the extension columns slot, with FakeExtension registered" do
    setup do
      start_supervised!(PhoenixKit.ModuleRegistry)
      :ok = PhoenixKit.ModuleRegistry.register(FakeModule)

      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), FakeModule)
        )
      end)

      :ok
    end

    test "the contributed column appears in the Columns modal's Available list for items",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Ext cols"})
      fixture_item(%{name: "Widget", sku: "W-1", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")

      opened = render_click(view, "show_column_modal", %{})
      assert opened =~ "Fake status"
      assert opened =~ ~s(phx-value-column_id="fake:status")
      assert opened =~ ~s(phx-value-scope="detail_items")
    end

    test "the contributed column appears in the Columns modal's Available list for categories",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Ext cat cols"})
      fixture_category(catalogue, %{name: "Configurable"})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      opened = render_click(view, "show_column_modal", %{})
      assert opened =~ "Fake status"
      assert opened =~ ~s(phx-value-column_id="fake:status")
      assert opened =~ ~s(phx-value-scope="detail_categories")
    end

    test "adding it renders the extension's cell content in the items table", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Ext render items"})
      item = fixture_item(%{name: "Widget", sku: "W-1", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")

      render_click(view, "show_column_modal", %{})

      updated =
        render_click(view, "add_column", %{
          "column_id" => "fake:status",
          "scope" => "detail_items"
        })

      assert updated =~ "fake-status"
      assert updated =~ "ext-fake-status-#{item.uuid}"
    end

    test "adding it renders the extension's cell content in the categories table",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Ext render categories"})
      category = fixture_category(catalogue, %{name: "Configurable"})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      render_click(view, "show_column_modal", %{})

      updated =
        render_click(view, "add_column", %{
          "column_id" => "fake:status",
          "scope" => "detail_categories"
        })

      assert updated =~ "fake-status"
      assert updated =~ "ext-fake-status-#{category.uuid}"
    end
  end

  describe "no extension registered" do
    test "the page renders fine and offers no shop-extension column", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "No ext"})
      fixture_item(%{name: "Widget", sku: "W-1", catalogue_uuid: catalogue.uuid})

      {:ok, view, html} = live(conn, url(catalogue.uuid) <> "?mode=items")
      assert html =~ "Widget"

      opened = render_click(view, "show_column_modal", %{})
      refute opened =~ "Fake status"
    end

    test "a previously-saved but now-unknown extension column id is dropped, not rendered",
         %{conn: conn, scope: scope} do
      catalogue = fixture_catalogue(%{name: "Stale ext column"})
      fixture_item(%{name: "Widget", sku: "W-1", catalogue_uuid: catalogue.uuid})

      # Simulates an admin who picked the extension's column while it was
      # registered; the extension is gone by the time this user loads the
      # page (uninstalled, disabled, or simply not on this deploy). Needs
      # the REAL user row (`with_scope/2`'s bare `%{uuid:}` doesn't match
      # `ViewConfig.save/3`'s `%Auth.User{}` clause and would silently
      # no-op the save).
      user = Auth.get_user!(scope.user.uuid)
      cfg = %{ViewConfig.load(user, :detail_items) | columns: ["sku", "fake:status"]}
      {:ok, _updated_user} = ViewConfig.save(user, :detail_items, cfg)
      conn = with_scope(conn, scope)

      {:ok, _view, html} = live(conn, url(catalogue.uuid) <> "?mode=items")

      assert html =~ "Widget"
      refute html =~ "fake-status"
    end
  end

  describe "a raising extension" do
    setup do
      start_supervised!(PhoenixKit.ModuleRegistry)
      :ok = PhoenixKit.ModuleRegistry.register(BrokenColumnsModule)

      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), BrokenColumnsModule)
        )
      end)

      :ok
    end

    test "does not break the page or the Columns modal", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Broken ext"})
      fixture_item(%{name: "Widget", sku: "W-1", catalogue_uuid: catalogue.uuid})

      {:ok, view, html} = live(conn, url(catalogue.uuid) <> "?mode=items")
      assert html =~ "Widget"

      opened = render_click(view, "show_column_modal", %{})
      refute opened =~ "boom"
    end
  end
end
