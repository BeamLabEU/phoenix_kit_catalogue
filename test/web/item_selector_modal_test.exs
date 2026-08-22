defmodule PhoenixKitCatalogue.Web.Components.ItemSelectorModalTest do
  @moduledoc """
  Drives `ItemSelectorModal` through `Test.SelectorHostLive`, asserting the
  PROCESS-MESSAGE contract a production host consumes (rendered back as
  DOM by the host) — not component internals. Security clamps get the
  adversarial cases: crafted uuids, out-of-scope categories, absurd
  quantities.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  defp seed(_ctx) do
    cat = fixture_catalogue(%{name: "Picker Catalogue"})
    other = fixture_catalogue(%{name: "Forbidden Catalogue"})

    {:ok, screw} =
      Catalogue.create_item(%{
        name: "M8 Screw",
        sku: "M8-100",
        base_price: Decimal.new("2.50"),
        catalogue_uuid: cat.uuid
      })

    {:ok, paint} =
      Catalogue.create_item(%{
        name: "White Paint",
        sku: "PAINT-W",
        catalogue_uuid: cat.uuid
      })

    {:ok, forbidden} =
      Catalogue.create_item(%{
        name: "Forbidden Item",
        sku: "NOPE-1",
        catalogue_uuid: other.uuid
      })

    %{cat: cat, other: other, screw: screw, paint: paint, forbidden: forbidden}
  end

  setup :seed

  defp open(conn, query), do: live(conn, "/test/selector-host?#{query}")

  defp picker(view), do: with_target(view, "#picker")

  describe "scoped browsing" do
    test "renders only the scoped catalogue's items", %{conn: conn, cat: cat} do
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}")

      assert html =~ "M8 Screw"
      assert html =~ "White Paint"
      refute html =~ "Forbidden Item"
    end

    test "search narrows within the scope", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      html = view |> picker() |> render_change("browse_search", %{"search" => "screw"})

      assert html =~ "M8 Screw"
      refute html =~ "White Paint"
    end

    test "a crafted category event cannot leak the other catalogue", %{
      conn: conn,
      cat: cat,
      other: other
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      # Every fetch re-ANDs scope.catalogue_uuids, so even a category value
      # from another catalogue can never surface its items.
      html =
        view
        |> picker()
        |> render_click("browse_category", %{"uuid" => other.uuid})

      refute html =~ "Forbidden Item"
    end

    test "a category outside scope.category_uuids is rejected as a no-op", %{
      conn: conn,
      cat: cat
    } do
      # The case category_allowed?/2 actually guards: the host restricted
      # browsing to ONE category, and a crafted event names a sibling.
      allowed = fixture_category(cat, %{name: "Allowed"})
      hidden = fixture_category(cat, %{name: "Hidden"})

      {:ok, in_cat} =
        Catalogue.create_item(%{
          name: "Allowed Widget",
          catalogue_uuid: cat.uuid,
          category_uuid: allowed.uuid
        })

      {:ok, _out} =
        Catalogue.create_item(%{
          name: "Hidden Widget",
          catalogue_uuid: cat.uuid,
          category_uuid: hidden.uuid
        })

      {:ok, view, html} =
        live(conn, "/test/selector-host?c=#{cat.uuid}&cat_scope=#{allowed.uuid}")

      assert html =~ "Allowed Widget"
      refute html =~ "Hidden Widget"

      # The crafted chip event names the sibling category. BrowseState must
      # refuse it outright — the grid stays exactly as scoped.
      html =
        view
        |> picker()
        |> render_click("browse_category", %{"uuid" => hidden.uuid})

      assert html =~ "Allowed Widget"
      refute html =~ "Hidden Widget"
      _ = in_cat
    end
  end

  describe "selection and confirm — the host contract" do
    test "select, confirm: the host receives Decimal qty and the snapshot", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ ~s(id="picked")
      assert html =~ "M8 Screw|M8-100|qty=1|decimal=true|line=2.50"
      # Confirm also closes.
      assert html =~ ~s(id="closed")
    end

    test "a crafted card_click with an unrendered uuid is refused", %{
      conn: conn,
      cat: cat,
      forbidden: forbidden
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      view |> picker() |> render_click("card_click", %{"uuid" => forbidden.uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      # Nothing was selectable, so the payload is empty — the forbidden
      # item never enters the selection, let alone the picks.
      assert html =~ ~s(<span id="picked-count">0</span>)
    end

    test "clicking a selected card deselects it", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ ~s(<span id="picked-count">0</span>)
    end

    test "cancel sends the closed message and nothing else", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      view |> picker() |> render_click("cancel", %{})
      html = render(view)

      assert html =~ ~s(id="closed")
      refute html =~ ~s(id="picked")
    end
  end

  describe "quantities" do
    test "inc steps up; dec at the minimum deselects", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")
      uuid = to_string(screw.uuid)

      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      view |> picker() |> render_click("qty_inc", %{"uuid" => uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ "qty=2"

      # Fresh mount: select, then minus at qty 1 removes the pick.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")
      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      view |> picker() |> render_click("qty_dec", %{"uuid" => uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ ~s(<span id="picked-count">0</span>)
    end

    test "commit parses a decimal comma when precision allows", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&precision=2")
      uuid = to_string(screw.uuid)

      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "2,5"})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ "qty=2.5"
      assert html =~ "line=6.25"
    end

    test "integer precision rounds a decimal commit", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")
      uuid = to_string(screw.uuid)

      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "2.5"})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      # precision 0: 2.5 rounds, it does not become a fractional pick.
      assert html =~ ~r/qty=[23]\|/
      refute html =~ "qty=2.5"
    end

    test "garbage and hostile quantities cannot corrupt the selection", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&max=99")
      uuid = to_string(screw.uuid)

      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()

      # Garbage keeps the committed value.
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "abc"})
      # Negative is rejected outright.
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "-5"})
      # Absurd is clamped to qty_max, not stored.
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "1000000000"})

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ "qty=99"
    end
  end

  describe "preselection" do
    test "hydrates in-scope preselects with their quantities", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&pre=#{screw.uuid}:3")

      # Already selected: the card shows its selected state on first render.
      assert html =~ ~s(data-selected="true")

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ "qty=3"
    end

    test "an out-of-scope preselect is shown but never confirmed", %{
      conn: conn,
      cat: cat,
      forbidden: forbidden
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&pre=#{forbidden.uuid}:2")

      # The tray starts collapsed; expand it to see the rows. Visible and
      # flagged — the host's data is not silently dropped…
      html = view |> picker() |> render_click("toggle_tray", %{})
      assert html =~ "Forbidden Item"
      assert html =~ "Not available in this selection"

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&pre=#{forbidden.uuid}:2")
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      # …but it must not come back as a pick: the host's own scope said no.
      assert html =~ ~s(<span id="picked-count">0</span>)
    end
  end

  describe "hardening from the 2026-08-22 implementation review" do
    test "an :only-excluded preselect is unavailable, not confirmable", %{conn: conn, cat: cat} do
      # The item HAS a category, the scope says :uncategorized_only — the
      # browse could never return it, so hydration must not bless it.
      category = fixture_category(cat, %{name: "Cat"})

      {:ok, categorized} =
        Catalogue.create_item(%{
          name: "Categorized",
          catalogue_uuid: cat.uuid,
          category_uuid: category.uuid
        })

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&only=uncategorized&pre=#{categorized.uuid}:2"
        )

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ ~s(<span id="picked-count">0</span>)
    end

    test "exponent quantities are rejected, not parsed to 1e9", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")
      uuid = to_string(screw.uuid)

      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "1e9"})
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "1e1000000"})

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ "qty=1|"
    end

    test "a crafted payload with missing keys is a no-op, not a crash", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      view |> picker() |> render_click("card_click", %{})
      view |> picker() |> render_click("qty_commit", %{"value" => "5"})
      html = view |> picker() |> render_click("nonsense_event", %{})

      # Still alive, still rendering.
      assert html =~ "M8 Screw"
    end
  end

  describe "single mode" do
    test "a second pick replaces the first", %{conn: conn, cat: cat, screw: screw, paint: paint} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&mode=single")

      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      view |> element("#picker-card-#{paint.uuid} > button") |> render_click()
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ ~s(<span id="picked-count">1</span>)
      assert html =~ "White Paint"
      refute html =~ "pick-#{screw.uuid}"
    end

    test "immediate mode confirms on the tap itself", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&mode=single&immediate=true")

      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      html = render(view)

      assert html =~ ~s(id="picked")
      assert html =~ "M8 Screw"
      assert html =~ ~s(id="closed")
    end
  end

  describe "multiple pickers on one page" do
    test "every element id stays unique", %{conn: conn, cat: cat} do
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&two=true")

      # \s anchor: phx-value-uuid="…" contains the substring id="…", which
      # a naive scan counts as an element id.
      ids = Regex.scan(~r/\sid="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()
      dupes = ids |> Enum.frequencies() |> Enum.filter(fn {_id, n} -> n > 1 end)

      assert dupes == [], "duplicate DOM ids: #{inspect(dupes)}"
    end
  end
end
