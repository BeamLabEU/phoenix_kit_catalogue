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

  # Regression: two PRO100 rows whose digits-only ids both resolve to the same
  # catalogue item must produce exactly ONE change entry (not two). Previously
  # build/2 emitted two independent entries each built from the item's
  # pre-import snapshot; on apply the second write silently discarded the first
  # row's persisted data["pro100"] payload (silent data loss).
  test "two rows resolving to the same item are folded into one change (last-row-wins)" do
    # Both ids differ only in non-digit characters → same digits-only key "76002612"
    item = item(base_price: Decimal.new("80.00"), uuid: "uuid-collision-test")
    idx = Matcher.index([item])

    row1 = row(%{id: "76002612", base_price: Decimal.new("90.00"), service: %{"c3" => "first"}})
    row2 = row(%{id: "76002612", base_price: Decimal.new("100.00"), service: %{"c3" => "second"}})

    plan = Pro100Plan.build([row1, row2], idx)

    # Must produce exactly one change for that item, not two.
    assert length(plan.updates) == 1
    assert plan.stats.update == 1

    [change] = plan.updates

    # The newer row's price wins.
    assert {_old, new_price} = change.changes.base_price
    assert Decimal.equal?(new_price, Decimal.new("100.00"))

    # The newer row's pro100 data wins (data-loss regression guard).
    assert change.data["pro100"]["c3"] == "second"
  end

  # Regression: when the LAST of two colliding rows reasserts the item's
  # original (pre-import) price, the field must be treated as unchanged —
  # not silently left at an earlier colliding row's stale price. The bug:
  # each row's diff was computed independently against the pristine item, so
  # a row matching the original value produced an EMPTY diff and couldn't
  # override an earlier row's real change via Map.merge.
  test "last row reverting to the item's original price wins over an earlier row's change" do
    item = item(base_price: Decimal.new("80.00"), uuid: "uuid-revert-test")
    idx = Matcher.index([item])

    row1 = row(%{id: "76002612", base_price: Decimal.new("100.00"), service: %{"c3" => "first"}})
    row2 = row(%{id: "76002612", base_price: Decimal.new("80.00"), service: %{"c3" => "second"}})

    plan = Pro100Plan.build([row1, row2], idx)

    assert [change] = plan.updates
    refute Map.has_key?(change.changes, :base_price)
    assert change.data["pro100"]["c3"] == "second"
  end

  test "ambiguous rows carry the colliding items for the report" do
    item_a = item(uuid: "a")
    item_b = item(uuid: "b")
    idx = Matcher.index([item_a, item_b])

    plan = Pro100Plan.build([row(%{})], idx)

    assert [%{reason: :ambiguous, items: items}] = plan.skipped
    assert length(items) == 2
  end
end
