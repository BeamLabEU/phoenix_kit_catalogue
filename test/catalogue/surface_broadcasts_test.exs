defmodule PhoenixKitCatalogue.Catalogue.SurfaceBroadcastsTest do
  @moduledoc """
  Pins the `{:catalogue_data_changed, kind, uuid, parent}` fan-out of the
  writes that used to leave a surface stale until reload (2026-08 "as live
  as we can" batch). Every write that changes something a list/detail page
  shows must broadcast — after its transaction commits, never inside it.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub

  setup do
    PubSub.subscribe()
    :ok
  end

  defp catalogue!(name \\ "Cat") do
    {:ok, cat} = Catalogue.create_catalogue(%{name: name})
    cat
  end

  defp category!(cat, name \\ "Sec") do
    {:ok, c} = Catalogue.create_category(%{name: name, catalogue_uuid: cat.uuid})
    c
  end

  defp item!(cat, attrs \\ %{}) do
    {:ok, item} =
      Catalogue.create_item(Map.merge(%{name: "Item", catalogue_uuid: cat.uuid}, attrs))

    item
  end

  # Drop the events the fixtures themselves emitted so the assertions
  # below only see the write under test.
  defp flush do
    receive do
      {:catalogue_data_changed, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  describe "F1 — bulk item ops emit one batch :item event per touched catalogue" do
    test "bulk_trash_items" do
      cat = catalogue!()
      other = catalogue!("Other")
      a = item!(cat)
      b = item!(other)
      flush()

      assert {2, nil} = Catalogue.bulk_trash_items([a.uuid, b.uuid], [])

      assert_receive {:catalogue_data_changed, :item, nil, parent1}
      assert_receive {:catalogue_data_changed, :item, nil, parent2}
      assert Enum.sort([parent1, parent2]) == Enum.sort([cat.uuid, other.uuid])
      refute_receive {:catalogue_data_changed, :item, _, _}
    end

    test "bulk_trash_items is silent when nothing changed or when muted" do
      cat = catalogue!()
      a = item!(cat)
      flush()

      assert {0, nil} = Catalogue.bulk_trash_items([Ecto.UUID.generate()], [])
      refute_receive {:catalogue_data_changed, :item, _, _}

      assert {1, nil} = Catalogue.bulk_trash_items([a.uuid], broadcast: false)
      refute_receive {:catalogue_data_changed, :item, _, _}
    end

    test "bulk_restore_items" do
      cat = catalogue!()
      a = item!(cat)
      {1, nil} = Catalogue.bulk_trash_items([a.uuid], broadcast: false)
      flush()

      assert {1, nil} = Catalogue.bulk_restore_items([a.uuid], [])
      assert_receive {:catalogue_data_changed, :item, nil, parent}
      assert parent == cat.uuid
    end

    test "bulk_permanently_delete_items resolves the catalogue before the rows are gone" do
      cat = catalogue!()
      a = item!(cat)
      flush()

      assert {1, nil} = Catalogue.bulk_permanently_delete_items([a.uuid], [])
      assert_receive {:catalogue_data_changed, :item, nil, parent}
      assert parent == cat.uuid
    end

    test "bulk_move_items_to_category — into a category and to uncategorized" do
      cat = catalogue!()
      sec = category!(cat)
      a = item!(cat)
      flush()

      assert {:ok, 1} =
               Catalogue.bulk_move_items_to_category([a.uuid], sec.uuid, catalogue_uuid: cat.uuid)

      assert_receive {:catalogue_data_changed, :item, nil, parent}
      assert parent == cat.uuid

      assert {:ok, 1} =
               Catalogue.bulk_move_items_to_category([a.uuid], nil, catalogue_uuid: cat.uuid)

      assert_receive {:catalogue_data_changed, :item, nil, parent}
      assert parent == cat.uuid

      assert {:ok, 1} =
               Catalogue.bulk_move_items_to_category([a.uuid], sec.uuid,
                 catalogue_uuid: cat.uuid,
                 broadcast: false
               )

      refute_receive {:catalogue_data_changed, :item, _, _}
    end

    test "trash_items_in_category carries the category's catalogue as parent" do
      cat = catalogue!()
      sec = category!(cat)
      _a = item!(cat, %{category_uuid: sec.uuid})
      flush()

      assert {1, nil} = Catalogue.trash_items_in_category(sec.uuid)
      assert_receive {:catalogue_data_changed, :item, nil, parent}
      assert parent == cat.uuid
    end

    test "reorder_categories_groups emits a batch :category event" do
      cat = catalogue!()
      a = category!(cat, "A")
      b = category!(cat, "B")
      flush()

      assert :ok = Catalogue.reorder_categories_groups(cat.uuid, [{nil, [b.uuid, a.uuid]}])
      assert_receive {:catalogue_data_changed, :category, nil, parent}
      assert parent == cat.uuid
    end
  end

  describe "F13 — bulk_trash_categories broadcasts after the outer transaction commits" do
    test "one :category event per trashed category, after commit" do
      cat = catalogue!()
      a = category!(cat, "A")
      b = category!(cat, "B")
      flush()

      assert {:ok, %{categories: 2}} =
               Catalogue.bulk_trash_categories([a.uuid, b.uuid], :cascade, [])

      assert_receive {:catalogue_data_changed, :category, uuid1, parent}
      assert parent == cat.uuid
      assert_receive {:catalogue_data_changed, :category, uuid2, _}
      assert Enum.sort([uuid1, uuid2]) == Enum.sort([a.uuid, b.uuid])
    end

    test "a rolled-back batch emits nothing for the steps that had succeeded" do
      cat = catalogue!()
      other = catalogue!("Other")
      a = category!(cat, "A")
      target = category!(cat, "Target")
      foreign = category!(other, "Foreign")
      flush()

      # Step 1 (a → move into target) succeeds; step 2 (foreign → target
      # lives in another catalogue) fails and rolls the whole batch back.
      assert {:error, :cross_catalogue_move} =
               Catalogue.bulk_trash_categories(
                 [a.uuid, foreign.uuid],
                 {:move_to, target.uuid},
                 []
               )

      assert Catalogue.get_category(a.uuid).status == "active"
      refute_receive {:catalogue_data_changed, :category, _, _}
    end

    test "broadcast: false mutes the batch" do
      cat = catalogue!()
      a = category!(cat, "A")
      flush()

      assert {:ok, %{categories: 1}} =
               Catalogue.bulk_trash_categories([a.uuid], :cascade, broadcast: false)

      refute_receive {:catalogue_data_changed, :category, _, _}
    end
  end
end
