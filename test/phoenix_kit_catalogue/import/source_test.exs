defmodule PhoenixKitCatalogue.Import.SourceTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import
  alias PhoenixKitCatalogue.Import.Source

  test "registry lists universal + pro100 and looks up by key" do
    keys = Enum.map(Import.sources(), & &1.key())
    assert :universal in keys
    assert :pro100 in keys
    assert Import.source_by_key("pro100") == Source.Pro100
    assert Import.source_by_key(:universal) == Source.Universal
    assert Import.source_by_key("nope") == nil
  end

  test "pro100 source advertises furniture/materials, .txt, :sync flow" do
    assert Source.Pro100.flow() == :sync
    assert Source.Pro100.accept() == ~w(.txt)
    assert Enum.map(Source.Pro100.formats(), fn {k, _} -> k end) == [:furniture, :materials]
  end

  test "universal source advertises spreadsheet/json, :mapping flow" do
    assert Source.Universal.flow() == :mapping
    assert {:json, _} = Enum.find(Source.Universal.formats(), fn {k, _} -> k == :json end)
  end
end
