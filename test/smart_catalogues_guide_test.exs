defmodule PhoenixKitCatalogue.SmartCataloguesGuideTest do
  @moduledoc """
  Exercises the worked example from `guides/smart_catalogues.md` end
  to end. The reference implementation in the guide is repeated here
  as `Apply` — keep them in sync. If this test breaks, either the
  guide's example or the consumer-side math contract has shifted, and
  the guide needs updating to match.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.{CatalogueRule, Item}

  defmodule Apply do
    @moduledoc false
    # Verbatim transcription of the reference implementation in
    # guides/smart_catalogues.md §4. Keep them in lockstep.

    def apply_rules(entries) do
      ref_sums = build_ref_sums(entries)
      Enum.map(entries, &compute_price(&1, ref_sums))
    end

    defp build_ref_sums(entries) do
      entries
      |> Enum.filter(&(&1.item.catalogue.kind == "standard"))
      |> Enum.group_by(& &1.item.catalogue_uuid)
      |> Map.new(fn {catalogue_uuid, group} ->
        {catalogue_uuid, Enum.reduce(group, Decimal.new(0), &Decimal.add(line_total(&1), &2))}
      end)
    end

    defp line_total(%{item: %Item{base_price: nil}}), do: Decimal.new(0)

    defp line_total(%{item: %Item{base_price: price}, qty: qty}),
      do: Decimal.mult(price, Decimal.new(qty))

    defp compute_price(%{item: %Item{catalogue: %{kind: "smart"}} = item} = entry, ref_sums) do
      price =
        Enum.reduce(item.catalogue_rules, Decimal.new(0), fn rule, acc ->
          Decimal.add(acc, rule_amount(rule, item, ref_sums))
        end)

      Map.put(entry, :computed_price, price)
    end

    defp compute_price(entry, _ref_sums), do: entry

    defp rule_amount(rule, item, ref_sums) do
      {value, unit} = CatalogueRule.effective(rule, item)
      ref_sum = Map.get(ref_sums, rule.referenced_catalogue_uuid, Decimal.new(0))

      case {value, unit} do
        {nil, _} -> Decimal.new(0)
        {v, "percent"} -> Decimal.div(Decimal.mult(v, ref_sum), Decimal.new(100))
        {v, "flat"} -> v
        {_, _} -> Decimal.new(0)
      end
    end
  end

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

      panel_loaded = repo().preload(panel, [:catalogue, :catalogue_rules])

      delivery_loaded =
        repo().preload(delivery, [:catalogue, catalogue_rules: :referenced_catalogue])

      entries =
        Apply.apply_rules([
          %{item: panel_loaded, qty: 1},
          %{item: delivery_loaded, qty: 1}
        ])

      [panel_entry, delivery_entry] = entries

      refute Map.has_key?(panel_entry, :computed_price)
      assert Decimal.equal?(delivery_entry.computed_price, Decimal.new("15"))
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

      panel_loaded = repo().preload(panel, [:catalogue, :catalogue_rules])

      delivery_loaded =
        repo().preload(delivery, [:catalogue, catalogue_rules: :referenced_catalogue])

      [_, delivery_entry] =
        Apply.apply_rules([
          %{item: panel_loaded, qty: 1},
          %{item: delivery_loaded, qty: 1}
        ])

      # 10% (inherited from default_value) of 200 = 20
      assert Decimal.equal?(delivery_entry.computed_price, Decimal.new("20"))
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

      panel_loaded = repo().preload(panel, [:catalogue, :catalogue_rules])

      delivery_loaded =
        repo().preload(delivery, [:catalogue, catalogue_rules: :referenced_catalogue])

      [_, delivery_entry] =
        Apply.apply_rules([
          %{item: panel_loaded, qty: 1},
          %{item: delivery_loaded, qty: 1}
        ])

      assert Decimal.equal?(delivery_entry.computed_price, Decimal.new("20"))
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
