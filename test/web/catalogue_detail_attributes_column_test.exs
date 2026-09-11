defmodule PhoenixKitCatalogue.Web.CatalogueDetailAttributesColumnTest do
  @moduledoc """
  The detail page's "Attributes" list column reads `has_attributes` off
  `attribute_map`, which `merge_row_indicators/3` used to fill from the
  legacy `Catalogue.item_attribute_group_map/1` (the `phoenix_kit_cat_
  item_attribute_groups` table). Real attribute bindings live in the
  entities-backed attribute SETS (`phoenix_kit_cat_item_attribute_sets`),
  so an item attaching only a set rendered as "—" everywhere. These
  tests pin the column (and the card view) reading the batched set
  resolve instead, showing the selected values' labels.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets

  @base "/en/admin/catalogue"

  defp cat_url(cat_uuid, category_uuid), do: "#{@base}/#{cat_uuid}?category=#{category_uuid}"

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
      :ok
    end

    test "the Attributes column shows the selected value's label, not a dash", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Hermes doors"})
      category = fixture_category(catalogue)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Door color"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Punane"})

      with_set =
        fixture_item(%{
          name: "With set",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      _without_set =
        fixture_item(%{
          name: "Without set",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      {:ok, _} = Catalogue.attach_attribute_set(with_set.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(with_set.uuid, set.uuid, [red.slug])

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      html =
        view
        |> render_click("add_column", %{"column_id" => "attributes", "scope" => "detail_items"})

      # The attached item's row carries the selected value's label —
      # never just the swatch icon with nothing readable next to it.
      with_set_row = row_segment(html, "With set")
      assert with_set_row =~ "Punane"

      # The unattached item's row carries no attribute label — "—" alone
      # isn't distinctive (other empty cells in the row render it too).
      without_set_row = row_segment(html, "Without set")
      refute without_set_row =~ "Punane"
      refute without_set_row =~ "Door color"

      # The name-adjacent swatch indicator (presence only) is untouched.
      assert has_element?(view, ~s|[title="Has attribute group"]|)
    end

    test "an item with an attached set but no selection shows the set's name", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Hermes trims"})
      category = fixture_category(catalogue)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Trim finish"})
      {:ok, _gold} = Catalogue.create_attribute_set_value(set, %{label: "Gold"})

      item =
        fixture_item(%{
          name: "Whole set item",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      html =
        view
        |> render_click("add_column", %{"column_id" => "attributes", "scope" => "detail_items"})

      row = row_segment(html, "Whole set item")
      assert row =~ set.display_name
    end

    test "a PubSub attribute_set broadcast refreshes the column", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Hermes handles"})
      category = fixture_category(catalogue)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Handle finish"})
      {:ok, brass} = Catalogue.create_attribute_set_value(set, %{label: "Brass"})

      item =
        fixture_item(%{
          name: "Handle item",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      render_click(view, "add_column", %{"column_id" => "attributes", "scope" => "detail_items"})

      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [brass.slug])

      html = render(view)
      assert row_segment(html, "Handle item") =~ "Brass"
    end
  else
    @tag :skip
    test "entities package lacks the Managed contract — suite skipped" do
      assert true
    end
  end

  # Cuts the enclosing `<tr>…</tr>` around one item's name so assertions
  # stay scoped to that table row instead of matching anywhere on the
  # page (the card view renders the same item as `<div>`s with no `<tr>`,
  # so this only ever matches the table row markup).
  defp row_segment(html, needle) do
    case :binary.match(html, needle) do
      {idx, _len} ->
        row_start = last_tag_start(html, idx)
        row_end = row_end(html, idx)
        binary_part(html, row_start, row_end - row_start)

      :nomatch ->
        flunk("expected #{inspect(needle)} in rendered HTML")
    end
  end

  defp last_tag_start(html, idx) do
    case html |> :binary.matches("<tr") |> Enum.filter(fn {s, _} -> s <= idx end) do
      [] -> 0
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp row_end(html, idx) do
    case :binary.match(html, "</tr>", scope: {idx, byte_size(html) - idx}) do
      {end_idx, end_len} -> end_idx + end_len
      :nomatch -> byte_size(html)
    end
  end
end
