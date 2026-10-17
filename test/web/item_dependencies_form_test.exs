defmodule PhoenixKitCatalogue.Web.ItemDependenciesFormTest do
  @moduledoc """
  The admin side of the V5 additions, driven through the real pages: the
  item form's Dependencies tab (staged until Save, like the supplier rows —
  adding from both pickers, typing, reordering, removing, a bad value
  blocking the whole save), the Internal box and the notes for AI on the
  forms, the Internal badge on the admin lists, and the permanent-delete
  confirmation naming the dependency lines a delete removes.
  """

  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWeb.Components.TreePicker

  @base "/en/admin/catalogues"

  defp form_selector, do: ~s|form[action="#"][phx-submit=save]|

  setup do
    furniture = fixture_catalogue(%{name: "Furniture"})
    screws = fixture_catalogue(%{name: "Screws"})
    wood = fixture_category(screws, %{name: "Wood screws", internal: true})
    susan = fixture_item(%{name: "Lazy susan", catalogue_uuid: furniture.uuid})

    screw =
      fixture_item(%{name: "Screw 4x30", catalogue_uuid: screws.uuid, category_uuid: wood.uuid})

    %{furniture: furniture, screws: screws, wood: wood, susan: susan, screw: screw}
  end

  defp open_tab(conn, item) do
    {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")
    render_click(view, "switch_tab", %{"tab" => "dependencies"})
    view
  end

  defp open_picker(view), do: view |> element("#dependency-add") |> render_click()

  # Selects `id` the way the pop-up's tree does.
  defp select(view, id) do
    send(view.pid, {TreePicker, "dependency-place-picker", id})
    render(view)
  end

  defp confirm(view, values \\ %{}) do
    view |> form("#dependency-picker-form", %{"picker" => values}) |> render_submit()
  end

  defp done(view), do: view |> element("#dependency-picker-done") |> render_click()

  # Opens the Add pop-up, selects `id`, adds it with the defaults and
  # closes the pop-up.
  defp pick_place(view, id) do
    open_picker(view)
    select(view, id)
    confirm(view)
    done(view)
  end

  defp pick_item(view, item), do: pick_place(view, "item:" <> item.uuid)

  defp search_picker(view, text) do
    view
    |> element("#dependency-place-picker-search")
    |> render_hook("search", %{"value" => text})
  end

  defp row_keys(view) do
    Regex.scan(~r/id="dependency-row-(\d+)"/, render(view), capture: :all_but_first)
    |> List.flatten()
  end

  defp save(view) do
    view |> form(form_selector(), %{"item" => %{"name" => "Lazy susan"}}) |> render_submit()
  end

  describe "the Dependencies tab" do
    test "starts empty and lists what the item already has", %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      assert has_element?(view, "#dependencies-empty")

      {:ok, _} =
        Catalogue.put_item_dependencies(ctx.susan, [
          %{target: {:catalogue, ctx.screws.uuid}, quantity: 8, note: "by wood type"},
          %{target: {:category, ctx.wood.uuid}, quantity: 1},
          %{target: {:item, ctx.screw.uuid}, quantity: 2}
        ])

      view = open_tab(conn, ctx.susan)
      assert has_element?(view, "[data-dependency-kind=catalogue]", "Screws")
      refute has_element?(view, ~s([data-internal-badge="#{ctx.screws.uuid}"]))
      # The category is internal, and so is the item filed under it.
      assert has_element?(view, ~s([data-internal-badge="#{ctx.wood.uuid}"]))
      assert has_element?(view, ~s([data-internal-badge="#{ctx.screw.uuid}"]))
      assert has_element?(view, ~s(input[value="by wood type"]))
    end

    test "adds a catalogue, a category and an item, then saves them in order",
         %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)

      pick_place(view, "catalogue:" <> ctx.screws.uuid)
      pick_place(view, "category:" <> ctx.wood.uuid)
      pick_item(view, ctx.screw)

      [first, second, _third] = row_keys(view)

      view
      |> element("#dependency-rows-form")
      |> render_change(%{
        "dependencies" => %{
          first => %{"quantity" => "8", "note" => "pick by wood type"},
          second => %{"quantity" => "2,5", "note" => ""}
        }
      })

      # Nothing is written until Save.
      assert Catalogue.list_item_dependencies(ctx.susan) == []

      save(view)

      assert [
               %{target_catalogue_uuid: screws, note: "pick by wood type"} = a,
               %{target_category_uuid: wood} = b,
               %{target_item_uuid: screw}
             ] = Catalogue.list_item_dependencies(ctx.susan)

      assert {screws, wood, screw} == {ctx.screws.uuid, ctx.wood.uuid, ctx.screw.uuid}
      assert Decimal.equal?(a.quantity, 8)
      assert Decimal.equal?(b.quantity, Decimal.new("2.5"))
    end

    test "moves and removes rows before saving", %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      pick_place(view, "catalogue:" <> ctx.screws.uuid)
      pick_item(view, ctx.screw)
      [catalogue_row, item_row] = row_keys(view)

      render_click(view, "dependency_move", %{"key" => item_row, "direction" => "up"})
      assert row_keys(view) == [item_row, catalogue_row]

      view
      |> element(~s(#dependency-row-#{item_row} button[phx-value-direction="down"]))
      |> render_click()

      assert row_keys(view) == [catalogue_row, item_row]
      render_click(view, "dependency_move", %{"key" => item_row, "direction" => "up"})

      render_click(view, "dependency_remove", %{"key" => catalogue_row})
      save(view)

      assert [%{target_item_uuid: screw}] = Catalogue.list_item_dependencies(ctx.susan)
      assert screw == ctx.screw.uuid
    end

    test "a bad quantity blocks the whole save and opens the tab", %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      pick_item(view, ctx.screw)
      [row] = row_keys(view)

      view
      |> element("#dependency-rows-form")
      |> render_change(%{"dependencies" => %{row => %{"quantity" => "0", "note" => ""}}})

      render_click(view, "switch_tab", %{"tab" => "details"})

      html =
        view
        |> form(form_selector(), %{"item" => %{"name" => "Renamed susan"}})
        |> render_submit()

      assert html =~ "Some dependency values are not valid."
      assert html =~ "Enter a quantity above zero, with at most four decimal places."
      assert :sys.get_state(view.pid).socket.assigns.current_tab == :dependencies
      # Not half-applied: the item's own fields did not save either.
      assert Catalogue.get_item(ctx.susan.uuid).name == "Lazy susan"
      assert Catalogue.list_item_dependencies(ctx.susan) == []
    end

    test "Add opens one tree of catalogues, categories and items; a picked row is staged",
         %{conn: conn} = ctx do
      {:ok, _} = Catalogue.update_item(ctx.screw, %{sku: "S-430"})
      view = open_tab(conn, ctx.susan)
      refute has_element?(view, "#dependency-picker")

      view |> element("#dependency-add") |> render_click()
      assert has_element?(view, "#dependency-picker")
      assert has_element?(view, ~s([data-tree-node="catalogue:#{ctx.screws.uuid}"]))

      # Found by SKU as well as by name, under its catalogue and category.
      search_picker(view, "s-430")
      assert has_element?(view, ~s([data-tree-node="item:#{ctx.screw.uuid}"]), "Screw 4x30")
      assert has_element?(view, ~s([data-tree-node="category:#{ctx.wood.uuid}"]))

      # The item being edited is not offered.
      search_picker(view, "Lazy")
      refute has_element?(view, ~s([data-tree-node="item:#{ctx.susan.uuid}"]))

      # Nothing is chosen yet, so there is nothing to add.
      assert has_element?(view, "#dependency-picker-selection", "Nothing selected yet.")
      assert has_element?(view, "#dependency-picker-confirm[disabled]")

      # Picking a row only selects it: the pop-up stays, showing the path.
      search_picker(view, "4x30")
      view |> element(~s([data-tree-node="item:#{ctx.screw.uuid}"])) |> render_click()

      assert has_element?(view, "#dependency-picker")

      assert has_element?(
               view,
               "#dependency-picker-selection",
               "Screws › Wood screws › Screw 4x30"
             )

      refute has_element?(view, "#dependency-picker-confirm[disabled]")
      assert row_keys(view) == []

      confirm(view, %{"quantity" => "8", "note" => "by wood type"})

      # Staged, and the pop-up stays for the next pick: the search is kept,
      # the selection, quantity and note start over, and it says what landed.
      assert has_element?(view, "#dependency-picker")
      assert has_element?(view, "#dependency-picker-added", "Added 8 × Screw 4x30.")
      assert has_element?(view, ~s(#dependency-place-picker-search[value="4x30"]))
      assert has_element?(view, "#dependency-picker-selection", "Nothing selected yet.")
      assert has_element?(view, ~s(#dependency-picker-quantity[value="1"]))
      assert has_element?(view, "#dependency-picker-confirm[disabled]")

      # A category reads as what its line means.
      select(view, "category:" <> ctx.wood.uuid)

      assert has_element?(
               view,
               "#dependency-picker-selection",
               "Any item in Screws › Wood screws"
             )

      confirm(view, %{"quantity" => "2"})
      assert has_element?(view, "#dependency-picker-added", "Added 2 × Wood screws.")

      done(view)
      refute has_element?(view, "#dependency-picker")
      assert has_element?(view, "[data-dependency-kind=item]", "Screw 4x30")
      assert has_element?(view, "#item-dependencies", "Screws › Wood screws")
      [key, _category_key] = row_keys(view)
      assert has_element?(view, ~s(#dependency-#{key}-quantity[value="8"]))
      assert has_element?(view, ~s(#dependency-#{key}-note[value="by wood type"]))
    end

    test "Add holds a bad quantity or note in the pop-up instead of staging it",
         %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      open_picker(view)
      select(view, "item:" <> ctx.screw.uuid)

      html = confirm(view, %{"quantity" => "0"})
      assert html =~ "Enter a quantity above zero, with at most four decimal places."
      assert has_element?(view, "#dependency-picker")
      assert row_keys(view) == []

      html = confirm(view, %{"quantity" => "2", "note" => String.duplicate("x", 501)})
      assert html =~ "The note is too long"
      assert row_keys(view) == []

      confirm(view, %{"quantity" => "2.5", "note" => ""})
      assert [_row] = row_keys(view)
    end

    test "the pop-up says when the selection is already on the list", %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      open_picker(view)
      select(view, "item:" <> ctx.screw.uuid)
      refute has_element?(view, "#dependency-picker-listed")
      confirm(view)

      # Also for a line added in this same sitting.
      select(view, "item:" <> ctx.screw.uuid)
      assert has_element?(view, "#dependency-picker-listed")

      # Allowed all the same: the same target may be listed twice.
      confirm(view)
      assert length(row_keys(view)) == 2
    end

    test "the Add pop-up closes without adding anything", %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      view |> element("#dependency-add") |> render_click()
      select(view, "item:" <> ctx.screw.uuid)
      done(view)

      refute has_element?(view, "#dependency-picker")
      assert row_keys(view) == []
    end

    test "a malformed push changes nothing and does not crash the form", %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      pick_item(view, ctx.screw)

      render_click(view, "dependency_remove", %{})
      render_click(view, "dependency_move", %{"key" => "1", "direction" => "sideways"})
      render_click(view, "dependency_move", %{"key" => %{"x" => 1}, "direction" => "up"})

      assert Process.alive?(view.pid)
      assert length(row_keys(view)) == 1
    end

    test "a target deleted for good meanwhile blocks the save before a new item is created",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, "#{@base}/#{ctx.furniture.uuid}/items/new")
      pick_item(view, ctx.screw)

      {:ok, trashed} = Catalogue.trash_item(ctx.screw)
      {:ok, _} = Catalogue.permanently_delete_item(trashed)

      html =
        view
        |> form(form_selector(), %{"item" => %{"name" => "Orphan carousel", "status" => "active"}})
        |> render_submit()

      assert html =~ "This no longer exists. Remove the line to save."
      assert Catalogue.search_items("Orphan carousel") == []
      # The staged row is still there to remove.
      assert [_row] = row_keys(view)
    end

    test "the item itself cannot be selected", %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      open_picker(view)
      select(view, "item:" <> ctx.susan.uuid)

      # Not in the tree, so the selection is refused and Add stays off.
      assert has_element?(view, "#dependency-picker-confirm[disabled]")
      confirm(view)
      assert row_keys(view) == []
    end

    test "a target trashed since the tree was drawn is refused on Add", %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      open_picker(view)
      select(view, "category:" <> ctx.wood.uuid)
      {:ok, _} = Catalogue.trash_category(ctx.wood)

      html = confirm(view)
      assert html =~ "That no longer exists. Choose another."
      assert has_element?(view, "#dependency-picker")
      assert row_keys(view) == []
    end

    test "a new item saves its dependencies after it is created", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, "#{@base}/#{ctx.furniture.uuid}/items/new")
      pick_item(view, ctx.screw)

      {:error, {:live_redirect, _}} =
        view
        |> form(form_selector(), %{"item" => %{"name" => "Corner carousel", "status" => "active"}})
        |> render_submit()

      [created] =
        Catalogue.search_items("Corner carousel", catalogue_uuids: [ctx.furniture.uuid])

      assert [%{target_item_uuid: screw}] = Catalogue.list_item_dependencies(created)
      assert screw == ctx.screw.uuid
    end

    test "a crafted value in the rows form is ignored, not a crash", %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      pick_item(view, ctx.screw)
      [row] = row_keys(view)

      render_change(view, "dependency_change", %{
        "dependencies" => %{row => %{"quantity" => %{"x" => "1"}, "note" => ["a"]}}
      })

      render_change(view, "dependency_change", %{"dependencies" => "nope"})

      assert Process.alive?(view.pid)
      assert has_element?(view, ~s(input[name="dependencies[#{row}][quantity]"][value="1"]))
    end

    test "Save writes the activity row under the signed-in admin", %{conn: conn} = ctx do
      scope = build_admin_scope()
      view = conn |> with_scope(scope) |> open_tab(ctx.susan)
      pick_item(view, ctx.screw)
      save(view)

      assert_activity_logged("item.dependencies_synced",
        resource_uuid: ctx.susan.uuid,
        actor_uuid: scope.user.uuid
      )
    end

    test "two admins: the second Save does not overwrite the first, and says so",
         %{conn: conn} = ctx do
      first = open_tab(conn, ctx.susan)
      second = open_tab(conn, ctx.susan)

      pick_item(first, ctx.screw)
      pick_place(second, "catalogue:" <> ctx.screws.uuid)

      save(first)

      html =
        second
        |> form(form_selector(), %{"item" => %{"name" => "Lazy susan, oiled"}})
        |> render_submit()

      assert html =~ "Someone else saved this item&#39;s dependencies"
      # Found before anything was written: the rename did not land alone.
      assert Catalogue.get_item(ctx.susan.uuid).name == "Lazy susan"
      # The first admin's list stands; the second keeps what they staged.
      assert [%{target_item_uuid: screw}] = Catalogue.list_item_dependencies(ctx.susan)
      assert screw == ctx.screw.uuid
      assert has_element?(second, "[data-dependency-kind=catalogue]", "Screws")

      # Saving again is now a deliberate replace, and goes through.
      save(second)
      assert [%{target_catalogue_uuid: screws}] = Catalogue.list_item_dependencies(ctx.susan)
      assert screws == ctx.screws.uuid
    end

    test "an untouched tab picks up a list saved in another tab", %{conn: conn} = ctx do
      watcher = open_tab(conn, ctx.susan)
      editor = open_tab(conn, ctx.susan)

      pick_item(editor, ctx.screw)
      save(editor)

      eventually(fn -> has_element?(watcher, "[data-dependency-kind=item]", "Screw 4x30") end)
    end

    test "an untouched tab writes no activity row on save", %{conn: conn} = ctx do
      view = open_tab(conn, ctx.susan)
      save(view)
      refute_activity_logged("item.dependencies_synced", resource_uuid: ctx.susan.uuid)
    end
  end

  describe "the Internal box and the notes for AI" do
    test "the catalogue form saves its notes and has no Internal box", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, "#{@base}/#{ctx.furniture.uuid}/edit")
      refute has_element?(view, ~s(input[name="catalogue[internal]"]))

      view
      |> form(form_selector(), %{
        "catalogue" => %{"name" => "Furniture", "ai_notes" => "Prices exclude VAT."}
      })
      |> render_submit()

      assert Catalogue.get_catalogue(ctx.furniture.uuid).ai_notes == "Prices exclude VAT."
    end

    test "the category form saves the Internal box", %{conn: conn} = ctx do
      chairs = fixture_category(ctx.furniture, %{name: "Chairs"})
      {:ok, view, _html} = live(conn, "#{@base}/categories/#{chairs.uuid}/edit")

      view
      |> form(form_selector(), %{"category" => %{"name" => "Chairs", "internal" => "true"}})
      |> render_submit()

      assert Catalogue.get_category(chairs.uuid).internal

      {:ok, view, _html} = live(conn, "#{@base}/categories/#{chairs.uuid}/edit")

      view
      |> form(form_selector(), %{"category" => %{"name" => "Chairs", "internal" => "false"}})
      |> render_submit()

      refute Catalogue.get_category(chairs.uuid).internal
    end

    test "the category and item forms save their notes", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, "#{@base}/categories/#{ctx.wood.uuid}/edit")

      view
      |> form(form_selector(), %{
        "category" => %{"name" => "Wood screws", "ai_notes" => "Pick by length."}
      })
      |> render_submit()

      assert Catalogue.get_category(ctx.wood.uuid).ai_notes == "Pick by length."

      {:ok, view, _html} = live(conn, "#{@base}/items/#{ctx.susan.uuid}/edit")

      view
      |> form(form_selector(), %{"item" => %{"name" => "Lazy susan", "ai_notes" => "Turns 360°."}})
      |> render_submit()

      assert Catalogue.get_item(ctx.susan.uuid).ai_notes == "Turns 360°."
    end

    test "the admin pages badge an internal category and its subtree", %{conn: conn} = ctx do
      plain = fixture_category(ctx.screws, %{name: "Metal screws"})
      child = fixture_category(ctx.screws, %{name: "Short", parent_uuid: ctx.wood.uuid})

      {:ok, view, _html} = live(conn, "#{@base}/#{ctx.screws.uuid}")
      assert has_element?(view, ~s([data-internal-badge="#{ctx.wood.uuid}"]))
      refute has_element?(view, ~s([data-internal-badge="#{plain.uuid}"]))
      refute has_element?(view, "#detail-level-caption [data-internal-badge]")

      {:ok, view, _html} = live(conn, "#{@base}/#{ctx.screws.uuid}?category=#{child.uuid}")
      assert has_element?(view, "#detail-level-caption [data-internal-badge]")

      {:ok, view, _html} = live(conn, @base)
      refute has_element?(view, "[data-internal-badge]")
    end
  end

  describe "permanent delete" do
    test "the catalogue confirmation names the dependency lines it removes",
         %{conn: conn} = ctx do
      {:ok, _} =
        Catalogue.put_item_dependencies(ctx.susan, [
          %{target: {:catalogue, ctx.screws.uuid}, quantity: 8}
        ])

      {:ok, _} = Catalogue.trash_catalogue(ctx.screws)
      {:ok, view, _html} = live(conn, @base)
      render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      html =
        render_click(view, "show_delete_confirm", %{
          "uuid" => ctx.screws.uuid,
          "type" => "catalogue"
        })

      assert html =~ "1 other item lists something this removes as a dependency."
    end

    test "the confirmation names the dependency lines it removes", %{conn: conn} = ctx do
      {:ok, _} =
        Catalogue.put_item_dependencies(ctx.susan, [
          %{target: {:item, ctx.screw.uuid}, quantity: 8}
        ])

      {:ok, _} = Catalogue.trash_item(ctx.screw)

      {:ok, view, _html} = live(conn, "#{@base}/#{ctx.screws.uuid}")
      render_click(view, "switch_view", %{"mode" => "deleted"})

      html =
        render_click(view, "show_delete_confirm", %{"uuid" => ctx.screw.uuid, "type" => "item"})

      assert html =~ "1 other item lists something this removes as a dependency."
    end
  end

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
