defmodule PhoenixKitCatalogue.Import.ParserTest do
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Import.Parser

  describe "detect_format/1" do
    test "detects xlsx" do
      assert Parser.detect_format("test.xlsx") == :xlsx
      assert Parser.detect_format("Test File.XLSX") == :xlsx
    end

    test "detects csv" do
      assert Parser.detect_format("test.csv") == :csv
      assert Parser.detect_format("test.tsv") == :csv
    end

    test "rejects unsupported formats" do
      assert Parser.detect_format("test.pdf") == {:error, :unsupported}
      assert Parser.detect_format("test.txt") == {:error, :unsupported}
    end
  end

  describe "parse/3 with CSV" do
    test "parses comma-separated CSV" do
      csv = "Name,SKU,Price\nOak Panel,OAK-18,4.88\nBirch Veneer,BV-01,3.50\n"
      assert {:ok, result} = Parser.parse(csv, "test.csv")
      assert result.headers == ["Name", "SKU", "Price"]
      assert result.row_count == 2
      assert result.sheets == ["Sheet1"]
      assert List.first(result.rows) == ["Oak Panel", "OAK-18", "4.88"]
    end

    test "parses semicolon-separated CSV" do
      csv = "Name;SKU;Price\nOak Panel;OAK-18;4,88\n"
      assert {:ok, result} = Parser.parse(csv, "test.csv")
      assert result.headers == ["Name", "SKU", "Price"]
      assert result.row_count == 1
    end

    test "parses tab-separated TSV" do
      tsv = "Name\tSKU\tPrice\nOak Panel\tOAK-18\t4.88\n"
      assert {:ok, result} = Parser.parse(tsv, "test.tsv")
      assert result.headers == ["Name", "SKU", "Price"]
      assert result.row_count == 1
    end

    test "handles BOM" do
      csv = "\xEF\xBB\xBFName,SKU\nOak,OAK-1\n"
      assert {:ok, result} = Parser.parse(csv, "test.csv")
      assert result.headers == ["Name", "SKU"]
    end

    test "skips empty rows" do
      csv = "Name,SKU\nOak,OAK-1\n,,\nBirch,BV-1\n"
      assert {:ok, result} = Parser.parse(csv, "test.csv")
      assert result.row_count == 2
    end

    test "trims whitespace from cells" do
      csv = "Name , SKU \n  Oak Panel  , OAK-18 \n"
      assert {:ok, result} = Parser.parse(csv, "test.csv")
      assert result.headers == ["Name", "SKU"]
      assert List.first(result.rows) == ["Oak Panel", "OAK-18"]
    end

    test "rejects unsupported format" do
      assert {:error, _msg} = Parser.parse("data", "test.pdf")
    end

    test "strips a fully empty leading column" do
      # Common spreadsheet quirk: a leading blank column survives export
      # as empty cells in every row. Without stripping, the importer
      # would render a phantom unnamed column in the preview and a
      # phantom mapping card.
      csv = ",Name,SKU\n,Oak,OAK-1\n,Birch,BV-1\n"
      assert {:ok, result} = Parser.parse(csv, "test.csv")
      assert result.headers == ["Name", "SKU"]
      assert List.first(result.rows) == ["Oak", "OAK-1"]
    end

    test "strips a fully empty middle column" do
      csv = "Name,,SKU\nOak,,OAK-1\nBirch,,BV-1\n"
      assert {:ok, result} = Parser.parse(csv, "test.csv")
      assert result.headers == ["Name", "SKU"]
      assert List.first(result.rows) == ["Oak", "OAK-1"]
    end

    test "strips a fully empty trailing column" do
      csv = "Name,SKU,\nOak,OAK-1,\nBirch,BV-1,\n"
      assert {:ok, result} = Parser.parse(csv, "test.csv")
      assert result.headers == ["Name", "SKU"]
    end

    test "keeps a column with a header but all-empty data" do
      # A real header (e.g., "Notes") with no content yet is still a
      # legitimate column the user might map.
      csv = "Name,Notes\nOak,\nBirch,\n"
      assert {:ok, result} = Parser.parse(csv, "test.csv")
      assert result.headers == ["Name", "Notes"]
      assert List.first(result.rows) == ["Oak", ""]
    end

    test "keeps a column with empty header but data present" do
      # Empty-header but data-bearing columns are malformed but not
      # noise; we keep them so the user can rename or skip in the UI.
      csv = "Name,\nOak,extra\nBirch,more\n"
      assert {:ok, result} = Parser.parse(csv, "test.csv")
      assert result.headers == ["Name", ""]
      assert List.first(result.rows) == ["Oak", "extra"]
    end
  end

  describe "parse/3 with XLSX" do
    @tag :integration
    test "parses sample xlsx file" do
      path = "/Users/maxdon/Downloads/ANDI MÖÖBEL HINNAKIRI 2026.xlsx"

      if File.exists?(path) do
        binary = File.read!(path)
        assert {:ok, result} = Parser.parse(binary, "test.xlsx")
        assert result.headers == ["Artikkel", "Kirjeldus", "Ühik", "Hind teile ilma km-ta"]
        assert result.row_count == 74
        assert "Data" in result.sheets
        assert length(List.first(result.rows)) == 4
      end
    end

    @tag :integration
    test "lists sheets from xlsx" do
      path = "/Users/maxdon/Downloads/ANDI MÖÖBEL HINNAKIRI 2026.xlsx"

      if File.exists?(path) do
        binary = File.read!(path)
        assert {:ok, sheets} = Parser.list_sheets(binary)
        assert "Data" in sheets
        assert "Aggregated Metadata" in sheets
      end
    end
  end
end
