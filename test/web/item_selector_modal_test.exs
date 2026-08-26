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

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
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

      # The forbidden item never enters the selection, so nothing is
      # confirmable and the confirm itself is refused — no message at all.
      refute html =~ ~s(id="picked")
    end

    test "clicking a selected card deselects it", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      # Deselected back to empty: confirm is refused rather than sending
      # `picks: []`.
      refute html =~ ~s(id="picked")
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

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_inc", %{"uuid" => uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ "qty=2"

      # Fresh mount: select, then minus at qty 1 removes the pick.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_dec", %{"uuid" => uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      # The minus removed the only pick, so confirm is refused outright.
      refute html =~ ~s(id="picked")
    end

    test "commit parses a decimal comma when precision allows", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&precision=2")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "2,5"})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ "qty=2.5"
      assert html =~ "line=6.25"
    end

    test "integer precision rounds a decimal commit", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
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

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})

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

      # …and with nothing available the confirm itself is refused — no
      # message at all, not a `picks: []` a replace-semantics host would
      # read as "erase everything".
      refute html =~ ~s(id="picked")
      refute html =~ ~s(id="closed")
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
      # Nothing available -> the confirm is refused, no message at all.
      refute html =~ ~s(id="picked")
    end

    test "a :categorized_only-excluded uncategorized preselect is not confirmable", %{
      conn: conn,
      cat: cat
    } do
      {:ok, loose} =
        Catalogue.create_item(%{
          name: "Loose Widget",
          catalogue_uuid: cat.uuid
        })

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&only=categorized&pre=#{loose.uuid}:2"
        )

      # Hydration of a nil category_uuid against a restriction list must
      # not crash (to_string(nil) is not implemented). Tray starts collapsed.
      html = view |> picker() |> render_click("toggle_tray", %{})
      assert html =~ "Loose Widget"
      assert html =~ "Not available in this selection"

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&only=categorized&pre=#{loose.uuid}:2"
        )

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      # Nothing available -> the confirm is refused, no message at all.
      refute html =~ ~s(id="picked")
    end

    test "an uncategorized preselect under a category_uuids scope does not crash", %{
      conn: conn,
      cat: cat
    } do
      allowed = fixture_category(cat, %{name: "Allowed"})

      {:ok, loose} =
        Catalogue.create_item(%{
          name: "Uncategorized Preselect",
          catalogue_uuid: cat.uuid
        })

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&cat_scope=#{allowed.uuid}&pre=#{loose.uuid}:1"
        )

      html = view |> picker() |> render_click("toggle_tray", %{})
      assert html =~ "Uncategorized Preselect"
      assert html =~ "Not available in this selection"

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&cat_scope=#{allowed.uuid}&pre=#{loose.uuid}:1"
        )

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      # Nothing available -> the confirm is refused, no message at all.
      refute html =~ ~s(id="picked")
    end

    test "a descendant-category preselect is confirmable (search expands the tree)", %{
      conn: conn,
      cat: cat
    } do
      parent = fixture_category(cat, %{name: "Kitchen"})
      child = fixture_category(cat, %{name: "Frames", parent_uuid: parent.uuid})

      {:ok, nested} =
        Catalogue.create_item(%{
          name: "Nested Frame",
          catalogue_uuid: cat.uuid,
          category_uuid: child.uuid
        })

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&cat_scope=#{parent.uuid}&pre=#{nested.uuid}:2"
        )

      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ "Nested Frame"
      assert html =~ "qty=2"
    end

    test "statuses scope hides inactive items from the grid", %{conn: conn, cat: cat} do
      {:ok, _inactive} =
        Catalogue.create_item(%{
          name: "Sleepy Widget",
          sku: "SLP-1",
          catalogue_uuid: cat.uuid,
          status: "inactive"
        })

      {:ok, _view, html} = live(conn, "/test/selector-host?c=#{cat.uuid}&statuses=active")

      refute html =~ "Sleepy Widget"
      assert html =~ "M8 Screw"
    end

    test "selling price (markup applied) is what the card and snapshot show", %{
      conn: conn
    } do
      cat =
        fixture_catalogue(%{
          name: "Marked Up",
          markup_percentage: Decimal.new("10"),
          discount_percentage: Decimal.new("0")
        })

      {:ok, item} =
        Catalogue.create_item(%{
          name: "Priced Widget",
          sku: "PW-1",
          base_price: Decimal.new("100.00"),
          catalogue_uuid: cat.uuid
        })

      {:ok, view, html} = open(conn, "c=#{cat.uuid}")

      assert html =~ "110.00"
      refute html =~ ">100.00<"

      view |> picker() |> render_click("card_click", %{"uuid" => item.uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ "line=110.00"
    end

    test "invalid qty commit bumps the stepper revision so morphdom recreates the input",
         %{
           conn: conn,
           cat: cat,
           screw: screw
         } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      html = render(view)
      assert html =~ ~s(id="picker-qty-#{uuid}-r0")

      html =
        view
        |> picker()
        |> render_click("qty_commit", %{"uuid" => uuid, "value" => "abc"})

      assert html =~ ~s(id="picker-qty-#{uuid}-r1")
      refute html =~ ~s(id="picker-qty-#{uuid}-r0")
    end

    test "exponent quantities are rejected, not parsed to 1e9", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
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

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("card_click", %{"uuid" => paint.uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ ~s(<span id="picked-count">1</span>)
      assert html =~ "White Paint"
      refute html =~ "pick-#{screw.uuid}"
    end

    test "immediate mode confirms on the tap itself", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&mode=single&immediate=true")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
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

  describe "hardening from the 2026-08-25 quorum review" do
    test "the search form routes submit — Enter must not become a native page load", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}")

      # The attribute is the fix: a phx-change form WITHOUT phx-submit is
      # an "external form" to LiveView's client — Enter would run a native
      # submit and destroy the modal with every pick in it.
      assert has_element?(view, ~s(#picker-search-form[phx-submit="browse_search"]))
      assert html =~ ~s(phx-submit="browse_search")

      # And the routed submit is just a re-search.
      html =
        view
        |> element("#picker-search-form")
        |> render_submit(%{"search" => "M8"})

      assert html =~ "M8 Screw"
      refute html =~ "White Paint"
    end

    test "an :uncategorized_only scope offers no category chips", %{conn: conn, cat: cat} do
      _category = fixture_category(cat, %{name: "Visible Cat"})

      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&only=uncategorized")

      # Every chip would be an invalid action (search_items/2 raises on
      # the combination), so the whole row is suppressed.
      refute html =~ ~s(id="picker-chips")
    end

    test "a crafted browse_category with a non-UUID string is a no-op, not a crash", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      html = view |> picker() |> render_click("browse_category", %{"uuid" => "garbage"})

      # Without the reducer guard this raised Ecto.Query.CastError inside
      # the subtree expansion and took the host LiveView down.
      assert Process.alive?(view.pid)
      assert html =~ "M8 Screw"
    end

    test "hydrated preselect quantities are clamped like typed ones", %{
      conn: conn,
      cat: cat,
      screw: screw,
      paint: paint
    } do
      # Above the absolute ceiling → capped; below the minimum → floored.
      {:ok, view, _html} =
        open(conn, "c=#{cat.uuid}&pre=#{screw.uuid}:5000000,#{paint.uuid}:0")

      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ "qty=1000000"
      assert html =~ "qty=1"
    end

    test "single mode keeps at most one preselected entry", %{
      conn: conn,
      cat: cat,
      screw: screw,
      paint: paint
    } do
      {:ok, view, _html} =
        open(conn, "c=#{cat.uuid}&pre=#{paint.uuid}:1,#{screw.uuid}:1&mode=single")

      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ ~s(<span id="picked-count">1</span>)
    end

    test "a crafted confirm with nothing selected is refused outright", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      refute html =~ ~s(id="picked")
      refute html =~ ~s(id="closed")
    end

    test "a preselect under a soft-deleted catalogue is unavailable", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # The search joins exclude items under deleted parents; hydration
      # must judge the same way or the tray blesses a row the browse could
      # never return.
      {:ok, _} = Catalogue.update_catalogue(cat, %{status: "deleted"})

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&pre=#{screw.uuid}:2")

      html = view |> picker() |> render_click("toggle_tray", %{})
      assert html =~ "Not available in this selection"

      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")
    end

    test "with qty_min: 0 a typed \"0\" commits instead of reverting", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&min=0")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_commit", %{"uuid" => screw.uuid, "value" => "0"})
      view |> picker() |> render_click("confirm", %{})

      assert render(view) =~ "qty=0"
    end

    test "a qty_commit for an unselected uuid changes nothing and cannot crash", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      view
      |> picker()
      |> render_click("qty_commit", %{"uuid" => Ecto.UUID.generate(), "value" => "5"})

      assert Process.alive?(view.pid)
      refute render(view) =~ ~s(id="picked")
    end

    test "a fresh search resets the selectable set — stale uuids are refused", %{
      conn: conn,
      cat: cat,
      screw: screw,
      paint: paint
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      # Narrow to paint only, then card_click the screw (rendered by the
      # PREVIOUS query, absent from this one): refused, so a later
      # confirm has nothing.
      view |> picker() |> render_change("browse_search", %{"search" => "Paint"})
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")

      # Positive control: the currently-rendered card still selects.
      view |> picker() |> render_click("card_click", %{"uuid" => paint.uuid})
      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ ~s(<span id="picked-count">1</span>)
    end

    test "table is the default view and cards are one toggle away", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}")

      # Default: the admin-look list — rows, headers, no photo cards.
      assert html =~ ~s(id="picker-table")
      assert html =~ ~s(id="picker-row-#{screw.uuid}")
      refute html =~ ~s(id="picker-card-#{screw.uuid}")
      assert html =~ "SKU"
      assert html =~ "Price"

      # The toggle flips to the photo grid and back.
      html = view |> picker() |> render_click("set_view", %{"mode" => "card"})
      assert html =~ ~s(id="picker-card-#{screw.uuid}")
      refute html =~ ~s(id="picker-table")

      html = view |> picker() |> render_click("set_view", %{"mode" => "table"})
      assert html =~ ~s(id="picker-table")
    end

    test "view=card starts on the photo grid and its DOM click still selects", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&view=card")

      assert html =~ ~s(id="picker-card-#{screw.uuid}")
      refute html =~ ~s(id="picker-table")

      # The card face's real binding, not the targeted shortcut.
      view |> element("#picker-card-#{screw.uuid} > button") |> render_click()
      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ ~s(<span id="picked-count">1</span>)
    end

    test "a table row's DOM click selects — and the qty cell does not toggle", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      # Row cells carry the same card_click binding the card face uses.
      view
      |> element(~s(#picker-row-#{screw.uuid} td[phx-click="card_click"]:first-of-type))
      |> render_click()

      assert has_element?(view, ~s(#picker-row-#{screw.uuid}[data-selected="true"]))
      # The stepper appeared in the qty cell…
      assert has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")
      # …and that cell is not click-bound, so stepping can't deselect.
      refute has_element?(view, ~s(#picker-row-#{screw.uuid} td:last-of-type[phx-click]))

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ "M8 Screw|M8-100|qty=1|decimal=true|line=2.50"
    end

    test "columns are a host contract — nothing renders uninvited", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # Client-safe embed: thumb + name + qty. No SKU, no price anywhere
      # in the list (2.50 is the screw's price).
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&cols=thumb,name,qty")

      assert html =~ ~s(id="picker-row-#{screw.uuid}")
      refute html =~ "SKU"
      refute html =~ "Price"
      refute html =~ "2.50"
      refute html =~ "M8-100"
    end

    test "omitting the :qty column keeps quantities in the tray only", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=name,price")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})

      # Selected, but no inline stepper — the row has no qty cell.
      assert render(view) =~ ~s(data-selected="true")
      refute has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")
    end

    test "unknown column entries raise instead of silently dropping", %{conn: conn, cat: cat} do
      exit_value = catch_exit(open(conn, "c=#{cat.uuid}&cols=name,bogus"))
      assert inspect(exit_value) =~ "unknown entries"
    end

    test "show_prices/show_sku shape the DEFAULT columns", %{conn: conn, cat: cat} do
      # The host host-level opt-outs carry into the derived column set.
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&hide_prices=true")

      refute html =~ "Price"
      assert html =~ "SKU"
    end

    test "the list adapts: staged columns and a widened modal, no sideways scroll", %{
      conn: conn,
      cat: cat
    } do
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}")

      # Low-priority columns carry their responsive stage on th AND td…
      # (unit rides inside the price cell and SKU starts hidden, so only
      # the lg stage appears in the default visible set).
      assert html =~ "hidden lg:table-cell"
      # …and the modal box grows past core Modal's 4xl cap on big screens.
      assert html =~ "xl:max-w-6xl"
      assert html =~ "2xl:max-w-7xl"
    end

    test "price is the SELLING price with inline unit; base_price is opt-in raw", %{
      conn: conn
    } do
      # 10% catalogue markup: base 10.00 sells at 11.00. The client-facing
      # default must show the selling price (with the unit folded in) and
      # never the raw number.
      marked = fixture_catalogue(%{name: "Marked Cat", markup_percentage: Decimal.new("10")})

      {:ok, _item} =
        Catalogue.create_item(%{
          name: "Marked Widget",
          catalogue_uuid: marked.uuid,
          base_price: Decimal.new("10.00"),
          unit: "set"
        })

      {:ok, view, html} = open(conn, "c=#{marked.uuid}")
      assert html =~ "11.00"
      assert html =~ "/ set"
      refute has_element?(view, "#picker-table th", "Unit")
      refute has_element?(view, "#picker-table th", "Base price")
      refute html =~ ">10.00<"

      # An internal embed asks for the raw column explicitly.
      {:ok, view, html} = open(conn, "c=#{marked.uuid}&cols=name,base_price")
      assert has_element?(view, "#picker-table th", "Base price")
      assert html =~ "10.00"
      refute html =~ "11.00"
    end

    test "SKU starts hidden; the Columns dropdown reveals it within the granted set", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}")

      # Hidden by default in the picker — but granted, so the dropdown
      # offers it and the data waits one click away.
      refute has_element?(view, "#picker-table th", "SKU")
      assert has_element?(view, ~s(#picker-column-toggle [phx-value-col="sku"]))
      _ = html

      view |> picker() |> render_click("toggle_column", %{"col" => "sku"})
      assert has_element?(view, "#picker-table th", "SKU")
      assert render(view) =~ "M8-100"

      # And hiding it again removes header and data both.
      view |> picker() |> render_click("toggle_column", %{"col" => "sku"})
      refute has_element?(view, "#picker-table th", "SKU")
      refute render(view) =~ "M8-100"
    end

    test "toggle_column refuses pinned and ungranted columns", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      # :name is the last visible identity column here; :base_price was
      # never granted; garbage is garbage.
      view |> picker() |> render_click("toggle_column", %{"col" => "name"})
      view |> picker() |> render_click("toggle_column", %{"col" => "base_price"})
      view |> picker() |> render_click("toggle_column", %{"col" => "bogus"})

      assert has_element?(view, "#picker-table th", "Name")
      refute has_element?(view, "#picker-table th", "Base price")
      assert Process.alive?(view.pid)
    end

    test "breadcrumb: the category prefix gets its own unlabeled column beside Name", %{
      conn: conn,
      cat: cat
    } do
      fasteners = fixture_category(cat, %{name: "Fasteners"})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Wood screws 4x40 (100pk)",
          catalogue_uuid: cat.uuid,
          category_uuid: fasteners.uuid
        })

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      # Off by default, offered in the dropdown.
      refute render(view) =~ "Fasteners /"
      assert has_element?(view, ~s(#picker-column-toggle [phx-value-col="breadcrumb"]))

      view |> picker() |> render_click("toggle_column", %{"col" => "breadcrumb"})
      # Redundant standalone Category column can go in its favour.
      view |> picker() |> render_click("toggle_column", %{"col" => "category"})

      html = render(view)
      # The prefix lives in its OWN cell — muted, slash-terminated — and
      # the name stays clean in the Name column.
      assert html =~ "Fasteners /"
      assert has_element?(view, "#picker-table td", "Fasteners /")
      assert has_element?(view, "#picker-table th", "Name")
      refute has_element?(view, "#picker-table th", "Category")

      # An uncategorized row simply leaves the prefix cell empty (the seed
      # items have no category and must not render a stray slash).
      refute html =~ "> /<"

      # Name is the identity column and cannot be hidden.
      view |> picker() |> render_click("toggle_column", %{"col" => "name"})
      assert has_element?(view, "#picker-table th", "Name")
    end

    test "quantity-first pins the qty column — the selector cannot be hidden", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity")

      refute has_element?(view, ~s(#picker-column-toggle [phx-value-col="qty"]))
      view |> picker() |> render_click("toggle_column", %{"col" => "qty"})
      assert has_element?(view, "#picker-table th", "Qty")
    end

    test "hidden_columns is the host's knob — empty list shows SKU from the start", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&hide=")

      assert has_element?(view, "#picker-table th", "SKU")
    end

    test "the Uncategorized chip makes the filters add up", %{conn: conn, cat: cat} do
      # Categorized and uncategorized items coexist; without this chip the
      # category chips can never reach the loose items.
      tools = fixture_category(cat, %{name: "Tools"})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Torx Driver",
          catalogue_uuid: cat.uuid,
          category_uuid: tools.uuid
        })

      {:ok, view, html} = open(conn, "c=#{cat.uuid}")
      assert html =~ "Uncategorized"

      # Narrow to the loose items: the categorized one disappears, the
      # uncategorized seed items stay.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => "__uncategorized__"})
      refute html =~ "Torx Driver"
      assert html =~ "M8 Screw"

      # All restores everything.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => ""})
      assert html =~ "Torx Driver"
    end

    test "the Uncategorized chip stays away from scopes that cannot accept it", %{
      conn: conn,
      cat: cat
    } do
      tools = fixture_category(cat, %{name: "Tools"})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Torx Driver",
          catalogue_uuid: cat.uuid,
          category_uuid: tools.uuid
        })

      # Category-restricted scope: uncategorized sits outside it.
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&cat_scope=#{tools.uuid}")
      refute html =~ "Uncategorized"

      # And a crafted event is refused by the reducer either way.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cat_scope=#{tools.uuid}")
      html = view |> picker() |> render_click("browse_category", %{"uuid" => "__uncategorized__"})
      assert html =~ "Torx Driver"
    end

    test "cards honor the columns contract — no price/SKU one toggle away", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # Host granted neither :price nor :sku. The table hides them; the
      # card view must not have them reappear.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=thumb,name,qty")

      html = view |> picker() |> render_click("set_view", %{"mode" => "card"})
      assert html =~ ~s(id="picker-card-#{screw.uuid}")
      refute html =~ "2.50"
      refute html =~ "M8-100"

      # And default-hidden SKU stays hidden on cards until the viewer
      # reveals it in the dropdown (visible drives both views).
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")
      html = view |> picker() |> render_click("set_view", %{"mode" => "card"})
      refute html =~ "M8-100"

      view |> picker() |> render_click("set_view", %{"mode" => "table"})
      view |> picker() |> render_click("toggle_column", %{"col" => "sku"})
      html = view |> picker() |> render_click("set_view", %{"mode" => "card"})
      assert html =~ "M8-100"
    end

    test "a parent-category chip still shows the whole subtree", %{conn: conn, cat: cat} do
      parent = fixture_category(cat, %{name: "Parent Scope"})
      child = fixture_category(cat, %{name: "Child Scope", parent_uuid: parent.uuid})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Deep Nested Item",
          catalogue_uuid: cat.uuid,
          category_uuid: child.uuid
        })

      {:ok, view, html} = open(conn, "c=#{cat.uuid}&cat_scope=#{parent.uuid}")
      assert html =~ "Deep Nested Item"

      # Clicking the PARENT chip must keep descendants' items — the scope
      # expansion regression fetched only the parent's direct items.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => parent.uuid})
      assert html =~ "Deep Nested Item"
    end

    test "qty bounds that invert after precision rounding raise at init", %{
      conn: conn,
      cat: cat
    } do
      # precision 0: min 1 (ceiled) vs max 0.9 -> 0 (floored) — every qty
      # would silently collapse to 0. Config fails loud instead.
      exit_value = catch_exit(open(conn, "c=#{cat.uuid}&max=0&min=1"))
      assert inspect(exit_value) =~ "rounds below"
    end

    test "quantity-first: every row is an order line, no click-selection", %{
      conn: conn,
      cat: cat,
      screw: screw,
      paint: paint
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=quantity")

      # Steppers at 0 on every rendered row; rows are not click-targets.
      assert has_element?(view, ~s(#picker-qty-#{screw.uuid}-r0-input[value="0"]))
      assert has_element?(view, ~s(#picker-qty-#{paint.uuid}-r0-input[value="0"]))
      refute html =~ ~s(phx-click="card_click")

      # Plus on an unselected row selects at the minimum…
      view |> picker() |> render_click("qty_inc", %{"uuid" => screw.uuid})
      # …and typing a positive quantity selects at that quantity.
      view |> picker() |> render_click("qty_commit", %{"uuid" => paint.uuid, "value" => "5"})

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ ~s(<span id="picked-count">2</span>)
      assert html =~ "M8 Screw|M8-100|qty=1|"
      assert html =~ "White Paint|PAINT-W|qty=5|"
    end

    test "quantity-first: back to zero is deselection, zero input stays nothing", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity")

      # Typing "0" on an untouched row selects nothing.
      view |> picker() |> render_click("qty_commit", %{"uuid" => screw.uuid, "value" => "0"})
      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")

      # Up then down again removes the line entirely.
      view |> picker() |> render_click("qty_inc", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_dec", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")
    end

    test "quantity-first: crafted clicks and foreign uuids stay refused", %{
      conn: conn,
      cat: cat,
      screw: screw,
      forbidden: forbidden
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity")

      # card_click has no meaning in this mode — even crafted.
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      # A stepper event for an item this modal never rendered is refused
      # by the same presented gate that guards clicks.
      view |> picker() |> render_click("qty_inc", %{"uuid" => forbidden.uuid})
      view |> picker() |> render_click("qty_commit", %{"uuid" => forbidden.uuid, "value" => "3"})

      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")
    end

    test "the category column shows each item's category, host-omittable", %{
      conn: conn,
      cat: cat
    } do
      shelving = fixture_category(cat, %{name: "Shelving"})

      {:ok, _item} =
        Catalogue.create_item(%{
          name: "Wall Bracket",
          catalogue_uuid: cat.uuid,
          category_uuid: shelving.uuid
        })

      # Default columns include Category, populated per row. Assertions
      # scope to the table — the chips row legitimately shows the name
      # regardless of columns (navigation, not data).
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")
      assert has_element?(view, "#picker-table th", "Category")
      assert has_element?(view, "#picker-table td", "Shelving")

      # A host that leaves it out shows neither header nor value.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=name,qty")
      refute has_element?(view, "#picker-table th", "Category")
      refute has_element?(view, "#picker-table td", "Shelving")
    end

    test "a parent-category scope shows and accepts descendant chips", %{conn: conn, cat: cat} do
      parent = fixture_category(cat, %{name: "Parent Cat"})
      child = fixture_category(cat, %{name: "Child Cat", parent_uuid: parent.uuid})

      {:ok, nested} =
        Catalogue.create_item(%{
          name: "Nested Item",
          catalogue_uuid: cat.uuid,
          category_uuid: child.uuid
        })

      {:ok, view, html} = open(conn, "c=#{cat.uuid}&cat_scope=#{parent.uuid}")

      # The subtree is part of the scope, so its chips must be offered…
      assert html =~ "Child Cat"
      assert html =~ "Nested Item"

      # …and narrowing to a descendant is accepted, not rejected as
      # out-of-scope.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => child.uuid})
      assert html =~ "Nested Item"
    end
  end
end
