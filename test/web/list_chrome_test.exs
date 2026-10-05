defmodule PhoenixKitCatalogue.Web.ListChromeTest do
  @moduledoc """
  The top of the list pages (boss via Max, 2026-10-05: too busy) and the
  tables' column fitting.

  Everything that tunes a list sits in one of two pop-ups — Filters beside
  the search (which rows), View options (how they are shown) — so these
  check the controls are still THERE, inside them, and nowhere loose.

  Column fitting hides a column by its position in the header row, so a
  body row with one cell more or fewer than the header would lose the wrong
  cell. Every fitted table is checked for that, in each shape it renders.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Chrome cat"})
    parent = fixture_category(catalogue, %{name: "Doors", position: 0})
    child = fixture_category(catalogue, %{name: "Oak doors", parent_uuid: parent.uuid})
    fixture_category(catalogue, %{name: "Oak panels", parent_uuid: child.uuid})
    fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: parent.uuid, name: "Door A"})
    fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Loose item"})

    %{conn: with_scope(conn, scope), catalogue: catalogue, parent: parent, child: child}
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp inside?(html, container, selector) do
    html |> doc() |> LazyHTML.query("#{container} #{selector}") |> Enum.count() > 0
  end

  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()

  # [{wrapper_id, header_cell_count, [body_row_cell_count]}] for every fitted
  # table in the page. A cell with a colspan is skipped by the hook, so a row
  # holding one is not a row it has to line up.
  defp fitted_tables(html) do
    for wrapper <- html |> doc() |> LazyHTML.query(~s([phx-hook="TableFit"])) do
      [id] = LazyHTML.attribute(wrapper, "id")
      [{_, _, _} = tree] = LazyHTML.to_tree(wrapper)
      table = find(tree, "table")
      head = table |> find("thead") |> find("tr") |> cells()

      {id, length(head), body_row_sizes(table)}
    end
  end

  defp body_row_sizes(table) do
    for {"tbody", _, kids} <- children(table),
        {"tr", _, _} = tr <- kids,
        cs = cells(tr),
        not Enum.any?(cs, &spanning?/1),
        do: length(cs)
  end

  defp spanning?({_, attrs, _}), do: List.keymember?(attrs, "colspan", 0)

  defp children({_, _, kids}), do: Enum.filter(kids, &is_tuple/1)
  defp find(node, tag), do: Enum.find(children(node), &(elem(&1, 0) == tag))
  defp cells(tr), do: Enum.filter(children(tr), &(elem(&1, 0) in ["td", "th"]))

  defp assert_rows_line_up(html, expected_ids) do
    tables = fitted_tables(html)
    ids = Enum.map(tables, &elem(&1, 0))

    for id <- expected_ids, do: assert(id in ids, "no fitted table #{id}; found #{inspect(ids)}")

    for {id, head, rows} <- tables do
      assert rows != [], "#{id} rendered no body rows — the check would pass on nothing"

      assert Enum.all?(rows, &(&1 == head)),
             "#{id}: header has #{head} cells, body rows have #{inspect(Enum.uniq(rows))}"
    end
  end

  describe "the index" do
    test "sort, Columns and the view switch live in View options, not on the row", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)

      assert inside?(html, "#catalogues-view-options", "#catalogues-sort-controls")
      assert inside?(html, "#catalogues-view-options", ~s(button[phx-click*="show_column_modal"]))
      assert inside?(html, "#catalogues-view-options", ~s(button[phx-click="set_view"]))

      # each exactly once: nothing left behind on the row, nothing doubled
      assert count(html, "#catalogues-sort-controls") == 1
      assert count(html, ~s(button[phx-click*="show_column_modal"])) == 1
      assert count(html, ~s(button[phx-click="set_view"])) == 3
    end

    # The pop-up is opened and closed on the client, so a control in it that
    # opens a dialog has to close it too — or it is still there, backdrop
    # and all, when the dialog shuts.
    test "Columns closes the pop-up it sits in", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)

      [click] =
        html
        |> doc()
        |> LazyHTML.query(~s(#catalogues-view-options button[phx-click*="show_column_modal"]))
        |> LazyHTML.attribute("phx-click")

      assert click =~ ~s("hide")
      assert click =~ "#catalogues-view-options"
    end

    test "the status filter lives in Filters, beside the search", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)

      assert inside?(html, "#catalogues-filters", "#filter-form-status")
      assert count(html, "#filter-form-status") == 1
      refute inside?(html, "#catalogues-view-options", "#filter-form-status")
    end

    test "the Filters button counts a filter that is on", %{conn: conn} do
      {:ok, view, html} = live(conn, @base)

      refute html |> doc() |> LazyHTML.query(~s(button[title="Filters"] .badge)) |> Enum.any?()

      html =
        view
        |> form("#filter-form-status", %{"column_id" => "status", "value" => "active"})
        |> render_change()

      assert [badge] =
               html
               |> doc()
               |> LazyHTML.query(~s(button[title="Filters"] .badge))
               |> Enum.to_list()

      assert LazyHTML.text(badge) =~ "1"
    end

    for mode <- ~w(table comfy) do
      test "every row lines up with the header in #{mode} view", %{conn: conn} do
        {:ok, view, _html} = live(conn, @base)
        html = render_click(view, "set_view", %{"mode" => unquote(mode)})

        assert_rows_line_up(html, [])
        assert fitted_tables(html) != []
      end
    end
  end

  describe "inside a catalogue" do
    test "the list controls live in View options, on the row the bulk bar replaces", %{
      conn: conn,
      catalogue: catalogue
    } do
      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}")

      assert inside?(html, "#detail-level-controls", "#detail-view-options")
      assert inside?(html, "#detail-view-options", "#categories-sort-selector")
      assert inside?(html, "#detail-view-options", ~s(button[phx-click*="show_column_modal"]))
      assert count(html, "#categories-sort-selector") == 1
    end

    test "the search refinements live in Filters", %{
      conn: conn,
      catalogue: catalogue,
      parent: parent
    } do
      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{parent.uuid}")

      assert inside?(html, "#catalogue-level-filters", ~s(input[phx-click="toggle_items_scope"]))
      assert count(html, ~s(input[phx-click="toggle_items_scope"])) == 1
    end

    test "an opened subcategory is set in: rail in the photo column, elbow and picture in the name cell",
         %{conn: conn, catalogue: catalogue, parent: parent, child: child} do
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
      html = render_click(view, "toggle_category_expand", %{"uuid" => parent.uuid})

      top = html |> doc() |> LazyHTML.query("#category-tree-row-#{parent.uuid}")
      sub = html |> doc() |> LazyHTML.query("#category-tree-row-#{child.uuid}")

      assert Enum.count(sub) == 1
      assert sub |> LazyHTML.query(".hero-arrow-turn-down-right") |> Enum.count() == 1
      assert top |> LazyHTML.query(".hero-arrow-turn-down-right") |> Enum.count() == 0
    end

    # The Image column takes the photo column's place, and with it the cell
    # that draws the first level's rail — the name cell then has to draw every
    # level itself, or a first-level subcategory is not set in at all.
    test "a subcategory is still set in when the Image column replaces the photo column", %{
      conn: conn,
      catalogue: catalogue,
      parent: parent,
      child: child
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")

      render_click(view, "add_column", %{"column_id" => "image", "section" => "detail_categories"})

      html = render_click(view, "toggle_category_expand", %{"uuid" => parent.uuid})

      # the photo column is gone: no rail cell before the name
      refute html =~ "left-1/2 border-l-2"

      sub = html |> doc() |> LazyHTML.query("#category-tree-row-#{child.uuid}")
      name_cell = sub |> LazyHTML.query("td.relative") |> LazyHTML.to_html()

      assert name_cell =~ "border-l-2"
      assert name_cell =~ "padding-left"
      assert_rows_line_up(html, ["catalogue-categories-tree-table-fit"])
    end

    test "every row lines up with the header: tree with an opened branch, and the items table", %{
      conn: conn,
      catalogue: catalogue,
      parent: parent,
      child: child
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
      render_click(view, "toggle_category_expand", %{"uuid" => parent.uuid})
      html = render_click(view, "toggle_category_expand", %{"uuid" => child.uuid})

      assert_rows_line_up(html, ["catalogue-categories-tree-table-fit"])

      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{parent.uuid}")
      assert_rows_line_up(html, ["level-items-active-fit"])
    end
  end
end
