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

      test "New Set collects name+kind, stamps ownership, hands off to entities", %{conn: conn} do
        {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

        render_click(view, "open_new_set_modal", %{})

        assert {:error, {:live_redirect, %{to: to}}} =
                 view
                 |> element("#new-attribute-set-modal form")
                 |> render_submit(%{"name" => "Handed Off", "kind" => "fixed"})

        # Straight to ADDING VALUES — not the blueprint editor.
        assert to =~ "/admin/entities/"
        assert to =~ "/data/new"

        [set] =
          Catalogue.list_attribute_sets()
          |> Enum.filter(&(&1.display_name == "Handed Off"))

        # The one reason creation stays here: the managed stamp + the
        # post-creation-locked kind.
        assert PhoenixKitEntities.Managed.owner(set) == "catalogue"
        assert Catalogue.attribute_set_kind(set) == "fixed"
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
