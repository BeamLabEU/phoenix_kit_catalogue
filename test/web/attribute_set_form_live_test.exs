defmodule PhoenixKitCatalogue.Web.AttributeSetFormLiveTest do
  @moduledoc """
  The set editor (2026-08-18 attribute-sets rework): values table with
  inline extras, the field-editor modal, the media picker wiring, and
  the crash-safety clauses. Pins the browser-verified behaviors the
  quality sweep found untested (C11, 2026-08-19).
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup %{conn: conn, scope: scope} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Editor colors"})
      {:ok, set} = Catalogue.add_attribute_set_field(set, %{label: "Price", type: "number"})
      {:ok, set} = Catalogue.add_attribute_set_field(set, %{label: "Swatch", type: "image"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})

      %{conn: with_scope(conn, scope), set: set, red: red}
    end

    defp open(conn, set) do
      live(conn, "/en/admin/catalogue/attributes/sets/#{set.uuid}/edit")
    end

    defp values(set), do: Catalogue.list_attribute_set_values(set)

    test "renders the values table and extra-field rows; no default star", %{
      conn: conn,
      set: set
    } do
      {:ok, _view, html} = open(conn, set)

      assert html =~ "Editor colors"
      assert html =~ "Red"
      assert html =~ "Price"
      # The default-value star is parked (user call 2026-08-19).
      refute html =~ "make_default"
    end

    test "add_value creates records — including non-Latin labels", %{conn: conn, set: set} do
      {:ok, view, _html} = open(conn, set)

      render_click(view, "add_value", %{"value" => "Blue"})
      render_click(view, "add_value", %{"value" => "Синий"})

      slugs = set |> values() |> Enum.map(& &1.slug)
      assert "blue" in slugs
      # The Cyrillic label got a usable (non-empty, unique) slug.
      assert length(slugs) == 3
      refute "" in slugs
    end

    test "rename_value and delete_value round-trip; forged uuids no-op", %{
      conn: conn,
      set: set,
      red: red
    } do
      {:ok, view, _html} = open(conn, set)

      render_click(view, "rename_value", %{"uuid" => red.uuid, "value" => "Crimson"})
      assert [%{title: "Crimson", slug: "red"}] = values(set)

      render_click(view, "rename_value", %{"uuid" => Ecto.UUID.generate(), "value" => "X"})
      assert [%{title: "Crimson"}] = values(set)

      render_click(view, "delete_value", %{"uuid" => red.uuid})
      assert values(set) == []
    end

    test "value_extras_changed casts valid input and flashes invalid input", %{
      conn: conn,
      set: set,
      red: red
    } do
      {:ok, view, _html} = open(conn, set)

      render_change(view, "value_extras_changed", %{
        "_target" => ["extras", "price"],
        "uuid" => red.uuid,
        "extras" => %{"price" => "12.5"}
      })

      assert [%{data: %{"price" => 12.5}}] = values(set)

      html =
        render_change(view, "value_extras_changed", %{
          "_target" => ["extras", "price"],
          "uuid" => red.uuid,
          "extras" => %{"price" => "not-a-number"}
        })

      assert html =~ "Invalid value"
      assert [%{data: %{"price" => 12.5}}] = values(set)
    end

    test "field-editor modal: add, refuse empty select, refuse duplicates", %{
      conn: conn,
      set: set
    } do
      {:ok, view, _html} = open(conn, set)

      # Add a select without any usable choice — stays in the modal
      # with the error, writes nothing.
      render_click(view, "open_field_editor", %{})

      html =
        render_click(view, "save_field_editor", %{
          "label" => "Finish",
          "type" => "select",
          "choices" => ["", ""]
        })

      assert html =~ "Add at least one choice"
      assert length(Catalogue.get_attribute_set(set.uuid).fields_definition) == 2

      # With choices it lands, options trimmed.
      render_click(view, "save_field_editor", %{
        "label" => "Finish",
        "type" => "select",
        "choices" => ["Matte", " Gloss ", ""]
      })

      fields = Catalogue.get_attribute_set(set.uuid).fields_definition
      assert %{"options" => ["Matte", "Gloss"]} = Enum.find(fields, &(&1["key"] == "finish"))

      # A second field with the same label is a duplicate key.
      render_click(view, "open_field_editor", %{})

      html =
        render_click(view, "save_field_editor", %{"label" => "Finish", "type" => "text"})

      assert html =~ "already exists"
    end

    test "confirm_remove_field removes after the confirm step", %{conn: conn, set: set} do
      {:ok, view, _html} = open(conn, set)

      render_click(view, "request_remove_field", %{"key" => "price"})
      render_click(view, "confirm_remove_field", %{})

      keys = Catalogue.get_attribute_set(set.uuid).fields_definition |> Enum.map(& &1["key"])
      assert keys == ["swatch"]
    end

    test "media pick flow: target staged, selection persisted, junk ignored", %{
      conn: conn,
      set: set,
      red: red
    } do
      {:ok, view, _html} = open(conn, set)

      render_click(view, "pick_value_media", %{"uuid" => red.uuid, "field" => "swatch"})
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.show_media_selector
      assert assigns.media_pick_target == %{value_uuid: red.uuid, field: "swatch"}
      assert assigns.media_filter == :image

      file_uuid = Ecto.UUID.generate()
      send(view.pid, {:media_selected, [file_uuid]})
      render(view)

      assert [%{data: %{"swatch" => ^file_uuid}}] = values(set)

      # clear_value_media wipes it again.
      render_click(view, "clear_value_media", %{"uuid" => red.uuid, "field" => "swatch"})
      assert [%{data: %{"swatch" => nil}}] = values(set)
    end

    test "stray messages and junk reorders never crash the editor", %{
      conn: conn,
      set: set,
      red: red
    } do
      {:ok, view, _html} = open(conn, set)

      # The admin on_mount hooks fall unconsumed broadcasts through to
      # the LV — the catch-all must absorb them (panel finding).
      send(view.pid, {:maintenance_status_changed, %{active: false}})
      send(view.pid, :complete_junk)
      assert render(view) =~ "Editor colors"

      render_click(view, "reorder_values", %{"ordered_ids" => ["junk", 42, red.uuid]})
      assert render(view) =~ "Red"
    end

    test "save in stay mode renames without navigating", %{conn: conn, set: set} do
      {:ok, view, _html} = open(conn, set)

      html =
        render_submit(view, "save", %{
          "set" => %{"name" => "Editor colors v2", "kind" => "fixed"},
          "save_action" => "stay"
        })

      assert html =~ "Editor colors v2"
      fresh = Catalogue.get_attribute_set(set.uuid)
      assert fresh.display_name == "Editor colors v2"
      assert Catalogue.attribute_set_kind(fresh) == "fixed"
    end
  else
    @tag :skip
    test "entities package lacks the Managed contract — suite skipped" do
      assert true
    end
  end
end
