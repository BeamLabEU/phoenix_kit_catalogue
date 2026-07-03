defmodule PhoenixKitCatalogue.Import.MatcherTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.Matcher
  alias PhoenixKitCatalogue.Schemas.Item

  defp item(sku), do: %Item{uuid: sku, sku: sku}

  test "indexes by digits-only sku and resolves a unique match" do
    idx = Matcher.index([item("76.0026.12"), item("C-01")])
    assert {:matched, %Item{sku: "76.0026.12"}} = Matcher.resolve(idx, "76002612")
  end

  test "returns :unmatched for unknown and blank ids" do
    idx = Matcher.index([item("76.0026.12")])
    assert :unmatched = Matcher.resolve(idx, "999")
    assert :unmatched = Matcher.resolve(idx, "")
  end

  test "returns :ambiguous when two skus reduce to the same digits" do
    idx = Matcher.index([item("76.00.26.12"), item("7600.2612")])
    assert {:ambiguous, [_, _]} = Matcher.resolve(idx, "76002612")
  end

  test "skips items whose sku has no digits" do
    idx = Matcher.index([item("ABC")])
    assert idx == %{}
  end
end
