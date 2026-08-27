defmodule PhoenixKitCatalogue.Web.AttributeSetDetailLiveTest do
  @moduledoc """
  The per-set detail page (`catalogue/attributes/:uuid`): the rich item
  listing (photo/price/location/selected values), the scale rules
  (server-side search, 25/page), the not-found redirect, and the
  dead-render skeleton.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup %{conn: conn, scope: scope} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      %{conn: with_scope(conn, scope)}
    end

    test "values strip, item rows with SELECTED labels, entities links", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Detail colors"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
      {:ok, _blue} = Catalogue.create_attribute_set_value(set, %{label: "Blue"})

      item = fixture_item(%{name: "Detail door"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])

      {:ok, view, html} = live(conn, "/en/admin/catalogue/attributes/#{set.uuid}")

      assert html =~ "Detail colors"
      assert html =~ "Blue"
      assert html =~ "Detail door"
      # The item's row shows its OWN selection of this set.
      assert has_element?(view, "#attr-set-item-#{item.uuid}", "Red")
      # The name links to the item editor; the header links into entities.
      assert has_element?(view, ~s|a[href$="/items/#{item.uuid}/edit"]|, "Detail door")
      assert html =~ "/admin/entities/#{set.name}/data"
      assert html =~ "/admin/entities/#{set.uuid}/edit"
    end

    test "item search is server-side and trailing-space tolerant", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Search set"})
      hit = fixture_item(%{name: "Walnut door"})
      miss = fixture_item(%{name: "Steel frame"})
      {:ok, _} = Catalogue.attach_attribute_set(hit.uuid, set.uuid)
      {:ok, _} = Catalogue.attach_attribute_set(miss.uuid, set.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes/#{set.uuid}")

      html = render_change(view, "items_search", %{"q" => "Walnut "})
      assert html =~ "Walnut door"
      refute html =~ "Steel frame"

      html = render_change(view, "items_search", %{"q" => "zzz-nothing"})
      assert html =~ "No items match your search."
      refute html =~ "No items attached."
    end

    test "items paginate at 25", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Paged set"})

      for n <- 1..26 do
        item = fixture_item(%{name: "Paged item #{String.pad_leading("#{n}", 2, "0")}"})
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      end

      {:ok, view, html} = live(conn, "/en/admin/catalogue/attributes/#{set.uuid}")
      assert html =~ "Paged item 01"
      refute html =~ "Paged item 26"
      assert html =~ "1 / 2"

      html = render_click(view, "items_page", %{"dir" => "next"})
      assert html =~ "Paged item 26"
      refute html =~ "Paged item 01"
    end

    test "deleted items stay off the page and out of the count", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Trash set"})
      kept = fixture_item(%{name: "Kept item"})
      gone = fixture_item(%{name: "Trashed item"})
      {:ok, _} = Catalogue.attach_attribute_set(kept.uuid, set.uuid)
      {:ok, _} = Catalogue.attach_attribute_set(gone.uuid, set.uuid)
      {:ok, _} = Catalogue.trash_item(gone)

      {:ok, _view, html} = live(conn, "/en/admin/catalogue/attributes/#{set.uuid}")
      assert html =~ "Kept item"
      refute html =~ "Trashed item"
    end

    test "an unknown uuid bounces back to the listing", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/en/admin/catalogue/attributes/#{Ecto.UUID.generate()}")

      assert to =~ "/admin/catalogue/attributes"
    end

    test "the dead render shows a skeleton, never an empty state", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Dead render set"})
      item = fixture_item(%{name: "Dead render item"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

      static = conn |> get("/en/admin/catalogue/attributes/#{set.uuid}") |> html_response(200)
      assert static =~ "Dead render set"
      assert static =~ "skeleton"
      refute static =~ "No items attached."
    end
  end
end
