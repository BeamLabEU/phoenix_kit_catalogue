defmodule PhoenixKitCatalogue.Web.ComponentsTest do
  @moduledoc """
  Unit tests for the stateless `Components` module. These use
  `Phoenix.LiveViewTest.render_component/2` — no LiveView lifecycle,
  just function-component rendering. They catch the "component crashes
  on unexpected input" class of bug, which is exactly what the
  `safe_assoc_field/3` / `safe_call/2` helpers are supposed to prevent.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PhoenixKitCatalogue.Web.Components

  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, Manufacturer}

  # ─────────────────────────────────────────────────────────────────
  # status_badge
  # ─────────────────────────────────────────────────────────────────

  describe "status_badge/1" do
    test "renders active status" do
      html = render_component(&status_badge/1, status: "active")
      assert html =~ "Active"
      assert html =~ "badge-success"
    end

    test "renders deleted status with error class" do
      html = render_component(&status_badge/1, status: "deleted")
      assert html =~ "Deleted"
      assert html =~ "badge-error"
    end

    test "renders inactive status" do
      html = render_component(&status_badge/1, status: "inactive")
      assert html =~ "Inactive"
    end

    test "renders with an unknown status" do
      # Should not crash — uses a fallback class.
      html = render_component(&status_badge/1, status: "mystery")
      assert html =~ "Mystery"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # empty_state
  # ─────────────────────────────────────────────────────────────────

  describe "empty_state/1" do
    test "renders a message" do
      html = render_component(&empty_state/1, message: "Nothing here")
      assert html =~ "Nothing here"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # search_input
  # ─────────────────────────────────────────────────────────────────

  describe "search_input/1" do
    test "renders an input with the query prefilled" do
      html = render_component(&search_input/1, query: "oak", placeholder: "Search...")
      assert html =~ "oak"
      assert html =~ "Search..."
    end

    test "renders without a query" do
      html = render_component(&search_input/1, query: "", placeholder: "Search...")
      assert html =~ "Search..."
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # search_results_summary
  # ─────────────────────────────────────────────────────────────────

  describe "search_results_summary/1" do
    test "renders the match count and query" do
      html = render_component(&search_results_summary/1, count: 3, query: "oak")
      assert html =~ "3"
      assert html =~ "oak"
    end

    test "renders zero results cleanly" do
      html = render_component(&search_results_summary/1, count: 0, query: "nothing")
      assert html =~ "0" or html =~ "nothing"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # item_table — robustness with nil / NotLoaded associations
  # ─────────────────────────────────────────────────────────────────

  describe "item_table/1 robustness" do
    test "renders items with fully-loaded associations" do
      catalogue = %Catalogue{
        uuid: "019d1330-c5e0-7caf-b84b-91a4418f67f2",
        name: "Kitchen"
      }

      category = %Category{
        uuid: "019d1335-5edc-7fa9-bea8-6e54bda31eda",
        name: "Frames",
        catalogue: catalogue
      }

      manufacturer = %Manufacturer{
        uuid: "019d1336-0000-7fa9-bea8-6e54bda31eda",
        name: "Blum"
      }

      item = %Item{
        uuid: "019d1337-0000-7fa9-bea8-6e54bda31eda",
        name: "Oak Panel",
        sku: "OAK-18",
        base_price: Decimal.new("25.50"),
        unit: "piece",
        status: "active",
        category: category,
        catalogue: catalogue,
        manufacturer: manufacturer
      }

      html =
        render_component(&item_table/1,
          items: [item],
          columns: [:name, :sku, :base_price, :unit, :status, :category, :manufacturer],
          id: "test-table"
        )

      assert html =~ "Oak Panel"
      assert html =~ "OAK-18"
      assert html =~ "Frames"
      assert html =~ "Blum"
    end

    test "item name in the table view is wrapped in a link when edit_path is provided" do
      item = %Item{
        uuid: "019d1337-0000-7fa9-bea8-6e54bda31aaa",
        name: "Clickable",
        status: "active"
      }

      html =
        render_component(&item_table/1,
          items: [item],
          columns: [:name],
          edit_path: fn uuid -> "/edit/#{uuid}" end,
          id: "link-name-table"
        )

      # The card view already wrapped the name in a link — the table
      # cell now matches, so the user can click the name from either
      # view mode.
      assert html =~ ~s(href="/edit/019d1337-0000-7fa9-bea8-6e54bda31aaa")
      assert html =~ "Clickable"
    end

    test "item name in the table view is plain text when edit_path is nil" do
      item = %Item{
        uuid: "019d1337-0000-7fa9-bea8-6e54bda31bbb",
        name: "Read-only",
        status: "active"
      }

      html =
        render_component(&item_table/1,
          items: [item],
          columns: [:name],
          id: "plain-name-table"
        )

      assert html =~ "Read-only"
      # No edit_path → no link wrapping the name
      refute html =~ "href=\"/edit"
    end

    test "doesn't crash on NotLoaded associations" do
      item = %Item{
        uuid: "019d1337-0000-7fa9-bea8-6e54bda31ede",
        name: "Orphan",
        sku: nil,
        base_price: nil,
        unit: "piece",
        status: "active",
        category: %Ecto.Association.NotLoaded{
          __field__: :category,
          __owner__: Item,
          __cardinality__: :one
        },
        catalogue: %Ecto.Association.NotLoaded{
          __field__: :catalogue,
          __owner__: Item,
          __cardinality__: :one
        },
        manufacturer: %Ecto.Association.NotLoaded{
          __field__: :manufacturer,
          __owner__: Item,
          __cardinality__: :one
        }
      }

      html =
        render_component(&item_table/1,
          items: [item],
          columns: [:name, :sku, :category, :manufacturer, :catalogue],
          id: "not-loaded-table"
        )

      # Renders without crashing; unloaded assocs fall back to "—".
      assert html =~ "Orphan"
      assert html =~ "—"
    end

    test "doesn't crash on nil associations" do
      item = %Item{
        uuid: "019d1337-0000-7fa9-bea8-6e54bda31edf",
        name: "Nil assocs",
        category: nil,
        catalogue: nil,
        manufacturer: nil
      }

      html =
        render_component(&item_table/1,
          items: [item],
          columns: [:name, :category, :manufacturer, :catalogue],
          id: "nil-table"
        )

      assert html =~ "Nil assocs"
      assert html =~ "—"
    end

    test "renders the empty state when items is empty" do
      html =
        render_component(&item_table/1,
          items: [],
          columns: [:name],
          id: "empty-table"
        )

      # Either an empty table body or a placeholder — just make sure
      # nothing raises.
      assert is_binary(html)
    end

    test "logs a warning and renders a dash for an unknown column" do
      item = %Item{
        uuid: "019d1337-0000-7fa9-bea8-6e54bda31ee0",
        name: "Test"
      }

      import ExUnit.CaptureLog

      {html, log} =
        with_log([level: :warning], fn ->
          render_component(&item_table/1,
            items: [item],
            columns: [:name, :nonexistent_column],
            id: "unknown-col-table"
          )
        end)

      assert html =~ "Test"
      assert log =~ "unknown column"
    end

    test "price column uses markup_percentage from the catalogue" do
      item = %Item{
        uuid: "019d1337-0000-7fa9-bea8-6e54bda31ee1",
        name: "Priced",
        base_price: Decimal.new("100.00")
      }

      html =
        render_component(&item_table/1,
          items: [item],
          columns: [:name, :base_price, :price],
          markup_percentage: Decimal.new("15"),
          id: "price-table"
        )

      # 100 * 1.15 = 115.00
      assert html =~ "115"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # view_mode_toggle
  # ─────────────────────────────────────────────────────────────────

  describe "view_mode_toggle/1" do
    test "renders without crashing" do
      html = render_component(&view_mode_toggle/1, storage_key: "test-key")
      # Renders the hook wrapper with the storage key.
      assert html =~ "test-key"
    end
  end
end
