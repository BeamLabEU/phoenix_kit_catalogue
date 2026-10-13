defmodule PhoenixKitCatalogue.API.UpdateProductsTest do
  @moduledoc "`catalogue.update_products` (spec 6.1, 11.2)."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.ApiCase

  @tool "catalogue.update_products"

  setup do
    %{catalogue: fixture_catalogue(%{name: "Update Cat"})}
  end

  defp item(catalogue, name, extra \\ %{}),
    do: fixture_item(Map.merge(%{name: name, catalogue_uuid: catalogue.uuid}, extra))

  defp run_update(catalogue, entries, overrides \\ %{}),
    do: ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid, "items" => entries}, overrides)

  defp entry(ref, changes), do: %{"ref" => ref, "changes" => changes}

  defp rows({:ok, %{"results" => rows}}), do: rows

  test "renames by id, sku and external_id and logs who did it and what moved", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta", %{sku: "SKU-B"})
    c = item(catalogue, "Gamma", %{data: %{"api" => %{"external_id" => "E-C"}}})

    result =
      run_update(catalogue, [
        entry(%{"id" => a.uuid}, %{"name" => "Alpha 2"}),
        entry(%{"sku" => "SKU-B"}, %{"name" => "Beta 2"}),
        entry(%{"external_id" => "E-C"}, %{"name" => "Gamma 2"})
      ])

    assert {:ok, %{"summary" => %{"updated" => 3}}} = result
    assert Enum.map(rows(result), & &1["id"]) == [a.uuid, b.uuid, c.uuid]
    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
    assert Catalogue.get_item!(b.uuid).name == "Beta 2"
    assert Catalogue.get_item!(c.uuid).name == "Gamma 2"

    log =
      assert_activity_logged("item.updated",
        resource_uuid: a.uuid,
        actor_uuid: ApiCase.user_uuid()
      )

    assert log.mode == "auto"
    assert log.metadata["via"] == "api"
    assert log.metadata["tool"] == "catalogue.update_products"
    assert log.metadata["key_prefix"] == "abcd1234"
    assert log.metadata["request_id"] == "req-test"
    assert log.metadata["changes"]["name"] == %{"from" => "Alpha", "to" => "Alpha 2"}
  end

  test "a name is stored trimmed", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha")

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"name" => "  Alpha 2  "})])

    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
  end

  test "a rename leaves the slug where it is", %{catalogue: catalogue} do
    a = item(catalogue, "Oak panel", %{slug: %{"en-US" => "oak-panel"}})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"name" => "Oak panel XL"})])

    assert Catalogue.get_item!(a.uuid).slug == %{"en-US" => "oak-panel"}
  end

  test "keys of data the tool does not own are untouched", %{catalogue: catalogue} do
    data = %{
      "ecommerce" => %{"shopify" => %{"product_id" => "1"}, "compare_at_price" => "3"},
      "meta" => %{"color" => "red"},
      "_primary_language" => "en-US",
      "en-US" => %{"_name" => "Alpha"}
    }

    a = item(catalogue, "Alpha", %{data: data})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [
               entry(%{"id" => a.uuid}, %{"name" => "Alpha 2", "external_id" => "E-1"})
             ])

    assert Catalogue.get_item!(a.uuid).data == Map.put(data, "api", %{"external_id" => "E-1"})

    log = assert_activity_logged("item.updated", resource_uuid: a.uuid)
    assert log.metadata["changes"]["data.api.external_id"] == %{"from" => "", "to" => "E-1"}
  end

  test "external_id can be changed and cleared", %{catalogue: catalogue} do
    a =
      item(catalogue, "Alpha", %{
        data: %{"api" => %{"external_id" => "E-1"}, "meta" => %{"k" => "v"}}
      })

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"external_id" => "E-2"})])

    assert Catalogue.get_item!(a.uuid).data["api"] == %{"external_id" => "E-2"}

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"external_id" => "E-2"}, %{"external_id" => nil})])

    data = Catalogue.get_item!(a.uuid).data
    refute Map.has_key?(data, "api")
    assert data["meta"] == %{"k" => "v"}
  end

  test "an external_id another live item holds is a row error with the holder's id; the rest apply",
       %{catalogue: catalogue} do
    holder = item(catalogue, "Holder", %{data: %{"api" => %{"external_id" => "TAKEN"}}})
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta")

    result =
      run_update(catalogue, [
        entry(%{"id" => a.uuid}, %{"name" => "Alpha 2"}),
        entry(%{"id" => b.uuid}, %{"external_id" => "TAKEN", "name" => "Beta 2"}),
        entry(%{"id" => a.uuid}, %{"name" => "Again"})
      ])

    assert [one, two, three] = rows(result)
    assert one["action"] == "updated"
    assert two["action"] == "error"
    assert two["error"]["code"] == "already_exists"
    assert two["error"]["context"]["existing_id"] == holder.uuid
    assert three["action"] == "error"
    assert three["error"]["code"] == "validation_failed"

    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
    assert Catalogue.get_item!(b.uuid).name == "Beta"
  end

  test "category: move, uncategorize, and a foreign category is refused", %{catalogue: catalogue} do
    shelf = fixture_category(catalogue, %{name: "Shelf"})
    foreign = fixture_category(fixture_catalogue(%{name: "Elsewhere"}), %{name: "Foreign"})
    a = item(catalogue, "Alpha")

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => shelf.uuid})])

    assert Catalogue.get_item!(a.uuid).category_uuid == shelf.uuid
    moved = assert_activity_logged("item.moved", resource_uuid: a.uuid)
    assert moved.metadata["via"] == "api"

    assert {:ok, %{"summary" => %{"unchanged" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => shelf.uuid})])

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => nil})])

    assert Catalogue.get_item!(a.uuid).category_uuid == nil

    assert [%{"action" => "error", "error" => %{"context" => %{"errors" => [error]}}}] =
             rows(
               run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => foreign.uuid})])
             )

    assert error["path"] == "changes.category_id"
  end

  test "status, unit, sku and description (including null) are written", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha", %{sku: "OLD", description: "Old text"})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [
               entry(%{"id" => a.uuid}, %{
                 "status" => "discontinued",
                 "unit" => "pack",
                 "sku" => nil,
                 "description" => nil
               })
             ])

    reread = Catalogue.get_item!(a.uuid)

    assert {reread.status, reread.unit, reread.sku, reread.description} ==
             {"discontinued", "pack", nil, nil}
  end

  test "an update that changes nothing is unchanged and writes no entry", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha")

    assert {:ok, %{"summary" => %{"unchanged" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"name" => "Alpha"})])

    refute_activity_logged("item.updated", resource_uuid: a.uuid)
  end

  test "bad rows are reported at their position and never poison the others", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha")
    item(catalogue, "Twin 1", %{sku: "TWIN"})
    item(catalogue, "Twin 2", %{sku: "TWIN"})
    b = item(catalogue, "Beta")

    result =
      run_update(catalogue, [
        entry(%{"id" => a.uuid}, %{"name" => "Alpha 2"}),
        entry(%{"sku" => "TWIN"}, %{"name" => "Which?"}),
        entry(%{"id" => "not-a-uuid"}, %{"name" => "X"}),
        entry(%{"sku" => "NOPE"}, %{"name" => "X"}),
        entry(%{}, %{"name" => "X"}),
        entry(%{"id" => b.uuid}, %{}),
        entry(%{"id" => b.uuid}, %{"name" => "   "}),
        entry(%{"id" => b.uuid}, %{"name" => "Beta 2"})
      ])

    rows = rows(result)

    assert Enum.map(rows, & &1["action"]) ==
             ["updated", "error", "error", "error", "error", "error", "error", "updated"]

    assert Enum.map(rows, &get_in(&1, ["error", "code"])) ==
             [
               nil,
               "ambiguous_ref",
               "not_found",
               "not_found",
               "validation_failed",
               "validation_failed",
               "validation_failed",
               nil
             ]

    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
    assert Catalogue.get_item!(b.uuid).name == "Beta 2"
    assert {:ok, %{"summary" => %{"updated" => 2, "error" => 6}}} = result
  end

  test "a malformed category_id, a blank sku ref and a blank name fail their own row only", %{
    catalogue: catalogue
  } do
    # None of these may be a whole-request 422: row-level strings have no length floor in the schema.
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta")

    result =
      run_update(catalogue, [
        entry(%{"id" => a.uuid}, %{"name" => "Alpha 2"}),
        entry(%{"id" => b.uuid}, %{"category_id" => "short"}),
        entry(%{"sku" => ""}, %{"name" => "X"}),
        entry(%{"id" => b.uuid}, %{"name" => ""}),
        entry(%{"id" => b.uuid}, %{"name" => "Beta 2"})
      ])

    assert {:ok, %{"results" => rows, "summary" => %{"updated" => 2, "error" => 3}}} = result
    assert Enum.map(rows, & &1["action"]) == ["updated", "error", "error", "error", "updated"]
    assert Enum.all?(Enum.slice(rows, 1, 3), &(&1["error"]["code"] == "validation_failed"))
    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
    assert Catalogue.get_item!(b.uuid).name == "Beta 2"
  end

  test "a blank external_id in changes is a row error and writes nothing", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha", %{data: %{"meta" => %{"k" => "v"}}})

    assert [%{"action" => "error", "error" => %{"code" => "validation_failed"}}] =
             rows(
               run_update(catalogue, [
                 entry(%{"id" => a.uuid}, %{"external_id" => "  ", "name" => "X"})
               ])
             )

    reread = Catalogue.get_item!(a.uuid)
    assert reread.name == "Alpha"
    assert reread.data == a.data
  end

  test "an item of another catalogue is not found", %{catalogue: catalogue} do
    foreign = item(fixture_catalogue(%{name: "Elsewhere"}), "Foreign")

    assert [%{"action" => "error", "error" => %{"code" => "not_found"}}] =
             rows(
               run_update(catalogue, [entry(%{"id" => foreign.uuid}, %{"name" => "Hijacked"})])
             )

    assert Catalogue.get_item!(foreign.uuid).name == "Foreign"
  end

  test "the schema refuses price, markup, discount and raw data at any depth", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha")

    for field <- ~w(base_price markup_percentage discount_percentage data cost_per_item) do
      assert {:error, :validation_failed, _, %{errors: errors}} =
               run_update(catalogue, [entry(%{"id" => a.uuid}, %{field => 1})]),
             "#{field} was accepted"

      assert Enum.any?(errors, &(&1.path == "items[0].changes.#{field}")),
             "#{field}: #{inspect(errors)}"
    end

    assert {:error, :validation_failed, _, %{errors: errors}} =
             run_update(catalogue, [entry(%{"id" => a.uuid, "base_price" => 1}, %{"name" => "x"})])

    assert Enum.any?(errors, &(&1.path == "items[0].ref.base_price"))

    assert {:error, :validation_failed, _, %{errors: errors}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"status" => "deleted"})])

    assert Enum.any?(errors, &(&1.path == "items[0].changes.status"))
  end

  test "a batch announces one bulk event", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta")
    :ok = PubSub.subscribe()
    flush()

    {:ok, _} =
      run_update(catalogue, [
        entry(%{"id" => a.uuid}, %{"name" => "A2"}),
        entry(%{"id" => b.uuid}, %{"name" => "B2"})
      ])

    cat_uuid = catalogue.uuid
    assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, uuids, _from}
    assert Enum.sort(uuids) == Enum.sort([a.uuid, b.uuid])
    refute_receive {:catalogue_bulk_change, _, _, _, _}, 50
    assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    refute_receive {:catalogue_data_changed, _, _, _}, 50
  end

  test "recategorising many items is one bulk event and one data-changed event; each move logs item.moved (D12)",
       %{catalogue: catalogue} do
    shelf = fixture_category(catalogue, %{name: "Move target"})
    items = for n <- 1..3, do: item(catalogue, "Mover #{n}")
    :ok = PubSub.subscribe()
    flush()

    entries = for i <- items, do: entry(%{"id" => i.uuid}, %{"category_id" => shelf.uuid})
    assert {:ok, %{"summary" => %{"updated" => 3}}} = run_update(catalogue, entries)

    cat_uuid = catalogue.uuid
    assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, uuids, _from}
    assert Enum.sort(uuids) == items |> Enum.map(& &1.uuid) |> Enum.sort()
    refute_receive {:catalogue_bulk_change, _, _, _, _}, 50
    assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    refute_receive {:catalogue_data_changed, _, _, _}, 50

    # The documented exception to "one log insert": a move keeps the context's own
    # `item.moved` entry (readable from/to), so N moves are N entries, not 3 broadcasts.
    moved = Enum.filter(list_activities(), &(&1.action == "item.moved"))
    assert length(moved) == 3

    assert Enum.all?(
             moved,
             &(&1.metadata["via"] == "api" and &1.metadata["tool"] == "catalogue.update_products")
           )
  end

  test "501 rows and an empty list are refused", %{catalogue: catalogue} do
    entries = for n <- 1..501, do: entry(%{"sku" => "S#{n}"}, %{"name" => "N"})

    assert {:error, :validation_failed, _, %{errors: [%{limit: 500}]}} =
             run_update(catalogue, entries)

    assert {:error, :validation_failed, _, _} = run_update(catalogue, [])
  end

  describe "dry run" do
    test "previews the changes, writes nothing, and the fingerprint follows the state", %{
      catalogue: catalogue
    } do
      a = item(catalogue, "Alpha")

      entries = [
        entry(%{"id" => a.uuid}, %{"name" => "Alpha 2", "external_id" => "E-9"}),
        entry(%{"sku" => "NOPE"}, %{"name" => "X"})
      ]

      assert {:preview, %{"rows" => [row, missing], "summary" => %{"updated" => 1, "error" => 1}},
              fingerprint} =
               run_update(catalogue, entries, %{dry_run?: true})

      assert row["id"] == a.uuid

      assert row["changes"] == %{
               "name" => %{"from" => "Alpha", "to" => "Alpha 2"},
               "data.api.external_id" => %{"from" => "", "to" => "E-9"}
             }

      assert missing["error"]["code"] == "not_found"
      assert Catalogue.get_item!(a.uuid).name == "Alpha"
      refute_activity_logged("item.updated", resource_uuid: a.uuid)

      assert {:preview, _, ^fingerprint} = run_update(catalogue, entries, %{dry_run?: true})

      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(a.uuid), %{name: "Changed meanwhile"})
      assert {:preview, _, other} = run_update(catalogue, entries, %{dry_run?: true})
      assert other != fingerprint
    end

    test "shows a category move; naming the same item twice is refused in the preview too", %{
      catalogue: catalogue
    } do
      shelf = fixture_category(catalogue, %{name: "Shelf"})
      a = item(catalogue, "Alpha")

      assert {:preview, %{"rows" => [moved, same]}, _} =
               run_update(
                 catalogue,
                 [
                   entry(%{"id" => a.uuid}, %{"category_id" => shelf.uuid}),
                   entry(%{"id" => a.uuid}, %{"name" => "Alpha"})
                 ],
                 %{dry_run?: true}
               )

      assert moved["changes"]["category_id"] == %{"from" => "", "to" => shelf.uuid}
      # the second row names the same item again: the plan refuses it
      assert same["action"] == "error"
      assert same["error"]["code"] == "validation_failed"
    end
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
