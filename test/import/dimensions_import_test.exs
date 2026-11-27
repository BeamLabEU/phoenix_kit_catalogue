defmodule PhoenixKitCatalogue.Import.DimensionsImportTest do
  @moduledoc """
  The V7 fields through import and export: the mapper's new targets and
  their row errors, the Universal JSON carrying sizes and supplier rows,
  and the full round trip — export, parse, map, execute — into another
  catalogue.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_supplier: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Errors
  alias PhoenixKitCatalogue.Export
  alias PhoenixKitCatalogue.Import.{Executor, Mapper}
  alias PhoenixKitCatalogue.Import.Source.Universal

  defp d(value), do: Decimal.new(value)
  defp same?(%Decimal{} = a, b), do: Decimal.equal?(a, d(b))

  defp mappings(pairs) do
    pairs
    |> Enum.with_index()
    |> Enum.map(fn {{header, target}, idx} ->
      %{column_index: idx, header: header, target: target}
    end)
  end

  describe "Mapper: detecting the new columns" do
    test "the export's own keys and plain headers map themselves" do
      headers = [
        "Name",
        "Length (mm)",
        "Width",
        "Paksus",
        "Pack size",
        "supplier_sku",
        "supplier_cost",
        "Currency",
        "Cost unit",
        "Supplier pack size"
      ]

      assert headers |> Mapper.auto_detect_mappings() |> Enum.map(& &1.target) == [
               :name,
               :length_mm,
               :width_mm,
               :thickness_mm,
               :pack_size,
               :supplier_sku,
               :supplier_cost,
               :supplier_currency,
               :supplier_cost_unit,
               :supplier_pack_size
             ]
    end

    test "a loosely named cost header is not taken for the supplier's cost" do
      # "Supplier price" could be the item's own price: the mapper proposes
      # what it always did, and the operator picks the supplier cost by hand.
      targets =
        ["Name", "Supplier price", "Unit cost"]
        |> Mapper.auto_detect_mappings()
        |> Enum.map(& &1.target)

      refute :supplier_cost in targets
    end

    test "every new target is offered by name" do
      offered = Mapper.available_targets() |> Enum.map(&elem(&1, 0))

      for target <-
            ~w(length_mm width_mm thickness_mm pack_size supplier_sku supplier_cost
               supplier_currency supplier_cost_unit supplier_pack_size)a do
        assert target in offered, inspect(target)
      end
    end
  end

  describe "Mapper: reading the cells" do
    @columns [
      {"Name", :name},
      {"L", :length_mm},
      {"W", :width_mm},
      {"T", :thickness_mm},
      {"Pack", :pack_size},
      {"Sup SKU", :supplier_sku},
      {"Cost", :supplier_cost},
      {"Cur", :supplier_currency},
      {"Per", :supplier_cost_unit},
      {"Sup pack", :supplier_pack_size}
    ]

    defp plan(rows), do: Mapper.build_import_plan(mappings(@columns), rows)

    test "sizes in millimetres, comma decimals and an mm suffix; kept as written" do
      plan =
        plan([
          ["Cross", "1250", "2500 mm", "6,5", "80", "BF-65", "830,00", "eur", "m³", "35"]
        ])

      assert plan.errors == []
      assert [item] = plan.items
      assert same?(item.length_mm, 1250)
      assert same?(item.width_mm, 2500)
      assert same?(item.thickness_mm, "6.5")
      assert same?(item.pack_size, 80)

      assert %{
               "supplier_sku" => "BF-65",
               "currency" => "EUR",
               "cost_unit" => "m3"
             } = item._supplier_terms

      assert same?(item._supplier_terms["unit_cost"], 830)
      assert same?(item._supplier_terms["pack_size"], 35)
    end

    test "blank cells are left out; an item needs none of them" do
      plan = plan([["Hinge", "", "", "", "", "", "", "", "", ""]])

      assert plan.errors == []
      assert [item] = plan.items
      refute Map.has_key?(item, :thickness_mm)
      refute Map.has_key?(item, :_supplier_terms)
    end

    test "a size in another unit, zero or words rejects the row, never a guess" do
      for bad <- ["2,5 m", "120 cm", "0", "-18", "thick", "18 inch"] do
        plan = plan([["Bad", "2500", "1250", bad, "", "", "", "", "", ""]])
        assert plan.items == [], bad
        assert [{1, {:invalid_dimension, ^bad}}] = plan.errors
      end
    end

    test "each other bad value names itself" do
      row = fn changes ->
        base = ["Bad", "", "", "", "", "", "", "", "", ""]
        Enum.reduce(changes, base, fn {idx, value}, acc -> List.replace_at(acc, idx, value) end)
      end

      assert [{1, {:invalid_pack_size, "0"}}] = plan([row.(%{4 => "0"})]).errors
      assert [{1, {:invalid_supplier_cost, "cheap"}}] = plan([row.(%{6 => "cheap"})]).errors
      assert [{1, {:invalid_currency_code, "euro"}}] = plan([row.(%{7 => "euro"})]).errors
      assert [{1, {:invalid_pack_size, "many"}}] = plan([row.(%{9 => "many"})]).errors
      # A cost unit is never coerced to "piece" the way an item's unit is.
      assert [{1, {:invalid_cost_unit, "pallet"}}] = plan([row.(%{8 => "pallet"})]).errors
    end

    test "the row errors read as sentences" do
      assert Errors.message({:invalid_dimension, "2,5 m"}) =~ "millimetres"
      assert Errors.message({:invalid_pack_size, "0"}) == "Invalid pack size: 0"
      assert Errors.message({:invalid_supplier_cost, "x"}) == "Invalid supplier cost: x"
      assert Errors.message({:invalid_currency_code, "euro"}) =~ "three-letter"
      assert Errors.message({:invalid_cost_unit, "pallet"}) == "Unknown cost unit: pallet"
    end
  end

  describe "Executor" do
    test "a mapped supplier's SKU, cost, cost unit and pack land on the item's supplier row" do
      target = fixture_catalogue(%{name: "Imported sheets"})
      supplier = fixture_supplier(%{name: "Birch Factory"})

      plan =
        Mapper.build_import_plan(
          mappings([
            {"Name", :name},
            {"Unit", :unit},
            {"L", :length_mm},
            {"W", :width_mm},
            {"T", :thickness_mm},
            {"Pack", :pack_size},
            {"Supplier", :supplier},
            {"Sup SKU", :supplier_sku},
            {"Cost", :supplier_cost},
            {"Cur", :supplier_currency},
            {"Per", :supplier_cost_unit},
            {"Sup pack", :supplier_pack_size}
          ]),
          [
            [
              "Ply 18",
              "sheet",
              "2500",
              "1250",
              "18",
              "40",
              "Birch Factory",
              "BF-18",
              "830",
              "EUR",
              "m3",
              "35"
            ],
            ["Ply bare", "sheet", "", "", "", "", "", "", "", "", "", ""]
          ]
        )

      assert plan.errors == []
      result = Executor.execute(plan, target.uuid, nil)
      assert result.created == 2
      assert result.errors == []

      [item] = Catalogue.search_items("Ply 18", catalogue_uuids: [target.uuid])
      assert item.unit == "sheet"
      assert same?(item.thickness_mm, 18)
      assert same?(item.pack_size, 40)
      assert same?(item.volume_m3, "0.05625")

      assert [info] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert info.supplier_uuid == supplier.uuid
      assert info.supplier_sku == "BF-18"
      assert info.currency == "EUR"
      assert info.cost_unit == "m3"
      assert same?(info.unit_cost, 830)
      assert same?(info.pack_size, 35)

      # What the import stored is what the host computes with.
      assert {:ok, per_sheet} = Catalogue.supplier_cost_per(item, info, "sheet")
      assert same?(per_sheet, "46.6875")

      [bare] = Catalogue.search_items("Ply bare", catalogue_uuids: [target.uuid])
      assert Catalogue.list_supplier_infos_for_item(bare.uuid) == []
    end

    test "supplier values without a supplier are not saved, and the item still imports" do
      target = fixture_catalogue(%{name: "No supplier"})

      plan =
        Mapper.build_import_plan(
          mappings([{"Name", :name}, {"Cost", :supplier_cost}, {"Per", :supplier_cost_unit}]),
          [["Orphan cost", "830", "m3"]]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = Executor.execute(plan, target.uuid, nil)
          assert result.created == 1
        end)

      assert log =~ "no supplier"
      [item] = Catalogue.search_items("Orphan cost", catalogue_uuids: [target.uuid])
      assert Catalogue.list_supplier_infos_for_item(item.uuid) == []
    end
  end

  describe "Universal JSON round trip" do
    setup do
      source = fixture_catalogue(%{name: "Sheets"})
      factory_a = fixture_supplier(%{name: "Factory A"})
      factory_b = fixture_supplier(%{name: "Factory B"})

      {:ok, ply} =
        Catalogue.create_item(%{
          name: "Birch plywood 6.5",
          sku: "BP-65",
          catalogue_uuid: source.uuid,
          unit: "sheet",
          # Cross grain: the length is the shorter side, and stays so.
          length_mm: 1250,
          width_mm: 2500,
          thickness_mm: "6.5",
          pack_size: 80
        })

      {:ok, _secondary} =
        Catalogue.create_supplier_info(%{
          item_uuid: ply.uuid,
          supplier_uuid: factory_b.uuid,
          supplier_source: "local",
          supplier_name_snapshot: "Factory B",
          unit_cost: "49.5",
          currency: "EUR"
        })

      {:ok, primary} =
        Catalogue.create_supplier_info(%{
          item_uuid: ply.uuid,
          supplier_uuid: factory_a.uuid,
          supplier_source: "local",
          supplier_name_snapshot: "Factory A",
          supplier_sku: "FA-65",
          unit_cost: "830",
          currency: "EUR",
          cost_unit: "m3",
          pack_size: 70
        })

      {:ok, _} = Catalogue.set_primary_supplier_info(primary)

      {:ok, _hinge} =
        Catalogue.create_item(%{name: "Hinge", sku: "H-1", catalogue_uuid: source.uuid})

      {_filename, json, _mime} =
        Export.build(%{destination: "universal", format: "json", catalogue_uuids: [source.uuid]})

      %{json: IO.iodata_to_binary(json), ply: ply, factory_a: factory_a}
    end

    test "the export carries the sizes and every supplier row, the primary first", %{json: json} do
      payload = Jason.decode!(json)
      ply = Enum.find(payload["items"], &(&1["sku"] == "BP-65"))

      assert ply["length_mm"] == "1250"
      assert ply["width_mm"] == "2500"
      assert ply["thickness_mm"] == "6.5"
      assert ply["pack_size"] == "80"
      refute Map.has_key?(ply, "volume_m3")

      assert [
               %{
                 "name" => "Factory A",
                 "sku" => "FA-65",
                 "cost" => "830",
                 "currency" => "EUR",
                 "cost_unit" => "m3",
                 "pack_size" => "70",
                 "primary" => true
               },
               %{"name" => "Factory B", "cost" => "49.5", "cost_unit" => "", "primary" => false}
             ] = ply["suppliers"]

      hinge = Enum.find(payload["items"], &(&1["sku"] == "H-1"))
      assert hinge["thickness_mm"] == ""
      assert hinge["suppliers"] == []
    end

    test "importing the file rebuilds the item and its primary supplier row exactly",
         %{json: json, ply: original, factory_a: factory_a} do
      target = fixture_catalogue(%{name: "Round trip"})
      {:ok, parsed} = Universal.parse(json, "export.json", :json)
      mappings = Mapper.auto_detect_mappings(parsed.headers)

      for target_key <-
            ~w(length_mm width_mm thickness_mm pack_size supplier supplier_sku supplier_cost
               supplier_currency supplier_cost_unit supplier_pack_size)a do
        assert Enum.any?(mappings, &(&1.target == target_key)), inspect(target_key)
      end

      plan = Mapper.build_import_plan(mappings, parsed.rows)
      assert plan.errors == []

      result = Executor.execute(plan, target.uuid, nil)
      assert result.created == 2
      assert result.errors == []

      [copy] = Catalogue.search_items("Birch plywood 6.5", catalogue_uuids: [target.uuid])
      assert copy.uuid != original.uuid
      assert copy.unit == "sheet"

      for field <- [:length_mm, :width_mm, :thickness_mm, :pack_size, :area_m2, :volume_m3] do
        assert Decimal.equal?(Map.fetch!(copy, field), Map.fetch!(original, field)),
               inspect(field)
      end

      # The same supplier is found by name, not created a second time.
      assert [info] = Catalogue.list_supplier_infos_for_item(copy.uuid)
      assert info.supplier_uuid == factory_a.uuid
      assert info.supplier_sku == "FA-65"
      assert info.currency == "EUR"
      assert info.cost_unit == "m3"
      assert same?(info.unit_cost, 830)
      assert same?(info.pack_size, 70)

      # 830 per m³ × 0.0203125 m³ per sheet, on the copy as on the original.
      assert {:ok, per_sheet} = Catalogue.supplier_cost_per(copy, info, "sheet")
      assert same?(per_sheet, "16.859375")

      [hinge] = Catalogue.search_items("Hinge", catalogue_uuids: [target.uuid])
      assert hinge.thickness_mm == nil
      assert Catalogue.list_supplier_infos_for_item(hinge.uuid) == []
    end

    test "a file from before these fields still imports", %{} do
      old =
        Jason.encode!(%{
          "items" => [
            %{"name" => "Old", "sku" => "O-1", "base_price" => "10.00", "unit" => "piece"}
          ]
        })

      target = fixture_catalogue(%{name: "Old file"})

      {:ok, parsed} = Universal.parse(old, "old.json", :json)
      plan = Mapper.build_import_plan(Mapper.auto_detect_mappings(parsed.headers), parsed.rows)
      assert plan.errors == []
      assert Executor.execute(plan, target.uuid, nil).created == 1
    end

    test "a suppliers value that is not a list of plain objects is not this format" do
      for bad <- [%{"a" => 1}, ["x"], [%{"name" => %{"nested" => true}}]] do
        json = Jason.encode!(%{"items" => [%{"name" => "X", "suppliers" => bad}]})
        assert Universal.parse(json, "bad.json", :json) == {:error, :bad_json_shape}
      end
    end
  end
end
