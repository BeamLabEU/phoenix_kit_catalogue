defmodule PhoenixKitCatalogue.Web.CatalogueDetailTreeReproTest do
  @moduledoc """
  Client, 2026-09-12: "In KAPI KARKASS I added MELAMIIN STANDART and started
  moving it around; suddenly the category doubled." Replays her sequence
  through the real detail page, ten rounds, and asserts after every
  step that the category exists once in the DB and once in the tree.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitCatalogue.Test.Repo

  @base "/en/admin/catalogue"

  defp db_count(name) do
    Repo.aggregate(from(c in Category, where: c.name == ^name), :count)
  end

  # The page renders the tree twice — the table (desktop) and the card
  # level (phone), one shown per breakpoint — so count table rows only.
  defp tree_count(html, uuid), do: length(Regex.scan(~r/<tr[^>]*data-tree-uuid="#{uuid}"/, html))
  defp card_count(html, uuid), do: length(Regex.scan(~r/<div[^>]*data-tree-uuid="#{uuid}"/, html))

  defp settle(view) do
    # Let the page's own PubSub broadcasts (moved/reordered) be handled.
    _ = :sys.get_state(view.pid)
    render(view)
  end

  test "moving a freshly created category in and out of a sibling never doubles it", %{
    conn: conn
  } do
    catalogue = fixture_catalogue(%{name: "ANDI Köögimööbel"})
    karkass = fixture_category(catalogue, %{name: "KAPI KARKASS", position: 0})
    melamiin = fixture_category(catalogue, %{name: "MELAMIIN", parent_uuid: karkass.uuid})
    other = fixture_category(catalogue, %{name: "MELAMIIN LUX", parent_uuid: melamiin.uuid})

    # The New Category form, opened from KAPI KARKASS, creates it there.
    {:ok, standart} =
      Catalogue.create_category(%{
        name: "MELAMIIN STANDART",
        catalogue_uuid: catalogue.uuid,
        parent_uuid: karkass.uuid,
        position: Catalogue.next_category_position(catalogue.uuid, karkass.uuid)
      })

    {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{karkass.uuid}")
    render_click(view, "toggle_category_expand", %{"uuid" => melamiin.uuid})
    html = settle(view)
    assert tree_count(html, standart.uuid) == 1

    for round <- 1..10 do
      # Edge drop under MELAMIIN, before its existing child.
      render_click(view, "drop_row", %{
        "type" => "category",
        "uuid" => standart.uuid,
        "parent" => melamiin.uuid,
        "entries" => ["category:#{standart.uuid}", "category:#{other.uuid}"]
      })

      html = settle(view)
      assert db_count("MELAMIIN STANDART") == 1, "round #{round}: DB doubled after nesting"
      assert tree_count(html, standart.uuid) == 1, "round #{round}: tree doubled after nesting"
      assert Catalogue.get_category(standart.uuid).parent_uuid == melamiin.uuid

      # Swap places with the sibling (edge drop after it).
      render_click(view, "drop_row", %{
        "type" => "category",
        "uuid" => standart.uuid,
        "parent" => melamiin.uuid,
        "entries" => ["category:#{other.uuid}", "category:#{standart.uuid}"]
      })

      html = settle(view)
      assert db_count("MELAMIIN STANDART") == 1, "round #{round}: DB doubled after swap"
      assert tree_count(html, standart.uuid) == 1, "round #{round}: tree doubled after swap"

      # Middle drop straight onto MELAMIIN (already its parent — a no-op move).
      render_click(view, "move_to_folder", %{
        "type" => "category",
        "uuid" => standart.uuid,
        "target" => melamiin.uuid
      })

      html = settle(view)
      assert db_count("MELAMIIN STANDART") == 1, "round #{round}: DB doubled after re-drop"
      assert tree_count(html, standart.uuid) == 1, "round #{round}: tree doubled after re-drop"

      # Back out to the KAPI KARKASS level, before MELAMIIN.
      render_click(view, "drop_row", %{
        "type" => "category",
        "uuid" => standart.uuid,
        "parent" => "root",
        "entries" => ["category:#{standart.uuid}", "category:#{melamiin.uuid}"]
      })

      html = settle(view)
      assert db_count("MELAMIIN STANDART") == 1, "round #{round}: DB doubled after lifting"
      assert tree_count(html, standart.uuid) == 1, "round #{round}: tree doubled after lifting"
      assert card_count(html, standart.uuid) == 1, "round #{round}: cards doubled after lifting"
      assert Catalogue.get_category(standart.uuid).parent_uuid == karkass.uuid
    end

    # The whole tree, once each.
    html = settle(view)
    assert tree_count(html, melamiin.uuid) == 1
    assert tree_count(html, other.uuid) == 1
    assert db_count("MELAMIIN") == 1
  end

  test "a category created or moved in another tab reaches the open tree without a reload", %{
    conn: conn
  } do
    catalogue = fixture_catalogue(%{name: "Two Tabs"})
    parent = fixture_category(catalogue, %{name: "Parent", position: 0})
    {:ok, view, html} = live(conn, "#{@base}/#{catalogue.uuid}")
    assert tree_count(html, parent.uuid) == 1

    # Tab B creates a sibling and nests a child under Parent.
    {:ok, sibling} =
      Catalogue.create_category(%{name: "From tab B", catalogue_uuid: catalogue.uuid})

    {:ok, child} =
      Catalogue.create_category(%{
        name: "Nested from tab B",
        catalogue_uuid: catalogue.uuid,
        parent_uuid: parent.uuid
      })

    send(view.pid, {:catalogue_data_changed, :category, sibling.uuid, catalogue.uuid})
    html = settle(view)
    assert tree_count(html, sibling.uuid) == 1
    # Parent now has a child: it gets a chevron (expandable) at once.
    render_click(view, "toggle_category_expand", %{"uuid" => parent.uuid})
    assert tree_count(settle(view), child.uuid) == 1
  end
end
