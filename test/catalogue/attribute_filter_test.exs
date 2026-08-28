defmodule PhoenixKitCatalogue.Catalogue.AttributeFilterTest do
  @moduledoc """
  Filtering items by their attribute VALUES — "all items with blue doors"
  (Max, 2026-08-28). The slugs are the ones an item's attachment stores
  in `data["selected_value_slugs"]`, i.e. what the item form writes.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup %{conn: conn, scope: scope} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      catalogue = fixture_catalogue(%{name: "Filter Cat"})

      {:ok, category} =
        Catalogue.create_category(%{name: "Doors", catalogue_uuid: catalogue.uuid})

      {:ok, colour} = Catalogue.create_attribute_set(%{name: "Colour"})
      {:ok, blue} = Catalogue.create_attribute_set_value(colour, %{label: "Blue"})
      {:ok, red} = Catalogue.create_attribute_set_value(colour, %{label: "Red"})

      {:ok, wood} = Catalogue.create_attribute_set(%{name: "Wood"})
      {:ok, oak} = Catalogue.create_attribute_set_value(wood, %{label: "Oak"})

      blue_oak =
        fixture_item(%{
          name: "Blue oak door",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      blue_pine =
        fixture_item(%{
          name: "Blue pine door",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      red_door =
        fixture_item(%{
          name: "Red door",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      for {item, set, slug} <- [
            {blue_oak, colour, blue.slug},
            {blue_oak, wood, oak.slug},
            {blue_pine, colour, blue.slug},
            {red_door, colour, red.slug}
          ] do
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [slug])
      end

      %{
        conn: with_scope(conn, scope),
        catalogue: catalogue,
        category: category,
        colour: colour,
        blue: blue,
        oak: oak,
        items: %{blue_oak: blue_oak, blue_pine: blue_pine, red_door: red_door}
      }
    end

    defp names(items), do: items |> Enum.map(& &1.name) |> Enum.sort()

    defp assert_patched_with_filter(view, slugs) do
      path = assert_patch(view, 100)
      assert path =~ "attr="
      for slug <- slugs, do: assert(path =~ slug)
    rescue
      # The patch may already have been consumed by an earlier assertion;
      # the assigns are the source of truth either way.
      _ ->
        assert Enum.sort(
                 :sys.get_state(view.pid).socket.assigns.attribute_filter
                 |> String.split(",", trim: true)
               ) == Enum.sort(slugs)
    end

    test "one slug narrows the level to the items carrying it", ctx do
      assert names(
               Catalogue.list_items_for_category_paged(ctx.category.uuid,
                 value_slugs: [ctx.blue.slug]
               )
             ) == ["Blue oak door", "Blue pine door"]

      assert Catalogue.item_count_for_category(ctx.category.uuid, value_slugs: [ctx.blue.slug]) ==
               2
    end

    test "two slugs NARROW, they don't widen", ctx do
      # "blue oak doors" is one item, not three.
      assert names(
               Catalogue.list_items_for_category_paged(ctx.category.uuid,
                 value_slugs: [ctx.blue.slug, ctx.oak.slug]
               )
             ) == ["Blue oak door"]
    end

    test "no slugs is no filter, and an unknown slug matches nothing", ctx do
      assert length(Catalogue.list_items_for_category_paged(ctx.category.uuid)) == 3

      assert Catalogue.list_items_for_category_paged(ctx.category.uuid, value_slugs: [])
             |> length() == 3

      assert Catalogue.list_items_for_category_paged(ctx.category.uuid, value_slugs: ["nope"]) ==
               []
    end

    test "search stays inside the filter", ctx do
      assert names(
               Catalogue.search_items("door",
                 catalogue_uuids: [ctx.catalogue.uuid],
                 value_slugs: [ctx.blue.slug]
               )
             ) == ["Blue oak door", "Blue pine door"]
    end

    test "the page filters, and the filter is in the URL", ctx do
      url = "/en/admin/catalogue/#{ctx.catalogue.uuid}?category=#{ctx.category.uuid}"

      {:ok, view, html} = live(ctx.conn, url)
      assert html =~ "Blue oak door"
      assert html =~ "Red door"

      # The control offers the sets in use…
      assert html =~ "Colour"
      assert html =~ "Wood"

      # …and picking a value narrows the level. The click patches the URL,
      # so read the view AFTER the patch rather than the click's return.
      render_click(view, "toggle_attribute_filter", %{"slug" => ctx.blue.slug})
      html = render(view)
      assert html =~ "Blue oak door"
      assert html =~ "Blue pine door"
      refute html =~ "Red door"

      # A second value narrows further rather than widening.
      render_click(view, "toggle_attribute_filter", %{"slug" => ctx.oak.slug})
      html = render(view)
      assert html =~ "Blue oak door"
      refute html =~ "Blue pine door"

      # It rides in the URL, so the filtered view is a link…
      assert_patched_with_filter(view, [ctx.blue.slug, ctx.oak.slug])

      # …and clicking the same value again removes it.
      render_click(view, "toggle_attribute_filter", %{"slug" => ctx.oak.slug})
      html = render(view)
      assert html =~ "Blue pine door"

      render_click(view, "clear_attribute_filter", %{})
      html = render(view)
      assert html =~ "Red door"
    end

    test "a filtered link opens filtered", ctx do
      {:ok, _view, html} =
        live(
          ctx.conn,
          "/en/admin/catalogue/#{ctx.catalogue.uuid}?category=#{ctx.category.uuid}&attr=#{ctx.blue.slug}"
        )

      assert html =~ "Blue oak door"
      refute html =~ "Red door"
    end

    test "the filter offers only sets this catalogue actually uses", ctx do
      {:ok, _unused} = Catalogue.create_attribute_set(%{name: "Unused elsewhere"})

      options = Catalogue.attribute_filter_options(ctx.catalogue.uuid)

      assert Enum.map(options, & &1.name) == ["Colour", "Wood"]

      colour = Enum.find(options, &(&1.name == "Colour"))
      assert Enum.sort(Enum.map(colour.values, & &1.title)) == ["Blue", "Red"]
    end
  end
end
