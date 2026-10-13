defmodule PhoenixKitCatalogue.RefLookupTest do
  @moduledoc "The context's batched reference lookups (one query per call, trash and catalogue scope honoured)."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue

  setup do
    %{catalogue: fixture_catalogue(%{name: "Lookup Cat"})}
  end

  test "by uuid, sku and external id, for items", %{catalogue: catalogue} do
    a =
      fixture_item(%{
        name: "A",
        sku: "S-A",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => "E-A"}}
      })

    fixture_item(%{name: "B", sku: "S-B", catalogue_uuid: catalogue.uuid})

    assert %{} = by_id = Catalogue.lookup_by_ids(:item, [a.uuid, Ecto.UUID.generate()])
    assert Map.keys(by_id) == [a.uuid]
    assert %{"S-A" => [%{uuid: uuid}]} = Catalogue.lookup_by_skus(:item, ["S-A", "NOPE"])
    assert uuid == a.uuid
    assert %{"E-A" => [%{uuid: ^uuid}]} = Catalogue.lookup_by_external_ids(:item, ["E-A", "NOPE"])
  end

  test "trashed rows are hidden unless asked for, and the catalogue scope applies", %{
    catalogue: catalogue
  } do
    other = fixture_catalogue(%{name: "Other Lookup Cat"})
    gone = fixture_item(%{name: "Gone", sku: "S-G", catalogue_uuid: catalogue.uuid})
    elsewhere = fixture_item(%{name: "Elsewhere", sku: "S-E", catalogue_uuid: other.uuid})
    {:ok, _} = Catalogue.trash_item(gone)

    assert Catalogue.lookup_by_ids(:item, [gone.uuid]) == %{}

    assert Map.keys(Catalogue.lookup_by_ids(:item, [gone.uuid], include_deleted: true)) == [
             gone.uuid
           ]

    assert Catalogue.lookup_by_skus(:item, ["S-E"], catalogue_uuid: catalogue.uuid) == %{}

    assert %{"S-E" => [%{uuid: uuid}]} =
             Catalogue.lookup_by_skus(:item, ["S-E"], catalogue_uuid: other.uuid)

    assert uuid == elsewhere.uuid
  end

  test "categories: ids and external ids; a sku lookup is an empty map", %{catalogue: catalogue} do
    category =
      fixture_category(catalogue, %{name: "Shelf", data: %{"api" => %{"external_id" => "C-1"}}})

    assert Map.keys(Catalogue.lookup_by_ids(:category, [category.uuid])) == [category.uuid]
    assert %{"C-1" => [_]} = Catalogue.lookup_by_external_ids(:category, ["C-1"])
    assert Catalogue.lookup_by_skus(:category, ["anything"]) == %{}
  end

  test "empty input is an empty map without a query" do
    assert Catalogue.lookup_by_ids(:item, []) == %{}
    assert Catalogue.lookup_by_skus(:item, []) == %{}
    assert Catalogue.lookup_by_external_ids(:category, []) == %{}
  end
end
