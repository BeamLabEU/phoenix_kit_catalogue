defmodule PhoenixKitCatalogue.ApiActivityTest do
  @moduledoc """
  What the shop API adds to the change log (spec 4.7): who wrote it, how, and
  what moved, down to `data` sub-paths and per-language slugs.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ActivityLog
  alias PhoenixKitCatalogue.Schemas.Item

  @actor "00000000-0000-7000-8000-000000000001"
  @meta %{
    "via" => "api",
    "key_prefix" => "abcd1234",
    "request_id" => "req-1",
    "tool" => "catalogue.update_products"
  }

  defp opts(extra \\ []),
    do: Keyword.merge([actor_uuid: @actor, mode: "auto", log_metadata: @meta], extra)

  describe "ActivityLog.with_changes/5" do
    test "reports a data path that moved, as data.<path>" do
      before = %Item{data: %{"ecommerce" => %{"compare_at_price" => "10", "tags" => ["a"]}}}
      now = %Item{data: %{"ecommerce" => %{"compare_at_price" => "12", "tags" => ["a"]}}}

      paths = [["ecommerce", "compare_at_price"], ["ecommerce", "tags"]]

      assert %{"changes" => changes} = ActivityLog.with_changes(%{}, before, now, [], paths)
      assert changes == %{"data.ecommerce.compare_at_price" => %{"from" => "10", "to" => "12"}}
    end

    test "a path that appears or disappears reads as blank on the missing side" do
      before = %Item{data: %{}}
      now = %Item{data: %{"api" => %{"external_id" => "X-1"}}}

      assert %{"changes" => %{"data.api.external_id" => %{"from" => "", "to" => "X-1"}}} =
               ActivityLog.with_changes(%{}, before, now, [], [["api", "external_id"]])

      assert %{"changes" => %{"data.api.external_id" => %{"from" => "X-1", "to" => ""}}} =
               ActivityLog.with_changes(%{}, now, before, [], [["api", "external_id"]])
    end

    test "a map or list leaf is written as JSON and a long one is clipped" do
      before = %Item{data: %{}}
      long = String.duplicate("x", 800)

      now = %Item{
        data: %{"ecommerce" => %{"price_modifiers" => %{"size" => %{"L" => "5"}}, "note" => long}}
      }

      paths = [["ecommerce", "price_modifiers"], ["ecommerce", "note"]]
      assert %{"changes" => changes} = ActivityLog.with_changes(%{}, before, now, [], paths)

      assert changes["data.ecommerce.price_modifiers"]["to"] == ~s({"size":{"L":"5"}})
      assert String.length(changes["data.ecommerce.note"]["to"]) == 501
      assert String.ends_with?(changes["data.ecommerce.note"]["to"], "…")
    end

    test "an untouched data path adds nothing" do
      item = %Item{data: %{"ecommerce" => %{"compare_at_price" => "10"}}}

      assert ActivityLog.with_changes(%{"name" => "n"}, item, item, [], [
               ["ecommerce", "compare_at_price"]
             ]) == %{"name" => "n"}
    end

    test "slug is reported per language" do
      before = %Item{slug: %{"en-US" => "old", "de-DE" => "alt"}}
      now = %Item{slug: %{"en-US" => "new", "de-DE" => "alt", "fr-FR" => "nouveau"}}

      assert %{"changes" => changes} = ActivityLog.with_changes(%{}, before, now, [:slug])

      assert changes == %{
               "slug.en-US" => %{"from" => "old", "to" => "new"},
               "slug.fr-FR" => %{"from" => "", "to" => "nouveau"}
             }
    end
  end

  describe "ActivityLog.with_extra/2" do
    test "the entry's own keys win over the extra ones" do
      assert ActivityLog.with_extra(%{"name" => "real"}, %{"name" => "evil", "via" => "api"}) ==
               %{"name" => "real", "via" => "api"}
    end

    test "nil and an empty map change nothing" do
      assert ActivityLog.with_extra(%{"a" => 1}, nil) == %{"a" => 1}
      assert ActivityLog.with_extra(%{"a" => 1}, %{}) == %{"a" => 1}
    end
  end

  describe "log_metadata reaches the entry" do
    test "update_item/3 carries it and keeps its own keys and diff" do
      item = fixture_item(%{name: "Old"})

      {:ok, updated} =
        Catalogue.update_item(
          item,
          %{name: "New"},
          opts(log_metadata: Map.put(@meta, "name", "evil"))
        )

      row =
        assert_activity_logged("item.updated", resource_uuid: updated.uuid, actor_uuid: @actor)

      assert row.mode == "auto"
      assert row.metadata["via"] == "api"
      assert row.metadata["key_prefix"] == "abcd1234"
      assert row.metadata["tool"] == "catalogue.update_products"
      assert row.metadata["name"] == "New"
      assert row.metadata["changes"]["name"] == %{"from" => "Old", "to" => "New"}
    end

    test "without the option the entry has exactly the keys it had before" do
      item = fixture_item(%{name: "Old"})
      {:ok, updated} = Catalogue.update_item(item, %{name: "New"}, actor_uuid: @actor)

      row = assert_activity_logged("item.updated", resource_uuid: updated.uuid)
      assert row.mode == "manual"
      assert row.metadata |> Map.keys() |> Enum.sort() == ["changes", "name", "sku"]
    end

    test "a slug change leaves the old slug in the diff" do
      item = fixture_item(%{name: "Vase", slug: %{"en-US" => "old-vase"}})
      {:ok, updated} = Catalogue.update_item(item, %{slug: %{"en-US" => "new-vase"}}, opts())

      row = assert_activity_logged("item.updated", resource_uuid: updated.uuid)

      assert row.metadata["changes"]["slug.en-US"] ==
               %{"from" => "old-vase", "to" => "new-vase"}
    end

    test "create_item/2, trash_item/2 and restore_item/2 carry it" do
      catalogue = fixture_catalogue(%{name: "Meta Cat"})

      {:ok, item} =
        Catalogue.create_item(%{name: "Fresh", catalogue_uuid: catalogue.uuid}, opts())

      {:ok, trashed} = Catalogue.trash_item(item, opts())
      {:ok, _} = Catalogue.restore_item(trashed, opts())

      for action <- ~w(item.created item.trashed item.restored) do
        row = assert_activity_logged(action, resource_uuid: item.uuid, actor_uuid: @actor)
        assert row.metadata["via"] == "api", "#{action} lost the metadata"
        assert row.metadata["name"] == "Fresh"
        assert row.mode == "auto", "#{action} lost the mode"
      end
    end

    test "create_category/2 and update_category/3 carry it" do
      catalogue = fixture_catalogue(%{name: "Meta Cat 2"})

      {:ok, category} =
        Catalogue.create_category(%{name: "Shelf", catalogue_uuid: catalogue.uuid}, opts())

      {:ok, _} = Catalogue.update_category(category, %{name: "Shelf 2"}, opts())

      for action <- ~w(category.created category.updated) do
        row = assert_activity_logged(action, resource_uuid: category.uuid)
        assert row.metadata["via"] == "api", "#{action} lost the metadata"
      end
    end

    test "move_item_to_category/3 carries it" do
      catalogue = fixture_catalogue(%{name: "Meta Cat 3"})
      category = fixture_category(catalogue, %{name: "Target"})
      item = fixture_item(%{name: "Mover", catalogue_uuid: catalogue.uuid})

      {:ok, _} = Catalogue.move_item_to_category(item, category.uuid, opts())

      row = assert_activity_logged("item.moved", resource_uuid: item.uuid)
      assert row.metadata["via"] == "api"
      assert row.mode == "auto"
    end

    test "trash_item/2 honours broadcast: false" do
      catalogue = fixture_catalogue(%{name: "Quiet Cat"})
      {:ok, item} = Catalogue.create_item(%{name: "Quiet", catalogue_uuid: catalogue.uuid})
      :ok = PhoenixKitCatalogue.Catalogue.PubSub.subscribe()
      flush_pubsub()

      {:ok, _} = Catalogue.trash_item(item, broadcast: false)

      refute_receive {:catalogue_data_changed, :item, _, _}, 100
    end
  end

  describe "ActivityLog.log_many/1" do
    test "stores every entry under the catalogue module" do
      assert :ok =
               ActivityLog.log_many([
                 %{
                   action: "item.updated",
                   mode: "auto",
                   resource_type: "item",
                   metadata: %{"n" => 1}
                 },
                 %{
                   action: "item.updated",
                   mode: "auto",
                   resource_type: "item",
                   metadata: %{"n" => 2}
                 }
               ])

      rows = Enum.filter(list_activities(), &(&1.action == "item.updated"))
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.module == "catalogue"))
    end

    test "an empty batch is a no-op" do
      before = list_activities()

      assert :ok = ActivityLog.log_many([])
      assert list_activities() == before
    end
  end

  defp flush_pubsub do
    receive do
      {:catalogue_data_changed, _, _, _} -> flush_pubsub()
    after
      0 -> :ok
    end
  end
end
