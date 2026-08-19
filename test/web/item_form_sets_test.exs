defmodule PhoenixKitCatalogue.Web.ItemFormSetsTest do
  @moduledoc """
  The item form's attribute-sets tab (2026-08-18 rework): staging
  attach/detach, the boss's two-modes checkbox selection, and the save
  that applies staged state through the context. Pins the
  browser-verified behaviors the quality sweep found untested (C11,
  2026-08-19).
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup %{conn: conn, scope: scope} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Form colors"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
      {:ok, blue} = Catalogue.create_attribute_set_value(set, %{label: "Blue"})

      cat = fixture_catalogue(%{name: "SetsCat"})
      item = fixture_item(%{name: "SetsItem", catalogue_uuid: cat.uuid})

      %{conn: with_scope(conn, scope), set: set, red: red, blue: blue, item: item}
    end

    defp open(conn, item), do: live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

    defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

    defp save(view) do
      view
      |> form("form[action=\"#\"][phx-submit=save]", %{"item" => %{}})
      |> render_submit()
    end

    test "attach stages the set and save persists the attachment", %{
      conn: conn,
      item: item,
      set: set
    } do
      {:ok, view, html} = open(conn, item)
      assert html =~ "Form colors"
      assert Catalogue.list_attribute_set_attachments(item.uuid) == []

      render_change(view, "attach_set", %{"attach_set_uuid" => set.uuid})
      assert assigns(view).staged_set_uuids == [set.uuid]
      # Staged only — nothing persisted until save.
      assert Catalogue.list_attribute_set_attachments(item.uuid) == []

      save(view)
      assert [%{set_uuid: attached}] = Catalogue.list_attribute_set_attachments(item.uuid)
      assert attached == set.uuid
    end

    test "toggle_value_selection stages ticks and save writes them", %{
      conn: conn,
      item: item,
      set: set,
      red: red,
      blue: blue
    } do
      {:ok, view, _html} = open(conn, item)
      render_change(view, "attach_set", %{"attach_set_uuid" => set.uuid})

      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => red.slug})
      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => blue.slug})
      # Untick red again — several → one.
      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => red.slug})

      # Junk pushes are ignored: unknown key, unstaged set.
      render_click(view, "toggle_value_selection", %{"set" => set.uuid, "key" => "ghost"})

      render_click(view, "toggle_value_selection", %{
        "set" => Ecto.UUID.generate(),
        "key" => red.slug
      })

      assert assigns(view).staged_selections[set.uuid] == MapSet.new([blue.slug])

      save(view)

      assert %{sets: [%{selected: selected}]} =
               Catalogue.resolve_attribute_sets_for_item(item.uuid)

      assert selected == [blue.slug]
    end

    test "stored selections hydrate on mount and detach drops them", %{
      conn: conn,
      item: item,
      set: set,
      red: red
    } do
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [red.slug, "ghost"])

      {:ok, view, _html} = open(conn, item)

      # Ghosts are intersected away on hydration (single ghost rule).
      assert assigns(view).staged_selections[set.uuid] == MapSet.new([red.slug])

      render_click(view, "detach_set", %{"uuid" => set.uuid})
      assert assigns(view).staged_set_uuids == []
      assert assigns(view).staged_selections[set.uuid] == nil

      save(view)
      assert Catalogue.list_attribute_set_attachments(item.uuid) == []
    end

    test "sets tab replaces the legacy group card when sets are live", %{
      conn: conn,
      item: item
    } do
      {:ok, _view, html} = open(conn, item)
      assert html =~ "Form colors"
      refute html =~ "phx-change=\"select_attribute_group\""
    end
  else
    @tag :skip
    test "entities package lacks the Managed contract — suite skipped" do
      assert true
    end
  end
end
