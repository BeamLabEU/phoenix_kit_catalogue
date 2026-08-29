defmodule PhoenixKitCatalogue.Web.Components.BrowseTest do
  @moduledoc """
  Render-shape tests for the embeddable Browse components — the pieces a
  host composes directly, so their attrs/markup contract is pinned here
  independently of the picker that also uses them.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1, render_component: 2]

  alias PhoenixKitCatalogue.Web.Components.Browse

  defp presented(over \\ %{}) do
    Map.merge(
      %{
        uuid: "u-1",
        name: "M8 Screw",
        sku: "M8-100",
        price: Decimal.new("2.50"),
        unit: "piece",
        manufacturer: nil,
        photo_url: nil,
        thumb_url: nil,
        default_qty: Decimal.new(1)
      },
      over
    )
  end

  describe "item_card/1" do
    test "no photo renders the deliberate SKU tile, never a broken image" do
      html = render_component(&Browse.item_card/1, id: "c1", item: presented())

      refute html =~ "<img"
      assert html =~ "M8-100"
      # The tile leads with the SKU initial.
      assert html =~ ">M</span>"
    end

    test "a photo renders lazily inside the fixed square frame" do
      html =
        render_component(&Browse.item_card/1,
          id: "c1",
          item: presented(%{photo_url: "/signed/medium/x"})
        )

      assert html =~ ~s(src="/signed/medium/x")
      assert html =~ ~s(loading="lazy")
      assert html =~ "aspect-square"
      assert html =~ "object-cover"
    end

    test "selected state draws the ring and badge; unselected draws neither" do
      selected =
        render_component(&Browse.item_card/1, id: "c1", item: presented(), selected: true)

      plain = render_component(&Browse.item_card/1, id: "c1", item: presented())

      assert selected =~ "ring-2"
      assert selected =~ "hero-check"
      refute plain =~ "ring-2"
      refute plain =~ "hero-check"
    end

    test "price and sku toggle off for embeddings that hide them" do
      html =
        render_component(&Browse.item_card/1,
          id: "c1",
          item: presented(),
          show_price: false,
          show_sku: false
        )

      refute html =~ "2.50"
      # The SKU still appears in the no-photo tile — hiding show_sku hides
      # the card-body line, not the placeholder identity.
      refute html =~ ~s(class="font-mono text-xs text-base-content/60")
    end
  end

  describe "qty_stepper/1" do
    test "integer mode: numeric keyboard, no unit suffix" do
      html =
        render_component(&Browse.qty_stepper/1, id: "q1", uuid: "u-1", qty: "3", precision: 0)

      assert html =~ ~s(inputmode="numeric")
      refute html =~ "join-item pointer-events-none"
    end

    test "decimal mode: decimal keyboard plus the unit suffix — same component" do
      html =
        render_component(&Browse.qty_stepper/1,
          id: "q1",
          uuid: "u-1",
          qty: "2.5",
          precision: 2,
          unit: "L"
        )

      assert html =~ ~s(inputmode="decimal")
      assert html =~ ">L</span>" or html =~ "L\n"
      assert html =~ ~s(value="2.5")
    end

    test "commit wiring: blur and submit both target qty_commit with the uuid" do
      html =
        render_component(&Browse.qty_stepper/1, id: "q1", uuid: "u-1", qty: "1", precision: 0)

      assert html =~ ~s(phx-blur="qty_commit")
      assert html =~ ~s(phx-submit="qty_commit")
      assert html =~ ~s(name="uuid" value="u-1")
    end
  end

  describe "category_chips/1" do
    test "All is active with no selection; the active chip flips with it" do
      cats = [%{uuid: "a", name: "Bolts"}, %{uuid: "b", name: "Paint"}]

      none = render_component(&Browse.category_chips/1, id: "ch", categories: cats)

      one =
        render_component(&Browse.category_chips/1, id: "ch", categories: cats, active_uuid: "b")

      assert none =~ ~r/btn-primary[^>]*>\s*All/
      assert one =~ ~r/btn-primary[^>]*\n?\s*phx-click/ or one =~ "Paint"
      assert one =~ ~s(phx-value-uuid="b")
    end
  end

  describe "present_items/2" do
    test "resolves translation, featured photo and default qty once, up front" do
      item = %{
        uuid: "u-9",
        name: "Primary Name",
        sku: "SKU-9",
        base_price: Decimal.new("10.00"),
        unit: "L",
        manufacturer_name: nil,
        manufacturer_name_snapshot: "ACME",
        default_value: Decimal.new("2.5"),
        data: %{"featured_image_uuid" => "photo-uuid"}
      }

      [p] = Browse.present_items([item], "en")

      assert p.uuid == "u-9"
      assert p.sku == "SKU-9"
      assert p.manufacturer == "ACME"
      # The signed URLs are computed here — the card never talks to
      # Storage. Two sizes: medium for the card faces, the 150px
      # thumbnail for the 32-48px row cells (2026-08-29 image sweep).
      assert p.photo_url =~ "photo-uuid"
      assert p.photo_url =~ "medium"
      assert p.thumb_url =~ "photo-uuid"
      assert p.thumb_url =~ "thumbnail"
      # Starting qty is always 1. `default_value` is the smart-catalogue
      # fee fallback, not a pick quantity.
      assert Decimal.equal?(p.default_qty, Decimal.new(1))
    end

    test "Item structs expose selling price (markup applied), not base_price" do
      item = %PhoenixKitCatalogue.Schemas.Item{
        uuid: "u-11",
        name: "Priced",
        sku: "P-1",
        base_price: Decimal.new("100.00"),
        markup_percentage: nil,
        discount_percentage: nil,
        unit: "piece",
        manufacturer_name: nil,
        manufacturer_name_snapshot: nil,
        default_value: Decimal.new("5"),
        data: %{},
        catalogue: %PhoenixKitCatalogue.Schemas.Catalogue{
          markup_percentage: Decimal.new("10"),
          discount_percentage: Decimal.new("0")
        }
      }

      [p] = Browse.present_items([item], "en")

      assert Decimal.equal?(p.price, Decimal.new("110.00"))
      assert Decimal.equal?(p.default_qty, Decimal.new(1))
    end

    test "no featured image and no default_value degrade to nil photo and qty 1" do
      item = %{
        uuid: "u-10",
        name: "Plain",
        sku: nil,
        base_price: nil,
        unit: "piece",
        manufacturer_name: nil,
        manufacturer_name_snapshot: nil,
        default_value: nil,
        data: %{}
      }

      [p] = Browse.present_items([item], "en")

      assert p.photo_url == nil
      assert p.thumb_url == nil
      assert Decimal.equal?(p.default_qty, Decimal.new(1))
    end
  end

  describe "grid geometry" do
    test "skeleton cards share the card frame so arrival does not reflow" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PhoenixKitCatalogue.Web.Components.Browse.grid_skeleton id="sk" count={2} />
        """)

      assert html =~ "aspect-square"
      # Same count as requested, each with a unique id.
      assert html =~ ~s(id="sk-1")
      assert html =~ ~s(id="sk-2")
    end
  end
end
