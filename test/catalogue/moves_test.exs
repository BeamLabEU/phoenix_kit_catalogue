defmodule PhoenixKitCatalogue.Catalogue.MovesTest do
  @moduledoc """
  Moving items and categories anywhere: across catalogues, under a
  parent in another catalogue, in bulk — and the refusals that keep a
  move from putting a live row somewhere no tree shows it (a trashed
  catalogue or parent, a trashed row carried along by a stale form, a
  catalogue of the other kind). Both catalogues must hear about a move.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub

  defp smart_catalogue(name), do: fixture_catalogue(%{name: name, kind: "smart"})

  defp refresh_category(%{uuid: uuid}), do: Catalogue.get_category(uuid)
  defp refresh_item(%{uuid: uuid}), do: Catalogue.get_item(uuid)

  describe "move_category_to_catalogue/3" do
    test "carries the subtree and every item, trashed ones staying trashed" do
      source = fixture_catalogue(%{name: "Source"})
      target = fixture_catalogue(%{name: "Target"})
      root = fixture_category(source, %{name: "Root"})
      child = fixture_category(source, %{name: "Child", parent_uuid: root.uuid})
      live = fixture_item(%{name: "Live", category_uuid: child.uuid})
      binned = fixture_item(%{name: "Binned", category_uuid: root.uuid})
      {:ok, _} = Catalogue.trash_item(binned)

      assert {:ok, moved} = Catalogue.move_category_to_catalogue(root, target.uuid)

      assert moved.catalogue_uuid == target.uuid
      assert moved.parent_uuid == nil
      assert refresh_category(child).catalogue_uuid == target.uuid
      assert refresh_category(child).parent_uuid == root.uuid
      assert refresh_item(live).catalogue_uuid == target.uuid
      assert refresh_item(binned).catalogue_uuid == target.uuid
      assert refresh_item(binned).status == "deleted"
    end

    test "lands under a parent of the target catalogue in one step" do
      source = fixture_catalogue(%{name: "Source"})
      target = fixture_catalogue(%{name: "Target"})
      category = fixture_category(source, %{name: "Moving"})
      parent = fixture_category(target, %{name: "Parent"})

      assert {:ok, moved} =
               Catalogue.move_category_to_catalogue(category, target.uuid,
                 parent_uuid: parent.uuid
               )

      assert moved.catalogue_uuid == target.uuid
      assert moved.parent_uuid == parent.uuid
    end

    test "refuses a parent that is trashed, missing or in another catalogue" do
      source = fixture_catalogue(%{name: "Source"})
      target = fixture_catalogue(%{name: "Target"})
      category = fixture_category(source, %{name: "Moving"})
      trashed = fixture_category(target, %{name: "Trashed parent"})
      {:ok, _} = Catalogue.trash_category(trashed)
      elsewhere = fixture_category(source, %{name: "Wrong catalogue"})

      for parent_uuid <- [trashed.uuid, elsewhere.uuid, Ecto.UUID.generate()] do
        assert {:error, :parent_not_found} =
                 Catalogue.move_category_to_catalogue(category, target.uuid,
                   parent_uuid: parent_uuid
                 )
      end

      assert refresh_category(category).catalogue_uuid == source.uuid
    end

    test "refuses a parent inside the moved subtree" do
      catalogue = fixture_catalogue(%{name: "Same"})
      root = fixture_category(catalogue, %{name: "Root"})
      child = fixture_category(catalogue, %{name: "Child", parent_uuid: root.uuid})

      assert {:error, :would_create_cycle} =
               Catalogue.move_category_to_catalogue(root, catalogue.uuid, parent_uuid: child.uuid)
    end

    test "refuses a trashed, unknown or malformed target catalogue" do
      source = fixture_catalogue(%{name: "Source"})
      trashed = fixture_catalogue(%{name: "Trashed target"})
      {:ok, _} = Catalogue.trash_catalogue(trashed)
      category = fixture_category(source, %{name: "Moving"})
      item = fixture_item(%{name: "Inside", category_uuid: category.uuid})

      for target <- [trashed.uuid, Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :catalogue_not_found} =
                 Catalogue.move_category_to_catalogue(category, target)
      end

      assert refresh_category(category).catalogue_uuid == source.uuid
      assert refresh_item(item).catalogue_uuid == source.uuid
    end

    test "refuses a catalogue of the other kind" do
      source = fixture_catalogue(%{name: "Standard"})
      smart = smart_catalogue("Smart")
      category = fixture_category(source, %{name: "Moving"})

      assert {:error, :kind_mismatch} = Catalogue.move_category_to_catalogue(category, smart.uuid)
    end

    test "refuses a trashed category" do
      source = fixture_catalogue(%{name: "Source"})
      target = fixture_catalogue(%{name: "Target"})
      category = fixture_category(source, %{name: "Binned"})
      {:ok, _} = Catalogue.trash_category(category)

      assert {:error, :not_found} = Catalogue.move_category_to_catalogue(category, target.uuid)
      assert refresh_category(category).catalogue_uuid == source.uuid
    end

    test "tells the source catalogue as well as the target" do
      source = fixture_catalogue(%{name: "Source"})
      target = fixture_catalogue(%{name: "Target"})
      category = fixture_category(source, %{name: "Moving"})
      CataloguePubSub.subscribe()

      assert {:ok, _} = Catalogue.move_category_to_catalogue(category, target.uuid)

      source_uuid = source.uuid
      target_uuid = target.uuid
      assert_receive {:catalogue_data_changed, :category, _, ^target_uuid}
      assert_receive {:catalogue_data_changed, :category, _, ^source_uuid}
      assert_receive {:catalogue_data_changed, :item, _, ^source_uuid}
    end
  end

  describe "move_category_under/3" do
    test "refuses a trashed parent" do
      catalogue = fixture_catalogue(%{name: "Tree"})
      category = fixture_category(catalogue, %{name: "Moving"})
      parent = fixture_category(catalogue, %{name: "Binned parent"})
      {:ok, _} = Catalogue.trash_category(parent)

      assert {:error, :parent_not_found} = Catalogue.move_category_under(category, parent.uuid)
      assert refresh_category(category).parent_uuid == nil
    end

    test "refuses a trashed category, in both directions" do
      catalogue = fixture_catalogue(%{name: "Tree"})
      parent = fixture_category(catalogue, %{name: "Parent"})
      category = fixture_category(catalogue, %{name: "Binned", parent_uuid: parent.uuid})
      other = fixture_category(catalogue, %{name: "Other"})
      {:ok, _} = Catalogue.trash_category(category)
      stale = refresh_category(category)

      assert {:error, :not_found} = Catalogue.move_category_under(stale, other.uuid)
      assert {:error, :not_found} = Catalogue.move_category_under(stale, nil)
      assert refresh_category(category).parent_uuid == parent.uuid
    end

    test "still promotes and nests live categories" do
      catalogue = fixture_catalogue(%{name: "Tree"})
      parent = fixture_category(catalogue, %{name: "Parent"})
      category = fixture_category(catalogue, %{name: "Moving"})

      assert {:ok, nested} = Catalogue.move_category_under(category, parent.uuid)
      assert nested.parent_uuid == parent.uuid
      assert {:ok, promoted} = Catalogue.move_category_under(nested, nil)
      assert promoted.parent_uuid == nil
    end
  end

  describe "move_item_to_category/3" do
    test "refuses a trashed item (a stale form)" do
      catalogue = fixture_catalogue(%{name: "Source"})
      other = fixture_catalogue(%{name: "Target"})
      target = fixture_category(other, %{name: "Target category"})
      item = fixture_item(%{name: "Binned", catalogue_uuid: catalogue.uuid})
      {:ok, _} = Catalogue.trash_item(item)

      assert {:error, :not_found} = Catalogue.move_item_to_category(item, target.uuid)
      assert refresh_item(item).catalogue_uuid == catalogue.uuid
    end

    test "refuses a category of the other kind" do
      standard = fixture_catalogue(%{name: "Standard"})
      smart = smart_catalogue("Smart")
      smart_category = fixture_category(smart, %{name: "Smart category"})
      item = fixture_item(%{name: "Standard item", catalogue_uuid: standard.uuid})

      assert {:error, :kind_mismatch} = Catalogue.move_item_to_category(item, smart_category.uuid)
    end

    test "a move across catalogues tells both" do
      source = fixture_catalogue(%{name: "Source"})
      other = fixture_catalogue(%{name: "Target"})
      target = fixture_category(other, %{name: "Target category"})
      item = fixture_item(%{name: "Moving", catalogue_uuid: source.uuid})
      CataloguePubSub.subscribe()

      assert {:ok, moved} = Catalogue.move_item_to_category(item, target.uuid)
      assert moved.catalogue_uuid == other.uuid

      source_uuid = source.uuid
      other_uuid = other.uuid
      assert_receive {:catalogue_data_changed, :item, _, ^other_uuid}
      assert_receive {:catalogue_data_changed, :item, nil, ^source_uuid}
    end

    test "a malformed category uuid is a not-found, not a crash" do
      item = fixture_item(%{name: "Stays"})
      assert {:error, :category_not_found} = Catalogue.move_item_to_category(item, "nope")
    end
  end

  describe "move_item_to_catalogue/3" do
    test "files a standard item uncategorized in another standard catalogue" do
      source = fixture_catalogue(%{name: "Source"})
      target = fixture_catalogue(%{name: "Target"})
      category = fixture_category(source, %{name: "Old home"})
      item = fixture_item(%{name: "Moving", category_uuid: category.uuid})
      CataloguePubSub.subscribe()

      assert {:ok, moved} = Catalogue.move_item_to_catalogue(item, target.uuid)
      assert moved.catalogue_uuid == target.uuid
      assert moved.category_uuid == nil

      source_uuid = source.uuid
      assert_receive {:catalogue_data_changed, :item, nil, ^source_uuid}
    end

    test "refuses a trashed or unknown catalogue, and one of the other kind" do
      source = fixture_catalogue(%{name: "Source"})
      trashed = fixture_catalogue(%{name: "Trashed"})
      {:ok, _} = Catalogue.trash_catalogue(trashed)
      smart = smart_catalogue("Smart")
      item = fixture_item(%{name: "Stays", catalogue_uuid: source.uuid})

      assert {:error, :catalogue_not_found} = Catalogue.move_item_to_catalogue(item, trashed.uuid)

      assert {:error, :catalogue_not_found} =
               Catalogue.move_item_to_catalogue(item, Ecto.UUID.generate())

      assert {:error, :catalogue_not_found} = Catalogue.move_item_to_catalogue(item, "nope")
      assert {:error, :kind_mismatch} = Catalogue.move_item_to_catalogue(item, smart.uuid)
      assert refresh_item(item).catalogue_uuid == source.uuid
    end

    test "refuses a trashed item" do
      source = fixture_catalogue(%{name: "Source"})
      target = fixture_catalogue(%{name: "Target"})
      item = fixture_item(%{name: "Binned", catalogue_uuid: source.uuid})
      {:ok, _} = Catalogue.trash_item(item)

      assert {:error, :not_found} = Catalogue.move_item_to_catalogue(item, target.uuid)
    end
  end

  describe "bulk_move_items/3" do
    setup do
      source = fixture_catalogue(%{name: "Bulk source"})
      target = fixture_catalogue(%{name: "Bulk target"})
      a = fixture_item(%{name: "A", catalogue_uuid: source.uuid})
      b = fixture_item(%{name: "B", catalogue_uuid: source.uuid})
      %{source: source, target: target, a: a, b: b}
    end

    test "into a category of another catalogue", %{source: source, target: target, a: a, b: b} do
      landing = fixture_category(target, %{name: "Landing"})
      CataloguePubSub.subscribe()

      assert {:ok, 2} =
               Catalogue.bulk_move_items([a.uuid, b.uuid], {:category, landing.uuid},
                 catalogue_uuid: source.uuid
               )

      for item <- [a, b] do
        assert %{catalogue_uuid: catalogue_uuid, category_uuid: category_uuid} =
                 refresh_item(item)

        assert catalogue_uuid == target.uuid
        assert category_uuid == landing.uuid
      end

      source_uuid = source.uuid
      target_uuid = target.uuid
      assert_receive {:catalogue_data_changed, :item, nil, ^target_uuid}
      assert_receive {:catalogue_data_changed, :item, nil, ^source_uuid}
    end

    test "into another catalogue without a category", %{source: source, target: target, a: a} do
      assert {:ok, 1} =
               Catalogue.bulk_move_items([a.uuid], {:catalogue, target.uuid},
                 catalogue_uuid: source.uuid
               )

      assert %{catalogue_uuid: uuid, category_uuid: nil} = refresh_item(a)
      assert uuid == target.uuid
    end

    test "uncategorizes within the same catalogue", %{source: source, a: a} do
      category = fixture_category(source, %{name: "Old"})
      {:ok, a} = Catalogue.move_item_to_category(a, category.uuid)

      assert {:ok, 1} =
               Catalogue.bulk_move_items([a.uuid], {:catalogue, source.uuid},
                 catalogue_uuid: source.uuid
               )

      assert %{catalogue_uuid: uuid, category_uuid: nil} = refresh_item(a)
      assert uuid == source.uuid
    end

    test "an item from outside the scope stops the whole move",
         %{source: source, target: target, a: a} do
      foreign = fixture_item(%{name: "Foreign", catalogue_uuid: target.uuid})

      assert {:error, :wrong_catalogue_scope} =
               Catalogue.bulk_move_items([a.uuid, foreign.uuid], {:catalogue, target.uuid},
                 catalogue_uuid: source.uuid
               )

      assert refresh_item(a).catalogue_uuid == source.uuid
    end

    test "refuses trashed, missing and other-kind destinations",
         %{source: source, target: target, a: a} do
      binned = fixture_category(target, %{name: "Binned"})
      {:ok, _} = Catalogue.trash_category(binned)
      trashed_catalogue = fixture_catalogue(%{name: "Trashed"})
      {:ok, _} = Catalogue.trash_catalogue(trashed_catalogue)
      smart = smart_catalogue("Smart")
      opts = [catalogue_uuid: source.uuid]

      assert {:error, :category_not_found} =
               Catalogue.bulk_move_items([a.uuid], {:category, binned.uuid}, opts)

      assert {:error, :category_not_found} =
               Catalogue.bulk_move_items([a.uuid], {:category, Ecto.UUID.generate()}, opts)

      assert {:error, :catalogue_not_found} =
               Catalogue.bulk_move_items([a.uuid], {:catalogue, trashed_catalogue.uuid}, opts)

      assert {:error, :kind_mismatch} =
               Catalogue.bulk_move_items([a.uuid], {:catalogue, smart.uuid}, opts)

      assert refresh_item(a).catalogue_uuid == source.uuid
    end

    test "skips trashed items and needs a scope", %{source: source, target: target, a: a, b: b} do
      {:ok, _} = Catalogue.trash_item(b)

      assert {:error, :missing_catalogue_scope} =
               Catalogue.bulk_move_items([a.uuid], {:catalogue, target.uuid}, [])

      assert {:ok, 1} =
               Catalogue.bulk_move_items([a.uuid, b.uuid], {:catalogue, target.uuid},
                 catalogue_uuid: source.uuid
               )

      assert refresh_item(b).catalogue_uuid == source.uuid
    end
  end

  describe "bulk_move_categories_to_catalogue/4" do
    test "a selected child travels inside its selected parent" do
      source = fixture_catalogue(%{name: "Source"})
      target = fixture_catalogue(%{name: "Target"})
      parent = fixture_category(source, %{name: "Parent"})
      child = fixture_category(source, %{name: "Child", parent_uuid: parent.uuid})
      loose = fixture_category(source, %{name: "Loose"})

      # All three end up in the target: the child inside its parent.
      assert {:ok, %{moved: 3, errors: []}} =
               Catalogue.bulk_move_categories_to_catalogue(
                 [child.uuid, parent.uuid, loose.uuid],
                 target.uuid,
                 nil,
                 catalogue_uuid: source.uuid
               )

      assert refresh_category(parent).catalogue_uuid == target.uuid
      assert refresh_category(child).catalogue_uuid == target.uuid
      assert refresh_category(child).parent_uuid == parent.uuid
      assert refresh_category(loose).catalogue_uuid == target.uuid
    end

    test "a selected child still moves when its selected parent cannot" do
      source = fixture_catalogue(%{name: "Source"})
      target = fixture_catalogue(%{name: "Target"})
      parent = fixture_category(source, %{name: "Binned parent"})
      child = fixture_category(source, %{name: "Live child", parent_uuid: parent.uuid})
      {:ok, _} = Catalogue.trash_category(parent, items: :cascade)
      {:ok, _} = Catalogue.restore_category(refresh_category(child))

      assert {:ok, %{moved: 1, errors: [{parent_uuid, :not_found}]}} =
               Catalogue.bulk_move_categories_to_catalogue(
                 [parent.uuid, child.uuid],
                 target.uuid,
                 nil,
                 catalogue_uuid: source.uuid
               )

      assert parent_uuid == parent.uuid
      assert refresh_category(child).catalogue_uuid == target.uuid
      assert refresh_category(parent).catalogue_uuid == source.uuid
    end

    test "lands under a parent and refuses rows outside the scope" do
      source = fixture_catalogue(%{name: "Source"})
      target = fixture_catalogue(%{name: "Target"})
      landing = fixture_category(target, %{name: "Landing"})
      mine = fixture_category(source, %{name: "Mine"})
      foreign = fixture_category(target, %{name: "Foreign"})

      assert {:ok, %{moved: 1, errors: errors}} =
               Catalogue.bulk_move_categories_to_catalogue(
                 [mine.uuid, foreign.uuid, "bad"],
                 target.uuid,
                 landing.uuid,
                 catalogue_uuid: source.uuid
               )

      assert {foreign.uuid, :wrong_catalogue_scope} in errors
      assert {"bad", :invalid_uuid} in errors
      assert refresh_category(mine).parent_uuid == landing.uuid
      assert refresh_category(foreign).parent_uuid == nil
    end

    test "the scope catalogue as target is a plain reparent" do
      catalogue = fixture_catalogue(%{name: "Same"})
      parent = fixture_category(catalogue, %{name: "Parent"})
      category = fixture_category(catalogue, %{name: "Moving"})

      assert {:ok, %{moved: 1}} =
               Catalogue.bulk_move_categories_to_catalogue(
                 [category.uuid],
                 catalogue.uuid,
                 parent.uuid,
                 catalogue_uuid: catalogue.uuid
               )

      assert refresh_category(category).parent_uuid == parent.uuid
    end
  end
end
