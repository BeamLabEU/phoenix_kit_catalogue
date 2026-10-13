defmodule PhoenixKitCatalogue.API.UpsertCategoriesTest do
  @moduledoc "`catalogue.upsert_categories` (spec 6.1, 5.4)."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_category: 2]

  alias PhoenixKitCatalogue.API.Refs
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.ApiCase

  @tool "catalogue.upsert_categories"

  setup do
    %{catalogue: fixture_catalogue(%{name: "Upsert Cat"})}
  end

  defp upsert(catalogue, items, overrides \\ %{}),
    do: ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid, "items" => items}, overrides)

  defp rows({:ok, %{"results" => rows}}), do: rows
  defp category(id), do: Catalogue.get_category(id)

  test "creates categories by external_id, a child naming its parent from the same request",
       %{catalogue: catalogue} do
    result =
      upsert(catalogue, [
        %{"external_id" => "C-1", "name" => "Shelves", "position" => 3},
        %{
          "external_id" => "C-2",
          "name" => "Glass shelves",
          "parent" => %{"external_id" => "C-1"}
        }
      ])

    assert {:ok, %{"summary" => %{"created" => 2}}} = result
    assert [%{"id" => parent_id}, %{"id" => child_id}] = rows(result)

    parent = category(parent_id)
    child = category(child_id)

    assert {parent.name, parent.position, parent.parent_uuid, Refs.external_id(parent)} ==
             {"Shelves", 3, nil, "C-1"}

    assert {child.name, child.parent_uuid, Refs.external_id(child)} ==
             {"Glass shelves", parent_id, "C-2"}

    assert child.catalogue_uuid == catalogue.uuid

    log =
      assert_activity_logged("category.created",
        resource_uuid: child_id,
        actor_uuid: ApiCase.user_uuid()
      )

    assert log.mode == "auto"
    assert log.metadata["via"] == "api"
    assert log.metadata["tool"] == "catalogue.upsert_categories"
  end

  test "updates what differs, leaves what is not given, and is unchanged when nothing differs",
       %{catalogue: catalogue} do
    other = fixture_category(catalogue, %{name: "Other", data: %{"meta" => %{"k" => "v"}}})

    {:ok, shelves} =
      Catalogue.create_category(%{
        name: "Shelves",
        catalogue_uuid: catalogue.uuid,
        position: 1,
        data: %{"api" => %{"external_id" => "C-1"}, "meta" => %{"k" => "v"}}
      })

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             upsert(catalogue, [
               %{"external_id" => "C-1", "name" => "Racks", "parent" => %{"id" => other.uuid}}
             ])

    reread = category(shelves.uuid)
    assert {reread.name, reread.parent_uuid, reread.position} == {"Racks", other.uuid, 1}
    assert reread.data == %{"api" => %{"external_id" => "C-1"}, "meta" => %{"k" => "v"}}

    log = assert_activity_logged("category.updated", resource_uuid: shelves.uuid)
    assert log.metadata["changes"]["name"] == %{"from" => "Shelves", "to" => "Racks"}
    # Spec 4.7: the field that moved is in the diff, not only the actor and `via`.
    assert log.metadata["changes"]["parent_uuid"] == %{"from" => "", "to" => other.uuid}

    assert {:ok, %{"summary" => %{"unchanged" => 1}}} =
             upsert(catalogue, [%{"external_id" => "C-1", "name" => "Racks", "position" => 1}])
  end

  test "id plus external_id sets the external id of an existing category and keeps its other data",
       %{catalogue: catalogue} do
    c = fixture_category(catalogue, %{name: "Plain", data: %{"meta" => %{"k" => "v"}}})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             upsert(catalogue, [%{"id" => c.uuid, "external_id" => "C-9"}])

    reread = category(c.uuid)
    assert Refs.external_id(reread) == "C-9"
    assert reread.data["meta"] == %{"k" => "v"}

    log = assert_activity_logged("category.updated", resource_uuid: c.uuid)
    assert log.metadata["changes"]["data.api.external_id"] == %{"from" => "", "to" => "C-9"}
  end

  test "parent: null moves to the top level; a cycle and a foreign parent are row errors",
       %{catalogue: catalogue} do
    top = fixture_category(catalogue, %{name: "Top"})
    mid = fixture_category(catalogue, %{name: "Mid", parent_uuid: top.uuid})
    foreign = fixture_category(fixture_catalogue(%{name: "Elsewhere"}), %{name: "Foreign"})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             upsert(catalogue, [%{"id" => mid.uuid, "parent" => nil}])

    assert category(mid.uuid).parent_uuid == nil

    # a parent change is a diff entry, not only an actor (spec 4.7)
    log = assert_activity_logged("category.updated", resource_uuid: mid.uuid)
    assert log.metadata["changes"]["parent_uuid"] == %{"from" => top.uuid, "to" => ""}

    assert [row] = rows(upsert(catalogue, [%{"id" => top.uuid, "parent" => %{"id" => top.uuid}}]))
    assert row["action"] == "error"
    assert category(top.uuid).parent_uuid == nil

    {:ok, _} = Catalogue.update_category(category(mid.uuid), %{parent_uuid: top.uuid})

    assert [cycle] =
             rows(upsert(catalogue, [%{"id" => top.uuid, "parent" => %{"id" => mid.uuid}}]))

    assert cycle["action"] == "error"
    assert cycle["error"]["code"] == "validation_failed"

    assert [far] =
             rows(upsert(catalogue, [%{"id" => mid.uuid, "parent" => %{"id" => foreign.uuid}}]))

    assert far["action"] == "error"
    assert far["error"]["code"] == "not_found"
  end

  test "an unknown id is not found and creates nothing; a row needs a reference and, to create, a name",
       %{catalogue: catalogue} do
    before = length(Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid))

    rows =
      rows(
        upsert(catalogue, [
          %{"id" => Ecto.UUID.generate(), "name" => "Ghost"},
          %{"name" => "No reference"},
          %{"external_id" => "NEW-1"},
          %{"external_id" => "NEW-2", "name" => "   "},
          %{"external_id" => "NEW-3", "name" => "Fine"}
        ])
      )

    assert Enum.map(rows, & &1["action"]) == ["error", "error", "error", "error", "created"]

    assert Enum.map(rows, &get_in(&1, ["error", "code"])) == [
             "not_found",
             "validation_failed",
             "validation_failed",
             "validation_failed",
             nil
           ]

    assert length(Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid)) == before + 1
  end

  test "a malformed id, a malformed parent id and a blank external_id fail their own row only",
       %{catalogue: catalogue} do
    # Row-level fields have no length floor in the schema: none of these is a whole-request 422.
    rows =
      rows(
        upsert(catalogue, [
          %{"external_id" => "M-1", "name" => "Fine one"},
          %{"id" => "short", "name" => "Malformed id"},
          %{"external_id" => "M-2", "name" => "Malformed parent", "parent" => %{"id" => "short"}},
          %{"external_id" => "", "name" => "Blank external id"},
          %{"external_id" => "M-3", "name" => "Fine two"}
        ])
      )

    assert Enum.map(rows, & &1["action"]) == ["created", "error", "error", "error", "created"]

    assert Enum.map(rows, &get_in(&1, ["error", "code"])) == [
             nil,
             "not_found",
             "not_found",
             "validation_failed",
             nil
           ]
  end

  test "a blank external_id next to an id is a row error and writes nothing", %{
    catalogue: catalogue
  } do
    c = fixture_category(catalogue, %{name: "Plain", data: %{"meta" => %{"k" => "v"}}})

    assert [row] =
             rows(
               upsert(catalogue, [%{"id" => c.uuid, "external_id" => "", "name" => "Renamed"}])
             )

    assert row["action"] == "error"
    assert row["error"]["code"] == "validation_failed"

    reread = category(c.uuid)
    assert reread.name == "Plain"
    assert reread.data == %{"meta" => %{"k" => "v"}}
  end

  test "a trashed category frees its external_id", %{catalogue: catalogue} do
    {:ok, old} =
      Catalogue.create_category(%{
        name: "Old",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => "C-5"}}
      })

    {:ok, _} = Catalogue.trash_category(old)

    assert [%{"action" => "created", "id" => id}] =
             rows(upsert(catalogue, [%{"external_id" => "C-5", "name" => "New"}]))

    assert id != old.uuid
  end

  test "an external_id another category holds is a row error on update", %{catalogue: catalogue} do
    {:ok, holder} =
      Catalogue.create_category(%{
        name: "Holder",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => "TAKEN"}}
      })

    c = fixture_category(catalogue, %{name: "Plain"})

    assert [row] = rows(upsert(catalogue, [%{"id" => c.uuid, "external_id" => "TAKEN"}]))
    assert row["action"] == "error"
    assert row["error"]["code"] == "already_exists"
    assert row["error"]["context"]["existing_id"] == holder.uuid
  end

  test "the schema refuses unknown fields and bad values", %{catalogue: catalogue} do
    for {extra, path} <- [
          {%{"data" => %{}}, "items[0].data"},
          {%{"base_price" => 1}, "items[0].base_price"},
          {%{"position" => -1}, "items[0].position"},
          {%{"parent" => %{"name" => "x"}}, "items[0].parent.name"},
          {%{"parent" => "Shelves"}, "items[0].parent"}
        ] do
      assert {:error, :validation_failed, _, %{errors: errors}} =
               upsert(catalogue, [Map.merge(%{"external_id" => "C-1", "name" => "N"}, extra)])

      assert Enum.any?(errors, &(&1.path == path)), "#{inspect(extra)}: #{inspect(errors)}"
    end

    assert {:error, :validation_failed, _, _} = upsert(catalogue, [])
    items = for n <- 1..501, do: %{"external_id" => "C#{n}", "name" => "N#{n}"}
    assert {:error, :validation_failed, _, %{errors: [%{limit: 500}]}} = upsert(catalogue, items)
  end

  describe "dry run" do
    test "walks the batch without writing, accepting a parent the request would create", %{
      catalogue: catalogue
    } do
      c = fixture_category(catalogue, %{name: "Plain"})

      items = [
        %{"external_id" => "C-1", "name" => "Shelves"},
        %{"external_id" => "C-2", "name" => "Glass", "parent" => %{"external_id" => "C-1"}},
        %{"id" => c.uuid, "name" => "Renamed"},
        %{"id" => c.uuid, "name" => "Plain"}
      ]

      before = length(Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid))

      assert {:preview, %{"rows" => [one, two, three, four], "summary" => summary}, fingerprint} =
               upsert(catalogue, items, %{dry_run?: true})

      assert one["action"] == "created"
      assert one["fields"]["name"] == "Shelves"
      assert two["action"] == "created"
      assert three["action"] == "updated"
      assert three["changes"]["name"] == %{"from" => "Plain", "to" => "Renamed"}
      assert four["action"] == "unchanged"
      assert summary == %{"created" => 2, "updated" => 1, "unchanged" => 1}

      assert length(Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid)) == before
      assert category(c.uuid).name == "Plain"

      assert {:preview, _, ^fingerprint} = upsert(catalogue, items, %{dry_run?: true})

      {:ok, _} = Catalogue.update_category(category(c.uuid), %{name: "Changed meanwhile"})
      assert {:preview, _, other} = upsert(catalogue, items, %{dry_run?: true})
      assert other != fingerprint
    end

    test "answers the rows the write answers: a held external_id, a self-parent and a cycle", %{
      catalogue: catalogue
    } do
      {:ok, holder} =
        Catalogue.create_category(%{
          name: "Holder",
          catalogue_uuid: catalogue.uuid,
          data: %{"api" => %{"external_id" => "TAKEN"}}
        })

      plain = fixture_category(catalogue, %{name: "Plain"})
      top = fixture_category(catalogue, %{name: "Top"})
      mid = fixture_category(catalogue, %{name: "Mid", parent_uuid: top.uuid})
      leaf = fixture_category(catalogue, %{name: "Leaf"})

      items = [
        %{"id" => plain.uuid, "external_id" => "TAKEN"},
        %{"id" => top.uuid, "parent" => %{"id" => top.uuid}},
        %{"id" => top.uuid, "parent" => %{"id" => mid.uuid}},
        # two rows of one request: the first re-parents Leaf under Top, the second would close the loop
        %{"id" => leaf.uuid, "parent" => %{"id" => top.uuid}},
        %{"id" => top.uuid, "parent" => %{"id" => leaf.uuid}}
      ]

      assert {:preview, %{"rows" => preview_rows}, _} =
               upsert(catalogue, items, %{dry_run?: true})

      assert Enum.map(preview_rows, & &1["action"]) == [
               "error",
               "error",
               "error",
               "updated",
               "error"
             ]

      assert Enum.map(preview_rows, &get_in(&1, ["error", "code"])) == [
               "already_exists",
               "validation_failed",
               "validation_failed",
               nil,
               "validation_failed"
             ]

      assert hd(preview_rows)["error"]["context"]["existing_id"] == holder.uuid

      # nothing was written by the preview, and the write gives the same answers
      assert category(leaf.uuid).parent_uuid == nil
      executed = rows(upsert(catalogue, items))

      assert Enum.map(executed, &{&1["action"], get_in(&1, ["error", "code"])}) ==
               Enum.map(preview_rows, &{&1["action"], get_in(&1, ["error", "code"])})
    end

    test "a parent that nothing creates is still an error in the preview", %{catalogue: catalogue} do
      assert {:preview, %{"rows" => [row]}, _} =
               upsert(
                 catalogue,
                 [
                   %{
                     "external_id" => "C-2",
                     "name" => "Orphan",
                     "parent" => %{"external_id" => "NOPE"}
                   }
                 ],
                 %{dry_run?: true}
               )

      assert row["action"] == "error"
      assert row["error"]["code"] == "not_found"
    end
  end
end
