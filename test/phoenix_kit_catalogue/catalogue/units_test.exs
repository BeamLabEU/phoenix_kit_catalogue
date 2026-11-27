defmodule PhoenixKitCatalogue.Catalogue.UnitsTest do
  @moduledoc """
  `Catalogue.convert/5` and `Catalogue.supplier_cost_per/3` with the
  numbers a sheet-goods business trades on: a 2500 × 1250 × 18 mm sheet is
  3.125 m² and 0.05625 m³, and nothing on the way is a float or rounded.
  Pure functions — no database.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo

  defp d(value), do: Decimal.new(value)

  defp sheet(attrs \\ []) do
    struct!(
      %Item{
        unit: "sheet",
        length_mm: d(2500),
        width_mm: d(1250),
        thickness_mm: d(18),
        pack_size: d(40)
      },
      attrs
    )
  end

  # Equal as numbers — `Decimal.new("56.25")` and `"56.250000"` are.
  defp assert_decimal({:ok, %Decimal{} = actual}, expected) do
    assert Decimal.equal?(actual, d(expected)), "expected #{expected}, got #{actual}"
  end

  describe "Item.area_m2/1 and Item.volume_m3/1" do
    test "2500 × 1250 × 18 mm is 3.125 m² and 0.05625 m³" do
      assert Decimal.equal?(Item.area_m2(sheet()), d("3.125"))
      assert Decimal.equal?(Item.volume_m3(sheet()), d("0.05625"))
    end

    test "6.5 mm keeps its precision" do
      thin = sheet(thickness_mm: d("6.5"))
      assert Decimal.equal?(Item.volume_m3(thin), d("0.0203125"))
    end

    test "the order of the dimensions changes neither" do
      cross = sheet(length_mm: d(1250), width_mm: d(2500))
      assert Decimal.equal?(Item.area_m2(cross), Item.area_m2(sheet()))
      assert Decimal.equal?(Item.volume_m3(cross), Item.volume_m3(sheet()))
    end

    test "nil until every dimension it needs is set" do
      assert Item.area_m2(sheet(width_mm: nil)) == nil
      assert Item.volume_m3(sheet(thickness_mm: nil)) == nil
      # The area needs no thickness.
      assert Decimal.equal?(Item.area_m2(sheet(thickness_mm: nil)), d("3.125"))
    end
  end

  describe "convert/5 from a countable base unit" do
    test "1000 sheets are 56.25 m³, and 56.25 m³ are 1000 sheets" do
      assert_decimal(Catalogue.convert(sheet(), 1000, "sheet", "m3"), "56.25")
      assert_decimal(Catalogue.convert(sheet(), "56.25", "m3", "sheet"), "1000")
    end

    test "sheets and m²" do
      assert_decimal(Catalogue.convert(sheet(), 1, "sheet", "m2"), "3.125")
      assert_decimal(Catalogue.convert(sheet(), d("312.5"), "m2", "sheet"), "100")
    end

    test "m² and m³ go through the sheet" do
      # 3.125 m² is one sheet is 0.05625 m³
      assert_decimal(Catalogue.convert(sheet(), d("3.125"), "m2", "m3"), "0.05625")
      assert_decimal(Catalogue.convert(sheet(), d("0.05625"), "m3", "m2"), "3.125")
    end

    test "a pack of 40 is 2.25 m³" do
      assert_decimal(Catalogue.convert(sheet(), 1, "pack", "m3"), "2.25")
      assert_decimal(Catalogue.convert(sheet(), 1, "pack", "sheet"), "40")
      assert_decimal(Catalogue.convert(sheet(), 100, "sheet", "pack"), "2.5")
      assert_decimal(Catalogue.convert(sheet(), d("2.25"), "m3", "pack"), "1")
    end

    test "the supplier's pack of 35 wins over the item's: 1.96875 m³" do
      info = %ItemSupplierInfo{pack_size: d(35)}

      assert_decimal(
        Catalogue.convert(sheet(), 1, "pack", "m3", supplier_info: info),
        "1.96875"
      )
    end

    test "a supplier row without a pack size falls back to the item's" do
      info = %ItemSupplierInfo{pack_size: nil}
      assert_decimal(Catalogue.convert(sheet(), 1, "pack", "m3", supplier_info: info), "2.25")
    end

    test "6.5 mm thickness keeps precision through a conversion" do
      thin = sheet(thickness_mm: d("6.5"))
      assert_decimal(Catalogue.convert(thin, 1000, "sheet", "m3"), "20.3125")
    end

    test "the result is exact, not a float's neighbour" do
      {:ok, result} = Catalogue.convert(sheet(), 1, "sheet", "m3")
      assert Decimal.to_string(Decimal.normalize(result), :normal) == "0.05625"
    end

    test "the same unit on both sides returns the quantity, dimensions or not" do
      bare = %Item{unit: "kg"}
      assert_decimal(Catalogue.convert(bare, "12.5", "kg", "kg"), "12.5")
    end

    test "every countable unit converts through its size" do
      for unit <- Item.countable_units() do
        assert_decimal(Catalogue.convert(sheet(unit: unit), 2, unit, "m2"), "6.25")
      end
    end
  end

  describe "convert/5 from base unit m2" do
    test "m² and m³ need the thickness alone" do
      board = %Item{unit: "m2", thickness_mm: d(18)}
      assert_decimal(Catalogue.convert(board, 100, "m2", "m3"), "1.8")
      assert_decimal(Catalogue.convert(board, d("1.8"), "m3", "m2"), "100")
    end

    test "without a thickness the dimensions are missing" do
      assert Catalogue.convert(%Item{unit: "m2"}, 1, "m2", "m3") ==
               {:error, :missing_dimensions}
    end
  end

  describe "convert/5 errors" do
    test "a unit outside the list is unknown, on either side" do
      assert Catalogue.convert(sheet(), 1, "pallet", "m3") == {:error, :unknown_unit}
      assert Catalogue.convert(sheet(), 1, "sheet", "furlong") == {:error, :unknown_unit}
      assert Catalogue.convert(sheet(), 1, "furlong", "furlong") == {:error, :unknown_unit}
    end

    test "a missing dimension" do
      assert Catalogue.convert(sheet(thickness_mm: nil), 1, "sheet", "m3") ==
               {:error, :missing_dimensions}

      assert Catalogue.convert(sheet(width_mm: nil), 1, "sheet", "m2") ==
               {:error, :missing_dimensions}

      # The area does not need the thickness.
      assert_decimal(Catalogue.convert(sheet(thickness_mm: nil), 1, "sheet", "m2"), "3.125")
    end

    test "a pack with no size anywhere" do
      assert Catalogue.convert(sheet(pack_size: nil), 1, "pack", "sheet") ==
               {:error, :missing_pack_size}

      assert Catalogue.convert(sheet(pack_size: nil), 1, "pack", "sheet",
               supplier_info: %ItemSupplierInfo{}
             ) == {:error, :missing_pack_size}
    end

    test "a pair no rule connects" do
      assert Catalogue.convert(sheet(), 1, "sheet", "kg") == {:error, :not_convertible}
      assert Catalogue.convert(sheet(), 1, "hour", "m3") == {:error, :not_convertible}
      assert Catalogue.convert(sheet(), 1, "sheet", "running_meter") == {:error, :not_convertible}
      # A weight has no size, whatever dimensions the row carries.
      assert Catalogue.convert(sheet(unit: "kg"), 1, "kg", "m3") == {:error, :not_convertible}
    end

    test "a float quantity is refused, like a string that is no number" do
      assert_raise ArgumentError, fn -> Catalogue.convert(sheet(), 1.5, "sheet", "m3") end
      assert_raise ArgumentError, fn -> Catalogue.convert(sheet(), "many", "sheet", "m3") end
    end
  end

  describe "supplier_cost_per/3" do
    defp per_m3(attrs \\ []) do
      struct!(%ItemSupplierInfo{unit_cost: d(830), cost_unit: "m3", currency: "EUR"}, attrs)
    end

    test "830 per m³ is 46.6875 per sheet, unrounded" do
      assert_decimal(Catalogue.supplier_cost_per(sheet(), per_m3(), "sheet"), "46.6875")
    end

    test "per pack: the item's 40, and the supplier's own 35" do
      assert_decimal(Catalogue.supplier_cost_per(sheet(), per_m3(), "pack"), "1867.5")

      assert_decimal(
        Catalogue.supplier_cost_per(sheet(), per_m3(pack_size: d(35)), "pack"),
        "1634.0625"
      )
    end

    test "per its own cost unit it is the cost" do
      assert_decimal(Catalogue.supplier_cost_per(sheet(), per_m3(), "m3"), "830")
    end

    test "no cost unit means the item's base unit" do
      info = %ItemSupplierInfo{unit_cost: d("46.6875"), cost_unit: nil}
      assert_decimal(Catalogue.supplier_cost_per(sheet(), info, "sheet"), "46.6875")
      assert_decimal(Catalogue.supplier_cost_per(sheet(), info, "m3"), "830")
    end

    test "a row without a cost" do
      assert Catalogue.supplier_cost_per(sheet(), %ItemSupplierInfo{cost_unit: "m3"}, "sheet") ==
               {:error, :no_cost}
    end

    test "conversion errors pass through" do
      assert Catalogue.supplier_cost_per(sheet(thickness_mm: nil), per_m3(), "sheet") ==
               {:error, :missing_dimensions}

      assert Catalogue.supplier_cost_per(sheet(), per_m3(), "kg") == {:error, :not_convertible}
      assert Catalogue.supplier_cost_per(sheet(), per_m3(), "pallet") == {:error, :unknown_unit}
    end
  end
end
