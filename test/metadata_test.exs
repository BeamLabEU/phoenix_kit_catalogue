defmodule PhoenixKitCatalogue.MetadataTest do
  @moduledoc """
  Pure unit tests for `PhoenixKitCatalogue.Metadata` — all functions are
  pure, no DB required, no async isolation concerns.

  Covers the three-phase form flow: `build_state/2` reads `resource.data`
  to seed the editor; `absorb_params/2` folds in user edits on validate;
  `inject_into_data/3` casts + wedges values into `params["data"]["meta"]`
  before the context save.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Metadata

  describe "definitions/1" do
    test "returns item metadata definitions" do
      defs = Metadata.definitions(:item)

      assert is_list(defs)
      refute defs == []

      keys = Enum.map(defs, & &1.key)
      assert "color" in keys
      assert "weight" in keys
    end

    test "returns catalogue metadata definitions" do
      defs = Metadata.definitions(:catalogue)

      assert is_list(defs)
      refute defs == []

      keys = Enum.map(defs, & &1.key)
      assert "brand" in keys
      assert "collection" in keys
    end

    test "item and catalogue definitions are distinct" do
      item_keys = :item |> Metadata.definitions() |> Enum.map(& &1.key) |> MapSet.new()
      catalogue_keys = :catalogue |> Metadata.definitions() |> Enum.map(& &1.key) |> MapSet.new()

      assert MapSet.disjoint?(item_keys, catalogue_keys),
             "item and catalogue definitions should not overlap by key"
    end

    test "every definition carries a string key and label" do
      for type <- [:item, :catalogue], def_ <- Metadata.definitions(type) do
        assert is_binary(def_.key), "key must be a string for #{type}"
        assert is_binary(def_.label), "label must be a string for #{type}"
        refute def_.key == "", "key must be non-empty for #{type}"
        refute def_.label == "", "label must be non-empty for #{type}"
      end
    end
  end

  describe "definition/2" do
    test "returns the matching definition by key" do
      assert %{key: "color"} = Metadata.definition(:item, "color")
      assert %{key: "brand"} = Metadata.definition(:catalogue, "brand")
    end

    test "returns nil for an unknown key" do
      assert Metadata.definition(:item, "nonexistent") == nil
      assert Metadata.definition(:catalogue, "nonexistent") == nil
    end

    test "does not cross resource types" do
      # "brand" is a catalogue key, not an item key.
      assert Metadata.definition(:item, "brand") == nil
      # "color" is an item key, not a catalogue key.
      assert Metadata.definition(:catalogue, "color") == nil
    end
  end

  describe "cast_value/2" do
    test "trims surrounding whitespace" do
      assert Metadata.cast_value(%{key: "color", label: "Color"}, "  red  ") == "red"
    end

    test "returns nil for blank strings" do
      assert Metadata.cast_value(%{key: "color", label: "Color"}, "") == nil
      assert Metadata.cast_value(%{key: "color", label: "Color"}, "   ") == nil
    end

    test "preserves interior whitespace" do
      assert Metadata.cast_value(%{key: "color", label: "Color"}, "dark red") == "dark red"
    end

    test "returns nil for non-binary values" do
      assert Metadata.cast_value(%{key: "color", label: "Color"}, nil) == nil
      assert Metadata.cast_value(%{key: "color", label: "Color"}, 42) == nil
      assert Metadata.cast_value(%{key: "color", label: "Color"}, %{}) == nil
    end
  end

  describe "build_state/2" do
    test "empty data produces empty state" do
      assert Metadata.build_state(:item, nil) == %{attached: [], values: %{}}
      assert Metadata.build_state(:item, %{}) == %{attached: [], values: %{}}
      assert Metadata.build_state(:item, %{"meta" => %{}}) == %{attached: [], values: %{}}
    end

    test "accepts a struct with :data field" do
      struct = %{data: %{"meta" => %{"color" => "red"}}}
      state = Metadata.build_state(:item, struct)

      assert state.attached == ["color"]
      assert state.values == %{"color" => "red"}
    end

    test "known keys land in definition order" do
      # "weight" comes before "color" in the raw map, but definitions list
      # "color" first — so the attached order should follow definitions.
      raw = %{"meta" => %{"weight" => "5kg", "color" => "red"}}
      state = Metadata.build_state(:item, raw)

      assert state.attached == ["color", "weight"]
      assert state.values == %{"color" => "red", "weight" => "5kg"}
    end

    test "legacy keys come after known keys, alphabetized" do
      raw = %{"meta" => %{"foo" => "x", "color" => "red", "bar" => "y"}}
      state = Metadata.build_state(:item, raw)

      assert state.attached == ["color", "bar", "foo"]
    end

    test "coerces nil / non-binary values to strings in state" do
      raw = %{"meta" => %{"color" => nil, "weight" => 5}}
      state = Metadata.build_state(:item, raw)

      assert state.values == %{"color" => "", "weight" => "5"}
    end

    test "ignores malformed meta shapes" do
      # A list under "meta" — shouldn't crash, just treat as no data.
      assert Metadata.build_state(:item, %{"meta" => []}) == %{attached: [], values: %{}}
    end
  end

  describe "absorb_params/2" do
    test "merges matching keys from params into values" do
      state = %{attached: ["color", "weight"], values: %{"color" => "", "weight" => ""}}
      params = %{"meta" => %{"color" => "red", "weight" => "5kg"}}

      assert Metadata.absorb_params(state, params) == %{
               attached: ["color", "weight"],
               values: %{"color" => "red", "weight" => "5kg"}
             }
    end

    test "ignores keys not in attached" do
      # Guards against resurrecting a just-removed row.
      state = %{attached: ["color"], values: %{"color" => "red"}}
      params = %{"meta" => %{"color" => "blue", "weight" => "5kg"}}

      assert Metadata.absorb_params(state, params) == %{
               attached: ["color"],
               values: %{"color" => "blue"}
             }
    end

    test "leaves state untouched when params have no meta submap" do
      state = %{attached: ["color"], values: %{"color" => "red"}}

      assert Metadata.absorb_params(state, %{}) == state
      assert Metadata.absorb_params(state, %{"item" => %{"sku" => "X-1"}}) == state
    end

    test "ignores missing keys (doesn't overwrite with nil)" do
      state = %{attached: ["color", "weight"], values: %{"color" => "red", "weight" => "5kg"}}
      # User cleared "weight" client-side but the form only sends non-empty entries
      params = %{"meta" => %{"color" => "blue"}}

      # "weight" should retain its previous value since params didn't include it.
      assert Metadata.absorb_params(state, params) == %{
               attached: ["color", "weight"],
               values: %{"color" => "blue", "weight" => "5kg"}
             }
    end
  end

  describe "inject_into_data/3" do
    test ~s|wedges cast meta into params["data"]["meta"]| do
      state = %{attached: ["color"], values: %{"color" => "red"}}
      params = %{"name" => "Widget"}

      result = Metadata.inject_into_data(params, state, :item)

      assert result == %{"name" => "Widget", "data" => %{"meta" => %{"color" => "red"}}}
    end

    test "preserves existing data fields" do
      state = %{attached: ["color"], values: %{"color" => "red"}}
      params = %{"data" => %{"featured_image_uuid" => "uuid-123"}}

      result = Metadata.inject_into_data(params, state, :item)

      assert result == %{
               "data" => %{
                 "featured_image_uuid" => "uuid-123",
                 "meta" => %{"color" => "red"}
               }
             }
    end

    test "drops blank values" do
      state = %{attached: ["color", "weight"], values: %{"color" => "", "weight" => "  "}}
      params = %{}

      result = Metadata.inject_into_data(params, state, :item)

      assert result == %{"data" => %{"meta" => %{}}}
    end

    test "keeps legacy keys untouched (doesn't trim, doesn't drop unless empty)" do
      # "unknown_legacy" isn't in definitions(:item); it should pass through.
      state = %{
        attached: ["color", "unknown_legacy"],
        values: %{"color" => "red", "unknown_legacy" => "archived-value"}
      }

      params = %{}

      result = Metadata.inject_into_data(params, state, :item)

      assert result == %{
               "data" => %{
                 "meta" => %{"color" => "red", "unknown_legacy" => "archived-value"}
               }
             }
    end

    test "drops blank legacy keys" do
      state = %{attached: ["unknown_legacy"], values: %{"unknown_legacy" => ""}}
      params = %{}

      result = Metadata.inject_into_data(params, state, :item)

      assert result == %{"data" => %{"meta" => %{}}}
    end

    test "normalizes missing or non-map data key" do
      state = %{attached: [], values: %{}}

      assert Metadata.inject_into_data(%{}, state, :item) == %{"data" => %{"meta" => %{}}}

      assert Metadata.inject_into_data(%{"data" => nil}, state, :item) == %{
               "data" => %{"meta" => %{}}
             }
    end
  end
end
