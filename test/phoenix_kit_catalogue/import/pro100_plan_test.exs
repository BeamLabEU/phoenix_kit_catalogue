defmodule PhoenixKitCatalogue.Import.Pro100PlanTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.{Matcher, Pro100Plan}
  alias PhoenixKitCatalogue.Schemas.Item

  defp item(attrs), do: struct(%Item{uuid: "u", sku: "76.0026.12", unit: "piece"}, attrs)

  defp row(attrs) do
    Map.merge(
      %{
        line_no: 2,
        raw_line: "raw",
        id: "76002612",
        name: "X",
        base_price: Decimal.new("100.00"),
        unit: nil,
        service: %{"c3" => "0", "c5" => "1.0", "c6" => "222.00", "c7" => "2.0"},
        format: :furniture
      },
      attrs
    )
  end

  test "matched row with a new price yields an :update with a price change + pro100 data" do
    idx = Matcher.index([item(base_price: Decimal.new("80.00"))])
    plan = Pro100Plan.build([row(%{})], idx)
    assert [change] = plan.updates
    assert change.status == :update
    {old, new} = change.changes.base_price
    assert Decimal.equal?(old, Decimal.new("80.00"))
    assert Decimal.equal?(new, Decimal.new("100.00"))

    assert change.data["pro100"] == %{
             "format" => "furniture",
             "c3" => "0",
             "c5" => "1.0",
             "c6" => "222.00",
             "c7" => "2.0"
           }
  end

  test "identical price yields :nochange (still carries pro100 data)" do
    idx = Matcher.index([item(base_price: Decimal.new("100.00"))])
    plan = Pro100Plan.build([row(%{})], idx)
    assert [change] = plan.updates
    assert change.status == :nochange
  end

  test "materials unknown unit flags unit_unrecognized and keeps current unit" do
    mat_item = item(unit: "piece")
    idx = Matcher.index([mat_item])

    r =
      row(%{
        format: :materials,
        unit: "m³",
        base_price: Decimal.new("100.00"),
        service: %{"c3" => "0", "c5" => "1.0"}
      })

    plan = Pro100Plan.build([r], idx)
    assert [change] = plan.updates
    assert :unit_unrecognized in change.flags
    refute Map.has_key?(change.changes, :unit)
    assert change.data["original_unit"] == "m³"
  end

  test "unmatched and ambiguous rows go to skipped with reasons" do
    idx = Matcher.index([])
    plan = Pro100Plan.build([row(%{})], idx)
    assert [%{reason: :unmatched}] = plan.skipped
    assert plan.stats.unmatched == 1
  end
end
