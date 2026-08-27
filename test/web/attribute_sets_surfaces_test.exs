defmodule PhoenixKitCatalogue.Web.AttributeSetsSurfacesTest do
  @moduledoc """
  The remaining attribute-sets UI surfaces the quality sweep found
  untested (C11, 2026-08-19): the sets listing tab and its delete flow,
  the legacy group-form redirect, the OrphanPruner subscriber, the
  product card's selection-aware attribute rows, the catalogue-detail
  bottom navigation, and the set Paths.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Catalogue.AttributeSets.OrphanPruner
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Test.Repo
  alias PhoenixKitCatalogue.Web.Components.ProductCard

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup %{conn: conn, scope: scope} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      %{conn: with_scope(conn, scope)}
    end

    describe "CataloguesLive attributes tab (sets enabled)" do
      test "the tab is a VIEWER: values and attached items, no edit or delete", %{conn: conn} do
        # 2026-08-27 direction: the subtab shows sets and the items
        # they're attached to; ALL editing lives in the entities module.
        {:ok, set} = Catalogue.create_attribute_set(%{name: "Tab colors"})
        {:ok, _red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
        item = fixture_item(%{name: "TabItem"})
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

        {:ok, view, html} = live(conn, "/en/admin/catalogue/attributes")

        assert :sys.get_state(view.pid).socket.assigns.sets_enabled
        assert html =~ "Tab colors"
        # The viewer shows the set's values and its attached items…
        assert html =~ "Red"
        assert html =~ "TabItem"
        # …links every edit affordance into entities…
        assert html =~ "/admin/entities/#{set.name}/data"
        assert html =~ "/admin/entities/#{set.uuid}/edit"
        # …and carries no delete flow of its own — the handler itself is
        # gone (a crafted push would FunctionClauseError, proving no code
        # path on this LV can delete a set).
        refute html =~ "delete_attribute_set"
        refute html =~ "show_delete_confirm"
        assert %{} = Catalogue.get_attribute_set(set.uuid)
      end

      test "New Set collects a name only, stamps ownership, hands off to entities", %{
        conn: conn
      } do
        {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

        render_click(view, "open_new_set_modal", %{})

        assert {:error, {:live_redirect, %{to: to}}} =
                 view
                 |> element("#new-attribute-set-modal form")
                 |> render_submit(%{"name" => "Handed Off"})

        # Straight to ADDING VALUES — not the blueprint editor.
        assert to =~ "/admin/entities/"
        assert to =~ "/data/new"

        [set] =
          Catalogue.list_attribute_sets()
          |> Enum.filter(&(&1.display_name == "Handed Off"))

        # The one reason creation stays here: the managed stamp. Kind is
        # no longer asked for (nothing consumes it) and defaults quietly.
        assert PhoenixKitEntities.Managed.owner(set) == "catalogue"
        assert Catalogue.attribute_set_kind(set) == "multi"

        # Kind is stored but HIDDEN from every surface until something
        # consumes it (Max, 2026-08-27) — no badge, no column.
        {:ok, _view, listing} = live(conn, "/en/admin/catalogue/attributes")
        refute listing =~ "Fixed value"
        refute listing =~ "Multiple values"
      end

      test "a thousand of anything stays capped: pages, chips, previews", %{conn: conn} do
        # 30 sets -> two pages; one set with 12 values and 7 items ->
        # capped chips + "+N" to entities, capped item links + plain
        # overflow count. Counts stay the REAL numbers throughout.
        {:ok, big} = Catalogue.create_attribute_set(%{name: "Big Set"})

        for i <- 1..12 do
          {:ok, _} = Catalogue.create_attribute_set_value(big, %{label: "Val #{i}"})
        end

        for i <- 1..7 do
          item = fixture_item(%{name: "BigItem #{String.pad_leading(to_string(i), 2, "0")}"})
          {:ok, _} = Catalogue.attach_attribute_set(item.uuid, big.uuid)
        end

        for i <- 1..29 do
          {:ok, _} =
            Catalogue.create_attribute_set(%{
              name: "Filler #{String.pad_leading(to_string(i), 2, "0")}"
            })
        end

        {:ok, view, html} = live(conn, "/en/admin/catalogue/attributes")

        # Page 1 of 2, 30 sets total; page 2 reachable and clamped.
        assert html =~ "Page 1 of 2"
        refute html =~ "Filler 29"
        html = render_click(view, "attr_sets_page", %{"dir" => "next"})
        assert html =~ "Filler 29"
        html = render_click(view, "attr_sets_page", %{"dir" => "next"})
        assert html =~ "Page 2 of 2"

        # Search narrows and resets to page 1.
        html = render_change(view, "attr_sets_search", %{"q" => "Big Set"})
        assert html =~ "Big Set"
        refute html =~ "Filler 01"

        # Chips capped with the real count and a "+N" LINK to entities —
        # never all twelve inline.
        assert html =~ "Val 1"
        refute html =~ "Val 12"
        assert html =~ "(12)"
        assert html =~ "/admin/entities/#{big.name}/data"

        # Item links capped; overflow is a plain count, not a link dump.
        assert html =~ "BigItem 01"
        refute html =~ "BigItem 07"
        assert html =~ "and 2 more"
        assert html =~ "(7)"

        # The kebab carries the only actions, in both faces.
        assert html =~ ~s(id="attr-set-menu-t-#{big.uuid}")
        assert html =~ ~s(id="attr-set-menu-c-#{big.uuid}")
      end

      test "the static render shows a skeleton, never the legacy empty state", %{conn: conn} do
        # Data is deferred to the connected mount (whole-LV pattern); the
        # HTTP render used to flash "No attribute groups yet" from the
        # LEGACY branch before the sets loaded.
        {:ok, _} = Catalogue.create_attribute_set(%{name: "Flash Guard"})

        static = conn |> get("/en/admin/catalogue/attributes") |> html_response(200)
        refute static =~ "No attribute groups yet"
        refute static =~ "No sets yet"
        assert static =~ "skeleton"

        # The connected mount replaces the skeleton with the real listing.
        {:ok, _view, html} = live(conn, "/en/admin/catalogue/attributes")
        assert html =~ "Flash Guard"
        refute html =~ "skeleton h-24"
      end

      test "no-match search says so instead of rendering silence", %{conn: conn} do
        {:ok, _} = Catalogue.create_attribute_set(%{name: "Only Set"})
        {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

        html = render_change(view, "attr_sets_search", %{"q" => "zzz-nothing"})
        assert html =~ "No sets match your search."
      end

      test "the deferred backstop migration message reloads without crashing", %{conn: conn} do
        {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

        send(view.pid, :auto_migrate_legacy)
        assert render(view)
      end
    end

    describe "AttributeGroupFormLive with sets live" do
      test "redirects to the attributes listing instead of rendering", %{conn: conn} do
        assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
                 live(conn, "/en/admin/catalogue/attributes/new")

        assert to == Paths.attribute_groups()
        assert flash["info"] =~ "replaced by sets"
      end
    end

    describe "OrphanPruner subscriber" do
      test "prunes on :entity_deleted, absorbs everything else" do
        {:ok, set} = Catalogue.create_attribute_set(%{name: "Pruned"})
        item = fixture_item(%{name: "PrunedItem"})
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

        # Out-of-band delete (bypasses the guard), then the PubSub
        # handler — invoked directly so the sandbox owns the DB calls.
        Repo.delete!(set)
        assert {:noreply, %{}} = OrphanPruner.handle_info({:entity_deleted, set.uuid}, %{})
        assert Catalogue.list_attribute_set_attachments(item.uuid) == []

        # Shared-topic traffic and junk payloads are absorbed.
        assert {:noreply, %{}} = OrphanPruner.handle_info({:entity_created, set.uuid}, %{})
        assert {:noreply, %{}} = OrphanPruner.handle_info({:entity_deleted, "junk"}, %{})
        assert {:noreply, %{}} = OrphanPruner.handle_info(:noise, %{})
      end
    end

    describe "product card attribute rows" do
      test "selection narrows the set row; no selection shows all values" do
        {:ok, set} = Catalogue.create_attribute_set(%{name: "Card colors"})
        {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
        {:ok, _} = Catalogue.create_attribute_set_value(set, %{label: "Blue"})

        item = fixture_item(%{name: "CardItem"})
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
        item = Catalogue.get_item(item.uuid)

        # No selection → the whole set renders.
        assert {"Card colors", "Red, Blue"} in ProductCard.build_fields(item, "en")

        # One tick → this exact object.
        :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [red.slug])
        assert {"Card colors", "Red"} in ProductCard.build_fields(item, "en")
      end
    end

    describe "catalogue detail bottom navigation" do
      test "root shows All catalogues; category level adds Up one level", %{conn: conn} do
        catalogue = fixture_catalogue(%{name: "NavCat"})
        category = fixture_category(catalogue, %{name: "NavCategory"})

        {:ok, _view, root_html} = live(conn, "/en/admin/catalogue/#{catalogue.uuid}")
        assert root_html =~ "All catalogues"
        refute root_html =~ "Up one level"

        {:ok, _view, cat_html} =
          live(conn, "/en/admin/catalogue/#{catalogue.uuid}?category=#{category.uuid}")

        assert cat_html =~ "Up one level"
        assert cat_html =~ "All catalogues"
      end
    end

    describe "paths" do
      test "the set editor paths are gone — editing moved to entities" do
        refute function_exported?(Paths, :attribute_set_new, 0)
        refute function_exported?(Paths, :attribute_set_edit, 1)
      end
    end
  else
    @tag :skip
    test "entities package lacks the Managed contract — suite skipped" do
      assert true
    end
  end
end
