defmodule PhoenixKitCatalogue.SmartCataloguesGuideTest do
  @moduledoc """
  Exercises the worked example from `guides/smart_catalogues.md` end
  to end against real DB-loaded items. The guide directs consumers to
  `Catalogue.evaluate_smart_rules/2`; this test calls it the same way
  the guide tells them to. If this test breaks, either the guide is
  out of date or the public evaluator's contract has shifted.

  Pure-function coverage of every branch (NULL inheritance, missing
  refs, NotLoaded guards, custom :line_total, etc.) lives in
  `test/smart_pricing_test.exs`.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue

  describe "guide §3 worked example: 15% delivery on a kitchen line" do
    test "smart item's computed price is 15% of the standard line total" do
      {:ok, kitchen} = Catalogue.create_catalogue(%{name: "Kitchen"})

      {:ok, panel} =
        Catalogue.create_item(%{
          name: "Oak Panel",
          catalogue_uuid: kitchen.uuid,
          base_price: Decimal.new("100")
        })

      {:ok, services} = Catalogue.create_catalogue(%{name: "Services", kind: "smart"})

      {:ok, delivery} =
        Catalogue.create_item(%{
          name: "Delivery",
          catalogue_uuid: services.uuid,
          default_value: Decimal.new("5"),
          default_unit: "percent"
        })

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{
            referenced_catalogue_uuid: kitchen.uuid,
            value: Decimal.new("15"),
            unit: "percent"
          }
        ])

      [panel_loaded, delivery_loaded] =
        Catalogue.list_items_by_uuids([panel.uuid, delivery.uuid],
          preload: [catalogue_rules: :referenced_catalogue]
        )

      [panel_entry, delivery_entry] =
        Catalogue.evaluate_smart_rules([
          %{item: panel_loaded, qty: 1},
          %{item: delivery_loaded, qty: 1}
        ])

      refute Map.has_key?(panel_entry, :smart_price)
      assert Decimal.equal?(delivery_entry.smart_price, Decimal.new("15"))
    end

    test "rule with NULL value inherits item.default_value (data-layer fallback)" do
      {:ok, kitchen} = Catalogue.create_catalogue(%{name: "Kitchen"})

      {:ok, panel} =
        Catalogue.create_item(%{
          name: "Oak Panel",
          catalogue_uuid: kitchen.uuid,
          base_price: Decimal.new("200")
        })

      {:ok, services} = Catalogue.create_catalogue(%{name: "Services", kind: "smart"})

      {:ok, delivery} =
        Catalogue.create_item(%{
          name: "Delivery",
          catalogue_uuid: services.uuid,
          default_value: Decimal.new("10"),
          default_unit: "percent"
        })

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: nil, unit: "percent"}
        ])

      [panel_loaded, delivery_loaded] =
        Catalogue.list_items_by_uuids([panel.uuid, delivery.uuid],
          preload: [catalogue_rules: :referenced_catalogue]
        )

      [_, delivery_entry] =
        Catalogue.evaluate_smart_rules([
          %{item: panel_loaded, qty: 1},
          %{item: delivery_loaded, qty: 1}
        ])

      # 10% (inherited from default_value) of 200 = 20
      assert Decimal.equal?(delivery_entry.smart_price, Decimal.new("20"))
    end

    test "flat unit ignores ref_sum and uses the value directly" do
      {:ok, kitchen} = Catalogue.create_catalogue(%{name: "Kitchen"})

      {:ok, panel} =
        Catalogue.create_item(%{
          name: "Oak Panel",
          catalogue_uuid: kitchen.uuid,
          base_price: Decimal.new("999")
        })

      {:ok, services} = Catalogue.create_catalogue(%{name: "Services", kind: "smart"})

      {:ok, delivery} =
        Catalogue.create_item(%{
          name: "Delivery",
          catalogue_uuid: services.uuid,
          default_value: Decimal.new("0"),
          default_unit: "flat"
        })

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: Decimal.new("20"), unit: "flat"}
        ])

      [panel_loaded, delivery_loaded] =
        Catalogue.list_items_by_uuids([panel.uuid, delivery.uuid],
          preload: [catalogue_rules: :referenced_catalogue]
        )

      [_, delivery_entry] =
        Catalogue.evaluate_smart_rules([
          %{item: panel_loaded, qty: 1},
          %{item: delivery_loaded, qty: 1}
        ])

      assert Decimal.equal?(delivery_entry.smart_price, Decimal.new("20"))
    end
  end
end
