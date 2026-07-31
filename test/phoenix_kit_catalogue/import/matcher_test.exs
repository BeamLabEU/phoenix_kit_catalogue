defmodule PhoenixKitCatalogue.Import.MatcherTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.Matcher
  alias PhoenixKitCatalogue.Schemas.Item

  doctest PhoenixKitCatalogue.Import.Matcher, import: true

  defp item(sku, name \\ nil), do: %Item{uuid: sku, sku: sku, name: name || sku}

  describe "index/1" do
    test "indexes by digits-only sku and by {digits, normalised name}" do
      idx = Matcher.index([item("76.0026.12", "Widget")])

      assert %{digits: %{"76002612" => [_]}, digits_name: %{{"76002612", "widget"} => [_]}} = idx
    end

    test "skips items whose sku has no digits, in BOTH maps" do
      idx = Matcher.index([item("ABC", "Named Thing")])

      assert idx == %{digits: %{}, digits_name: %{}}
    end
  end

  describe "resolve/3 — stage order" do
    test "a blank id never matches, even when a same-named item exists" do
      # The regression this guards: the real export's "Tööpind" spacer row
      # carries no code and a price of 0.00, and the catalogue holds SKU-less
      # items with that name. A name-only match would zero a live price.
      idx = Matcher.index([item("", "Tööpind"), item("76.0026.12", "Real Item")])

      assert :unmatched = Matcher.resolve(idx, "", "Tööpind")
    end

    test "the name decides when the code is shared" do
      # 73.U767.18 and 73.U767.PM.18 both reduce to 7376718.
      idx =
        Matcher.index([
          item("73.U767.18", "MP U767 ST9 18mm, Cubanit Серый"),
          item("73.U767.PM.18", "MP U767 PM/ST9 18mm, Cubanit Серый")
        ])

      assert {:matched, %Item{sku: "73.U767.PM.18"}} =
               Matcher.resolve(idx, "7376718", "MP U767 PM/ST9 18mm, Cubanit Серый")

      assert {:matched, %Item{sku: "73.U767.18"}} =
               Matcher.resolve(idx, "7376718", "MP U767 ST9 18mm, Cubanit Серый")
    end

    test "falls back to the code alone when the name has drifted" do
      idx = Matcher.index([item("76.0026.12", "Widget")])

      assert {:matched, %Item{sku: "76.0026.12"}} =
               Matcher.resolve(idx, "76002612", "Widget renamed upstream")
    end

    test "a shared code with no name match stays ambiguous rather than guessing" do
      idx =
        Matcher.index([
          item("76.00.26.12", "One"),
          item("7600.2612", "Two")
        ])

      assert {:ambiguous, [_, _]} = Matcher.resolve(idx, "76002612", "Something Else")
    end

    test "a shared code AND a shared name stays ambiguous" do
      # Both file rows and both items are named identically; nothing can pick.
      idx =
        Matcher.index([
          item("74.W960.SM.2.28", "ABS W960 ST7 2/28mm, Белый"),
          item("74.W960.2.28", "ABS W960 ST7 2/28mm, Белый")
        ])

      assert {:ambiguous, [_, _]} = Matcher.resolve(idx, "74960228", "ABS W960 ST7 2/28mm, Белый")
    end

    test "an unknown code is unmatched" do
      idx = Matcher.index([item("76.0026.12")])

      assert :unmatched = Matcher.resolve(idx, "999", "Anything")
    end
  end

  describe "normalize_name/1" do
    test "is applied on both sides, so case and inner spacing do not matter" do
      idx = Matcher.index([item("76.0026.12", "MP  U741   ST9")])

      assert {:matched, _} = Matcher.resolve(idx, "76002612", "  mp u741 st9  ")
    end
  end
end
