defmodule PhoenixKitCatalogue.Import.MapperTest do
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Import.Mapper

  describe "auto_detect_mappings/1" do
    test "detects English headers" do
      headers = ["Name", "Description", "SKU", "Price", "Unit"]
      mappings = Mapper.auto_detect_mappings(headers)

      targets = Enum.map(mappings, & &1.target)
      assert :name in targets
      assert :sku in targets
      assert :base_price in targets
      assert :unit in targets
    end

    test "detects Estonian headers" do
      headers = ["Artikkel", "Kirjeldus", "Ühik", "Hind teile ilma km-ta"]
      mappings = Mapper.auto_detect_mappings(headers)

      assert Enum.find(mappings, &(&1.header == "Artikkel")).target == :sku
      assert Enum.find(mappings, &(&1.header == "Kirjeldus")).target == :name
      assert Enum.find(mappings, &(&1.header == "Ühik")).target == :unit
      assert Enum.find(mappings, &(&1.header == "Hind teile ilma km-ta")).target == :base_price
    end

    test "detects German headers" do
      headers = ["Bezeichnung", "Artikelnr", "Einheit", "Preis"]
      mappings = Mapper.auto_detect_mappings(headers)

      targets = Enum.map(mappings, & &1.target)
      assert :name in targets
      assert :sku in targets
      assert :unit in targets
      assert :base_price in targets
    end

    test "skips unknown headers" do
      headers = ["Random Column", "Another One"]
      mappings = Mapper.auto_detect_mappings(headers)
      assert Enum.all?(mappings, &(&1.target == :skip))
    end

    test "does not assign same target twice" do
      headers = ["Name", "Product Name", "Description"]
      mappings = Mapper.auto_detect_mappings(headers)

      name_count = Enum.count(mappings, &(&1.target == :name))
      assert name_count == 1
    end
  end

  describe "normalize_price/1" do
    test "parses decimal dot notation" do
      assert {:ok, d} = Mapper.normalize_price("4.88")
      assert Decimal.equal?(d, Decimal.new("4.88"))
    end

    test "parses decimal comma notation" do
      assert {:ok, d} = Mapper.normalize_price("4,88")
      assert Decimal.equal?(d, Decimal.new("4.88"))
    end

    test "strips currency symbols" do
      assert {:ok, d} = Mapper.normalize_price("€4.88")
      assert Decimal.equal?(d, Decimal.new("4.88"))
    end

    test "handles thousands separator with dot decimal" do
      assert {:ok, d} = Mapper.normalize_price("1,234.56")
      assert Decimal.equal?(d, Decimal.new("1234.56"))
    end

    test "handles whitespace" do
      assert {:ok, d} = Mapper.normalize_price("  4.88  ")
      assert Decimal.equal?(d, Decimal.new("4.88"))
    end

    test "rejects non-numeric" do
      assert :error = Mapper.normalize_price("abc")
    end

    test "rejects negative prices" do
      assert :error = Mapper.normalize_price("-5.00")
    end

    test "handles zero" do
      assert {:ok, d} = Mapper.normalize_price("0")
      assert Decimal.equal?(d, Decimal.new("0"))
    end
  end

  describe "normalize_unit/2" do
    test "maps Estonian TK to piece" do
      assert Mapper.normalize_unit("TK") == "piece"
    end

    test "maps KMPL to set" do
      assert Mapper.normalize_unit("KMPL") == "set"
    end

    test "maps m² to m2" do
      assert Mapper.normalize_unit("m²") == "m2"
    end

    test "maps jm to running_meter" do
      assert Mapper.normalize_unit("jm") == "running_meter"
    end

    test "defaults unknown to piece" do
      assert Mapper.normalize_unit("boxes") == "piece"
    end

    test "uses custom unit_map first" do
      assert Mapper.normalize_unit("KMPL", %{"KMPL" => "m2"}) == "m2"
    end

    test "is case-insensitive" do
      assert Mapper.normalize_unit("tk") == "piece"
      assert Mapper.normalize_unit("Tk") == "piece"
    end
  end

  describe "build_import_plan/3" do
    test "builds valid items from mapped rows" do
      mappings = [
        %{column_index: 0, header: "Name", target: :name},
        %{column_index: 1, header: "SKU", target: :sku},
        %{column_index: 2, header: "Price", target: :base_price}
      ]

      rows = [
        ["Oak Panel", "OAK-18", "4.88"],
        ["Birch Veneer", "BV-01", "3.50"]
      ]

      plan = Mapper.build_import_plan(mappings, rows)
      assert plan.stats.total == 2
      assert plan.stats.valid == 2
      assert plan.stats.invalid == 0
      assert length(plan.items) == 2

      item = List.first(plan.items)
      assert item.name == "Oak Panel"
      assert item.sku == "OAK-18"
      assert Decimal.equal?(item.base_price, Decimal.new("4.88"))
    end

    test "reports error for missing name" do
      mappings = [
        %{column_index: 0, header: "SKU", target: :sku}
      ]

      rows = [["OAK-18"]]

      plan = Mapper.build_import_plan(mappings, rows)
      assert plan.stats.invalid == 1
      assert [{1, "Missing item name"}] = plan.errors
    end

    test "extracts categories to create" do
      mappings = [
        %{column_index: 0, header: "Name", target: :name},
        %{column_index: 1, header: "Category", target: :category}
      ]

      rows = [
        ["Item 1", "Hooks"],
        ["Item 2", "Hinges"],
        ["Item 3", "Hooks"]
      ]

      plan = Mapper.build_import_plan(mappings, rows)
      assert plan.categories_to_create == ["Hinges", "Hooks"]
    end

    test "stores unit with original in data" do
      mappings = [
        %{column_index: 0, header: "Name", target: :name},
        %{column_index: 1, header: "Unit", target: :unit}
      ]

      rows = [["Panel", "TK"]]
      plan = Mapper.build_import_plan(mappings, rows)

      item = List.first(plan.items)
      assert item.unit == "piece"
      assert item.data["original_unit"] == "TK"
    end

    test "stores custom fields in data" do
      mappings = [
        %{column_index: 0, header: "Name", target: :name},
        %{column_index: 1, header: "Color", target: {:data, "color"}}
      ]

      rows = [["Panel", "Oak Natural"]]
      plan = Mapper.build_import_plan(mappings, rows)

      item = List.first(plan.items)
      assert item.data["color"] == "Oak Natural"
    end

    test "skips columns mapped to skip" do
      mappings = [
        %{column_index: 0, header: "Name", target: :name},
        %{column_index: 1, header: "Internal", target: :skip}
      ]

      rows = [["Panel", "secret data"]]
      plan = Mapper.build_import_plan(mappings, rows)

      item = List.first(plan.items)
      refute Map.has_key?(item, :internal)
    end
  end

  describe "unique_column_values/2" do
    test "returns sorted unique values" do
      rows = [["a", "TK"], ["b", "KMPL"], ["c", "TK"], ["d", "M2"]]
      assert Mapper.unique_column_values(rows, 1) == ["KMPL", "M2", "TK"]
    end

    test "excludes empty values" do
      rows = [["a", "TK"], ["b", ""], ["c", "TK"]]
      assert Mapper.unique_column_values(rows, 1) == ["TK"]
    end
  end

  describe "available_targets/0" do
    test "includes all expected targets" do
      targets = Mapper.available_targets()
      target_atoms = Enum.map(targets, fn {t, _} -> t end)

      assert :skip in target_atoms
      assert :name in target_atoms
      assert :sku in target_atoms
      assert :base_price in target_atoms
      assert :unit in target_atoms
      assert :category in target_atoms
    end
  end
end
