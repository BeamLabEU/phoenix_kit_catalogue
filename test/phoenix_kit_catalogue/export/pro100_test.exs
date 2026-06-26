defmodule PhoenixKitCatalogue.Export.Pro100Test do
  @moduledoc """
  Pure formatter tests for the PRO100 export source.

  No database access — all item data is constructed inline.
  Tests assert byte-exact output structure for Furniture, Materials,
  and Universal JSON formats.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Export.Pro100

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a minimal item struct without touching the DB.
  defp item(attrs \\ []) do
    base = %{
      name: "Widget Alpha",
      sku: "W-001",
      base_price: Decimal.new("100.00"),
      unit: "piece",
      category: %{uuid: "cat-uuid-1", name: "Category A"}
    }

    Map.merge(base, Map.new(attrs))
  end

  defp catalogue do
    %{uuid: "cat-uuid-1", name: "Test Catalogue"}
  end

  defp ctx(items, category \\ nil) do
    %{
      items: items,
      # Fixed timestamp so tests are deterministic
      index: 1_111_111_111,
      catalogue: catalogue(),
      category: category
    }
  end

  # ---------------------------------------------------------------------------
  # Source metadata
  # ---------------------------------------------------------------------------

  test "key/0 returns :pro100" do
    assert Pro100.key() == :pro100
  end

  test "label/0 returns PRO100 string" do
    assert Pro100.label() == "PRO100"
  end

  test "formats/0 returns furniture, materials, json" do
    keys = Pro100.formats() |> Enum.map(&elem(&1, 0))
    assert :furniture in keys
    assert :materials in keys
    assert :json in keys
  end

  # ---------------------------------------------------------------------------
  # format_price/1
  # ---------------------------------------------------------------------------

  describe "format_price/1" do
    test "nil becomes 0.00" do
      assert Pro100.format_price(nil) == "0.00"
    end

    test "integer-valued decimal gets .00 suffix" do
      assert Pro100.format_price(Decimal.new("2222")) == "2222.00"
    end

    test "one-decimal decimal gets trailing zero" do
      assert Pro100.format_price(Decimal.new("1.5")) == "1.50"
    end

    test "two-decimal decimal is unchanged" do
      assert Pro100.format_price(Decimal.new("33.33")) == "33.33"
    end

    test "zero decimal gives 0.00" do
      assert Pro100.format_price(Decimal.new("0")) == "0.00"
    end
  end

  # ---------------------------------------------------------------------------
  # sanitize/1
  # ---------------------------------------------------------------------------

  describe "sanitize/1" do
    test "strips tabs from strings" do
      assert Pro100.sanitize("hello\tworld") == "helloworld"
    end

    test "strips CR from strings" do
      assert Pro100.sanitize("hello\rworld") == "helloworld"
    end

    test "strips LF from strings" do
      assert Pro100.sanitize("hello\nworld") == "helloworld"
    end

    test "nil returns empty string" do
      assert Pro100.sanitize(nil) == ""
    end

    test "plain strings pass through unchanged" do
      assert Pro100.sanitize("Widget Alpha") == "Widget Alpha"
    end
  end

  # ---------------------------------------------------------------------------
  # Furniture format
  # ---------------------------------------------------------------------------

  describe "render(:furniture, ctx)" do
    test "returns Furniture.txt filename" do
      {filename, _content, _mime} = Pro100.render(:furniture, ctx([]))
      assert filename == "Furniture.txt"
    end

    test "returns text/plain mime" do
      {_filename, _content, mime} = Pro100.render(:furniture, ctx([]))
      assert mime == "text/plain"
    end

    test "header line is # Parts TAB index CRLF" do
      {_, content, _} = Pro100.render(:furniture, ctx([], nil))
      binary = IO.iodata_to_binary(content)
      assert String.starts_with?(binary, "# Parts\t1111111111\r\n")
    end

    test "each item row starts with two TABs" do
      items = [item()]
      {_, content, _} = Pro100.render(:furniture, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      assert String.starts_with?(hd(rows), "\t\t")
    end

    test "item row has correct TAB-delimited fields" do
      items = [item(name: "Chair", sku: "C-01", base_price: Decimal.new("2222"))]
      {_, content, _} = Pro100.render(:furniture, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)

      # Strip the two leading tabs, then split on remaining tabs
      row_data = String.trim_leading(hd(rows), "\t\t")
      fields = String.split(row_data, "\t")

      # 7 fields: name, sku, 0, price, 1.0, (empty), 0.0
      assert length(fields) == 7
      assert Enum.at(fields, 0) == "Chair"
      assert Enum.at(fields, 1) == "C-01"
      assert Enum.at(fields, 2) == "0"
      assert Enum.at(fields, 3) == "2222.00"
      assert Enum.at(fields, 4) == "1.0"
      assert Enum.at(fields, 5) == ""
      assert Enum.at(fields, 6) == "0.0"
    end

    test "nil price becomes 0.00 in row" do
      items = [item(base_price: nil)]
      {_, content, _} = Pro100.render(:furniture, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      row_data = String.trim_leading(hd(rows), "\t\t")
      fields = String.split(row_data, "\t")
      assert Enum.at(fields, 3) == "0.00"
    end

    test "nil sku becomes empty string in row" do
      items = [item(sku: nil)]
      {_, content, _} = Pro100.render(:furniture, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      row_data = String.trim_leading(hd(rows), "\t\t")
      fields = String.split(row_data, "\t")
      assert Enum.at(fields, 1) == ""
    end

    test "lines end with CRLF" do
      items = [item()]
      {_, content, _} = Pro100.render(:furniture, ctx(items))
      binary = IO.iodata_to_binary(content)
      # All lines end with CRLF
      lines = String.split(binary, "\r\n")
      # Last split after trailing CRLF is empty string — all others are non-empty
      [_last | non_trailing] = Enum.reverse(lines)
      assert Enum.all?(non_trailing, fn l -> l != "" end)
      # And the binary uses CRLF, not bare LF
      refute String.contains?(binary, "\n") == false
      assert String.contains?(binary, "\r\n")
    end

    test "content is UTF-8 binary" do
      items = [item(name: "Стул")]
      {_, content, _} = Pro100.render(:furniture, ctx(items))
      binary = IO.iodata_to_binary(content)
      assert String.valid?(binary)
      assert String.contains?(binary, "Стул")
    end

    test "multiple items produce multiple rows" do
      items = [item(name: "A"), item(name: "B"), item(name: "C")]
      {_, content, _} = Pro100.render(:furniture, ctx(items))
      binary = IO.iodata_to_binary(content)
      rows = String.split(binary, "\r\n", trim: true)
      # 1 header + 3 item rows
      assert length(rows) == 4
    end

    test "name with embedded TAB is sanitized" do
      items = [item(name: "Chair\tTable")]
      {_, content, _} = Pro100.render(:furniture, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      row_data = String.trim_leading(hd(rows), "\t\t")
      fields = String.split(row_data, "\t")
      # TAB in name gets stripped, so name field is "ChairTable"
      assert Enum.at(fields, 0) == "ChairTable"
    end
  end

  # ---------------------------------------------------------------------------
  # Materials format
  # ---------------------------------------------------------------------------

  describe "render(:materials, ctx)" do
    test "returns Materials.txt filename" do
      {filename, _, _} = Pro100.render(:materials, ctx([]))
      assert filename == "Materials.txt"
    end

    test "returns text/plain mime" do
      {_, _, mime} = Pro100.render(:materials, ctx([]))
      assert mime == "text/plain"
    end

    test "header line is # Materials TAB index CRLF" do
      {_, content, _} = Pro100.render(:materials, ctx([]))
      binary = IO.iodata_to_binary(content)
      assert String.starts_with?(binary, "# Materials\t1111111111\r\n")
    end

    test "item row has correct TAB-delimited fields with unit" do
      items = [item(name: "Plywood", sku: "PW-01", base_price: Decimal.new("111"), unit: "piece")]
      {_, content, _} = Pro100.render(:materials, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      row_data = String.trim_leading(hd(rows), "\t\t")
      fields = String.split(row_data, "\t")

      # 6 fields: name, sku, 0, price, 1.0, unit
      assert length(fields) == 6
      assert Enum.at(fields, 0) == "Plywood"
      assert Enum.at(fields, 1) == "PW-01"
      assert Enum.at(fields, 2) == "0"
      assert Enum.at(fields, 3) == "111.00"
      assert Enum.at(fields, 4) == "1.0"
      assert Enum.at(fields, 5) == "pc"
    end

    test "unit piece maps to pc" do
      items = [item(unit: "piece")]
      {_, content, _} = Pro100.render(:materials, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      fields = hd(rows) |> String.trim_leading("\t\t") |> String.split("\t")
      assert Enum.at(fields, 5) == "pc"
    end

    test "unit m2 maps to m²" do
      items = [item(unit: "m2")]
      {_, content, _} = Pro100.render(:materials, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      fields = hd(rows) |> String.trim_leading("\t\t") |> String.split("\t")
      assert Enum.at(fields, 5) == "m²"
    end

    test "unit running_meter maps to rm" do
      items = [item(unit: "running_meter")]
      {_, content, _} = Pro100.render(:materials, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      fields = hd(rows) |> String.trim_leading("\t\t") |> String.split("\t")
      assert Enum.at(fields, 5) == "rm"
    end

    test "unit set maps to set" do
      items = [item(unit: "set")]
      {_, content, _} = Pro100.render(:materials, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      fields = hd(rows) |> String.trim_leading("\t\t") |> String.split("\t")
      assert Enum.at(fields, 5) == "set"
    end

    test "nil unit maps to empty string" do
      items = [item(unit: nil)]
      {_, content, _} = Pro100.render(:materials, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      fields = hd(rows) |> String.trim_leading("\t\t") |> String.split("\t")
      assert Enum.at(fields, 5) == ""
    end

    test "unknown unit passes through" do
      items = [item(unit: "custom_unit")]
      {_, content, _} = Pro100.render(:materials, ctx(items))
      binary = IO.iodata_to_binary(content)
      [_header | rows] = String.split(binary, "\r\n", trim: true)
      fields = hd(rows) |> String.trim_leading("\t\t") |> String.split("\t")
      assert Enum.at(fields, 5) == "custom_unit"
    end

    test "lines end with CRLF" do
      items = [item()]
      {_, content, _} = Pro100.render(:materials, ctx(items))
      binary = IO.iodata_to_binary(content)
      assert String.contains?(binary, "\r\n")
    end

    test "UTF-8 content with Cyrillic name" do
      items = [item(name: "Стол")]
      {_, content, _} = Pro100.render(:materials, ctx(items))
      binary = IO.iodata_to_binary(content)
      assert String.valid?(binary)
      assert String.contains?(binary, "Стол")
    end
  end

  # ---------------------------------------------------------------------------
  # Universal JSON (via Pro100)
  # ---------------------------------------------------------------------------

  describe "render(:json, ctx)" do
    setup do
      items = [
        item(name: "Chair", sku: "CH-1", base_price: Decimal.new("500"), unit: "piece"),
        item(
          name: "Table",
          sku: "TB-1",
          base_price: nil,
          unit: "m2",
          category: %{uuid: "cat-2", name: "Tables"}
        )
      ]

      category = %{uuid: "cat-uuid-1", name: "Chairs"}
      {filename, content, mime} = Pro100.render(:json, ctx(items, category))
      {:ok, filename: filename, json: Jason.decode!(IO.iodata_to_binary(content)), mime: mime}
    end

    test "mime is application/json", %{mime: mime} do
      assert mime == "application/json"
    end

    test "filename ends with .json", %{filename: filename} do
      assert String.ends_with?(filename, ".json")
    end

    test "top-level catalogue key", %{json: json} do
      assert %{"uuid" => "cat-uuid-1", "name" => "Test Catalogue"} = json["catalogue"]
    end

    test "top-level category key when category given", %{json: json} do
      assert %{"uuid" => "cat-uuid-1", "name" => "Chairs"} = json["category"]
    end

    test "category is null when no category" do
      {_, content, _} = Pro100.render(:json, ctx([item()], nil))
      json = Jason.decode!(IO.iodata_to_binary(content))
      assert json["category"] == nil
    end

    test "exported_at is an ISO 8601 timestamp", %{json: json} do
      assert {:ok, _, _} = DateTime.from_iso8601(json["exported_at"])
    end

    test "index is an integer", %{json: json} do
      assert is_integer(json["index"])
    end

    test "items array has correct length", %{json: json} do
      assert length(json["items"]) == 2
    end

    test "item has name field", %{json: json} do
      assert hd(json["items"])["name"] == "Chair"
    end

    test "item has sku field", %{json: json} do
      assert hd(json["items"])["sku"] == "CH-1"
    end

    test "item base_price is 2dp string", %{json: json} do
      assert hd(json["items"])["base_price"] == "500.00"
    end

    test "item nil base_price becomes 0.00", %{json: json} do
      table_item = Enum.find(json["items"], &(&1["name"] == "Table"))
      assert table_item["base_price"] == "0.00"
    end

    test "item unit field is present", %{json: json} do
      assert hd(json["items"])["unit"] == "piece"
    end

    test "item category field is the category name", %{json: json} do
      assert hd(json["items"])["category"] == "Category A"
    end
  end
end
