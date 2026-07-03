defmodule PhoenixKitCatalogue.Import.Pro100ParserTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.Pro100Parser

  defp fixture(name),
    do: File.read!(Path.join([__DIR__, "..", "..", "support", "fixtures", "pro100", name]))

  test "parses furniture rows, stripping BOM and the two leading tabs" do
    {:ok, rows} = Pro100Parser.parse(fixture("furniture_8.txt"), :furniture)
    assert length(rows) == 3
    [first | _] = rows
    assert first.name == "Second 1 furniture 222"
    assert first.id == "1111"
    assert Decimal.equal?(first.base_price, Decimal.new("2222.00"))
    assert first.service == %{"c3" => "0", "c5" => "1.0", "c6" => "222.00", "c7" => "1.0"}
    assert first.format == :furniture
    assert first.raw_line =~ "Second 1 furniture 222"
  end

  test "furniture preserves varying service columns (c6 empty, c7 = 2.0)" do
    {:ok, rows} = Pro100Parser.parse(fixture("furniture_8.txt"), :furniture)
    third = Enum.at(rows, 2)
    assert third.name == "Third 3 furniture 333"
    assert third.service == %{"c3" => "0", "c5" => "1.0", "c6" => "", "c7" => "2.0"}
  end

  test "parses materials rows with unit in c6" do
    {:ok, rows} = Pro100Parser.parse(fixture("materials_3.txt"), :materials)
    assert length(rows) == 4
    [first | _] = rows
    assert first.unit == "pc"
    assert first.service == %{"c3" => "0", "c5" => "1.0"}
    third = Enum.at(rows, 2)
    assert third.name == "sdfsdfsadf"
    assert third.id == "1111111111"
    assert third.unit == "m³"
  end

  test "rejects a header that does not match the requested format" do
    assert {:error, :bad_header} = Pro100Parser.parse(fixture("furniture_8.txt"), :materials)
  end

  test "errors on empty input" do
    assert {:error, :empty} = Pro100Parser.parse("", :furniture)
  end
end
