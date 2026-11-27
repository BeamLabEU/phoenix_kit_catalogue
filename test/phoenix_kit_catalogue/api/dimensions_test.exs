defmodule PhoenixKitCatalogue.API.DimensionsTest do
  @moduledoc """
  The V7 size fields through the shop API: read as exact decimal strings,
  written by `create_products` / `update_products`, and filtered on by
  `list_products`. Supplier cost stays out of the API.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_item: 1]

  alias PhoenixKitCatalogue.API.Schemas
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.ApiCase

  @list "catalogue.list_products"
  @get "catalogue.get_products"
  @create "catalogue.create_products"
  @update "catalogue.update_products"

  setup do
    %{catalogue: fixture_catalogue(%{name: "Sheet goods API"})}
  end

  defp sheet(catalogue, name, extra \\ %{}) do
    fixture_item(
      Map.merge(
        %{
          name: name,
          catalogue_uuid: catalogue.uuid,
          unit: "sheet",
          length_mm: 2500,
          width_mm: 1250,
          thickness_mm: 18,
          pack_size: 40
        },
        extra
      )
    )
  end

  defp list_names(catalogue, filters) do
    assert {:ok, body} =
             ApiCase.call(
               @list,
               Map.merge(%{"catalogue_id" => catalogue.uuid, "fields" => ["name"]}, filters)
             )

    {body["items"] |> Enum.map(& &1["name"]) |> Enum.sort(), body["count"]}
  end

  test "get_products returns the size as exact decimal strings", %{catalogue: catalogue} do
    item = sheet(catalogue, "Plywood 18")

    assert {:ok, %{"results" => [%{"item" => read}]}} =
             ApiCase.call(@get, %{
               "catalogue_id" => catalogue.uuid,
               "refs" => [%{"id" => item.uuid}]
             })

    assert read["length_mm"] == "2500"
    assert read["width_mm"] == "1250"
    assert read["thickness_mm"] == "18"
    assert read["pack_size"] == "40"
    assert read["area_m2"] == "3.125"
    assert read["volume_m3"] == "0.05625"
  end

  test "an item without a size reads null, and no cost field exists", %{catalogue: catalogue} do
    item = fixture_item(%{name: "Hinge", catalogue_uuid: catalogue.uuid})

    assert {:ok, %{"results" => [%{"item" => read}]}} =
             ApiCase.call(@get, %{
               "catalogue_id" => catalogue.uuid,
               "refs" => [%{"id" => item.uuid}]
             })

    assert read["thickness_mm"] == nil
    assert read["volume_m3"] == nil

    for key <- ~w(unit_cost cost_unit supplier_sku base_price) do
      refute Map.has_key?(read, key)
    end

    for schema <- [Schemas.create_products(), Schemas.update_products()] do
      refute inspect(schema) =~ "cost_unit"
      refute inspect(schema) =~ "unit_cost"
    end
  end

  test "create_products takes numbers and decimal strings, stored as sent", %{
    catalogue: catalogue
  } do
    assert {:ok, %{"summary" => %{"created" => 2}, "results" => [first, second]}} =
             ApiCase.call(@create, %{
               "catalogue_id" => catalogue.uuid,
               "items" => [
                 %{
                   "name" => "Cross grain 6.5",
                   "sku" => "CG-65",
                   "unit" => "sheet",
                   "length_mm" => 1250,
                   "width_mm" => 2500,
                   "thickness_mm" => "6.5",
                   "pack_size" => 80
                 },
                 %{"name" => "Thin", "sku" => "T-07", "thickness_mm" => 0.7}
               ]
             })

    cross = Catalogue.get_item!(first["id"])
    assert Decimal.equal?(cross.length_mm, Decimal.new(1250))
    assert Decimal.equal?(cross.width_mm, Decimal.new(2500))
    assert Decimal.equal?(cross.thickness_mm, Decimal.new("6.5"))
    assert Decimal.equal?(cross.pack_size, Decimal.new(80))
    assert Decimal.equal?(cross.volume_m3, Decimal.new("0.0203125"))

    assert Decimal.equal?(Catalogue.get_item!(second["id"]).thickness_mm, Decimal.new("0.7"))
  end

  test "a bad size fails its own row and the others are still created", %{catalogue: catalogue} do
    assert {:ok, %{"results" => results}} =
             ApiCase.call(@create, %{
               "catalogue_id" => catalogue.uuid,
               "items" => [
                 %{"name" => "Zero", "sku" => "Z-0", "thickness_mm" => 0},
                 %{"name" => "Words", "sku" => "W-0", "length_mm" => "long"},
                 %{"name" => "Fine", "sku" => "F-0", "thickness_mm" => 18}
               ]
             })

    assert [
             %{"action" => "error", "error" => %{"code" => "validation_failed"} = zero},
             %{"action" => "error", "error" => %{"code" => "validation_failed"}},
             %{"action" => "created"}
           ] = results

    assert [%{"path" => "thickness_mm", "message" => "must be greater than 0"}] =
             zero["context"]["errors"]

    assert {["Fine"], 1} = list_names(catalogue, %{})
  end

  test "update_products changes and clears them", %{catalogue: catalogue} do
    item = sheet(catalogue, "Plywood 18")

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             ApiCase.call(@update, %{
               "catalogue_id" => catalogue.uuid,
               "items" => [
                 %{
                   "ref" => %{"id" => item.uuid},
                   "changes" => %{"thickness_mm" => "21", "pack_size" => nil}
                 }
               ]
             })

    updated = Catalogue.get_item!(item.uuid)
    assert Decimal.equal?(updated.thickness_mm, Decimal.new(21))
    assert updated.pack_size == nil
    assert Decimal.equal?(updated.volume_m3, Decimal.new("0.065625"))
    # Untouched fields stay.
    assert Decimal.equal?(updated.length_mm, Decimal.new(2500))
  end

  test "the derived fields cannot be written", %{catalogue: catalogue} do
    item = sheet(catalogue, "Plywood 18")

    assert {:error, :validation_failed, _message, _context} =
             ApiCase.call(@update, %{
               "catalogue_id" => catalogue.uuid,
               "items" => [%{"ref" => %{"id" => item.uuid}, "changes" => %{"volume_m3" => 1}}]
             })

    assert {:error, :validation_failed, _message, _context} =
             ApiCase.call(@create, %{
               "catalogue_id" => catalogue.uuid,
               "items" => [%{"name" => "X", "sku" => "X", "area_m2" => 1}]
             })
  end

  describe "list_products size filters" do
    setup %{catalogue: catalogue} do
      sheet(catalogue, "P 6.5", %{thickness_mm: "6.5"})
      sheet(catalogue, "P 12", %{thickness_mm: 12, length_mm: 1525, width_mm: 1525})
      sheet(catalogue, "P 18")
      fixture_item(%{name: "P bare", catalogue_uuid: catalogue.uuid})
      :ok
    end

    test "a range, an open end and an exact match", %{catalogue: catalogue} do
      assert {["P 12", "P 18"], 2} =
               list_names(catalogue, %{"thickness_mm_min" => 12, "thickness_mm_max" => 18})

      assert {["P 12", "P 6.5"], 2} = list_names(catalogue, %{"thickness_mm_max" => "12"})

      # A fractional JSON number is taken at its written value.
      assert {["P 6.5"], 1} =
               list_names(catalogue, %{"thickness_mm_min" => 6.5, "thickness_mm_max" => 6.5})

      assert {["P 12"], 1} = list_names(catalogue, %{"width_mm_min" => 1500})

      assert {["P 18", "P 6.5"], 2} =
               list_names(catalogue, %{"length_mm_min" => 2500, "length_mm_max" => 2500})
    end

    test "no filter lists everything, sized or not", %{catalogue: catalogue} do
      assert {["P 12", "P 18", "P 6.5", "P bare"], 4} = list_names(catalogue, %{})
    end

    test "a bound that is not a number is a request error", %{catalogue: catalogue} do
      assert {:error, _code, _message, context} =
               ApiCase.call(@list, %{
                 "catalogue_id" => catalogue.uuid,
                 "thickness_mm_min" => "thick"
               })

      assert inspect(context) =~ "thickness_mm_min"

      assert {:error, _code, _message, _context} =
               ApiCase.call(@list, %{
                 "catalogue_id" => catalogue.uuid,
                 "thickness_mm_max" => "NaN"
               })
    end
  end
end
