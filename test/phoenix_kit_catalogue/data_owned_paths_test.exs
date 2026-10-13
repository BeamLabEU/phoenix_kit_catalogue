defmodule PhoenixKitCatalogue.DataOwnedPathsTest do
  @moduledoc """
  `update_item/3` / `update_category/3` option `:data_owned_paths`: a deep
  merge of named `data` sub-paths into the row as it is now, under a row lock,
  so a concurrent writer of a sibling key loses nothing.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue

  @actor "00000000-0000-7000-8000-000000000001"
  @compare [["ecommerce", "compare_at_price"]]

  setup do
    catalogue = fixture_catalogue(%{name: "Paths Cat"})

    item =
      fixture_item(%{
        name: "Base",
        catalogue_uuid: catalogue.uuid,
        data: %{
          "ecommerce" => %{"shopify" => %{"id" => "1"}, "tags" => ["a"]},
          "meta" => %{"color" => "red"}
        }
      })

    %{catalogue: catalogue, item: item}
  end

  describe "update_item/3 with :data_owned_paths" do
    test "writes only the named path and keeps every sibling key", %{item: item} do
      attrs = %{data: %{"ecommerce" => %{"compare_at_price" => "9.50"}}}

      assert {:ok, updated} = Catalogue.update_item(item, attrs, data_owned_paths: @compare)

      assert updated.data["ecommerce"] == %{
               "shopify" => %{"id" => "1"},
               "tags" => ["a"],
               "compare_at_price" => "9.50"
             }

      assert updated.data["meta"] == %{"color" => "red"}
      assert Catalogue.get_item(item.uuid).data == updated.data
    end

    test "a stale copy cannot clobber what another writer stored since", %{item: item} do
      stale = Catalogue.get_item!(item.uuid)

      # the Shopify sync writes its own keys after `stale` was read
      {:ok, _} =
        Catalogue.update_item(item, %{
          data: %{"ecommerce" => %{"shopify" => %{"id" => "2"}, "tags" => ["new"]}}
        })

      attrs = %{data: %{"ecommerce" => %{"compare_at_price" => "9.50"}}}
      assert {:ok, updated} = Catalogue.update_item(stale, attrs, data_owned_paths: @compare)

      assert updated.data["ecommerce"] == %{
               "shopify" => %{"id" => "2"},
               "tags" => ["new"],
               "compare_at_price" => "9.50"
             }
    end

    test "the update is applied to the fresh row, so the logged from-value is the real one",
         %{item: item} do
      stale = Catalogue.get_item!(item.uuid)
      {:ok, _} = Catalogue.update_item(item, %{name: "Renamed by someone else"})

      {:ok, updated} = Catalogue.update_item(stale, %{name: "Mine"}, data_owned_paths: [])

      assert updated.name == "Mine"

      # Two `item.updated` rows exist for this item now (the rename by someone
      # else, then ours), and `assert_activity_logged/2` flunks unless exactly
      # one row matches: select ours by its diff instead.
      ours =
        list_activities()
        |> Enum.filter(
          &(&1.action == "item.updated" and &1.resource_uuid == Ecto.UUID.dump!(item.uuid))
        )
        |> Enum.filter(&(get_in(&1.metadata, ["changes", "name", "to"]) == "Mine"))

      assert [row] = ours

      assert row.metadata["changes"]["name"] == %{
               "from" => "Renamed by someone else",
               "to" => "Mine"
             }
    end

    test "a nil leaf deletes the key and prunes the maps it empties", %{item: item} do
      {:ok, with_id} =
        Catalogue.update_item(item, %{data: %{"api" => %{"external_id" => "X-1"}}},
          data_owned_paths: [["api", "external_id"]]
        )

      assert with_id.data["api"] == %{"external_id" => "X-1"}

      {:ok, cleared} =
        Catalogue.update_item(with_id, %{data: %{"api" => %{"external_id" => nil}}},
          data_owned_paths: [["api", "external_id"]]
        )

      refute Map.has_key?(cleared.data, "api")
      assert cleared.data["ecommerce"]["shopify"] == %{"id" => "1"}
    end

    test "keys outside the owned paths are ignored even when attrs carries them", %{item: item} do
      attrs = %{
        data: %{
          "ecommerce" => %{"compare_at_price" => "5", "shopify" => %{"id" => "evil"}},
          "meta" => %{"color" => "blue"}
        }
      }

      {:ok, updated} = Catalogue.update_item(item, attrs, data_owned_paths: @compare)

      assert updated.data["ecommerce"]["shopify"] == %{"id" => "1"}
      assert updated.data["ecommerce"]["compare_at_price"] == "5"
      assert updated.data["meta"] == %{"color" => "red"}
    end

    test ":slug_owned_langs merges only the named languages into the locked row's slug map",
         %{item: item} do
      {:ok, with_slugs} =
        Catalogue.update_item(item, %{slug: %{"en-US" => "base", "de-DE" => "basis"}})

      stale = Catalogue.get_item!(item.uuid)

      # Another writer (the sweep, the item form, a second API call) stores a slug for a
      # DIFFERENT language after our read.
      {:ok, _} =
        Catalogue.update_item(with_slugs, %{
          slug: %{"en-US" => "base", "de-DE" => "basis", "fr-FR" => "base-fr"}
        })

      opts = [data_owned_paths: [], slug_owned_langs: ["de-DE"]]
      assert {:ok, updated} = Catalogue.update_item(stale, %{slug: %{"de-DE" => "neu"}}, opts)

      # The stale copy knew nothing of "fr-FR"; it survives. Only "de-DE" took our value.
      assert updated.slug == %{"en-US" => "base", "de-DE" => "neu", "fr-FR" => "base-fr"}

      # A blank or absent value for an owned language deletes just that language.
      assert {:ok, cleared} = Catalogue.update_item(updated, %{slug: %{}}, opts)
      assert cleared.slug == %{"en-US" => "base", "fr-FR" => "base-fr"}

      assert [log] =
               list_activities()
               |> Enum.filter(
                 &(&1.action == "item.updated" and &1.resource_uuid == Ecto.UUID.dump!(item.uuid))
               )
               |> Enum.filter(&(get_in(&1.metadata, ["changes", "slug.de-DE", "to"]) == ""))

      assert log.metadata["changes"]["slug.de-DE"] == %{"from" => "neu", "to" => ""}
    end

    test ":slug_owned_langs without :data_owned_paths, or with a bad value, raises", %{item: item} do
      assert_raise ArgumentError, ~r/needs :data_owned_paths/, fn ->
        Catalogue.update_item(item, %{slug: %{}}, slug_owned_langs: ["de-DE"])
      end

      for bad <- [["", "de-DE"], [:de], "de-DE"] do
        assert_raise ArgumentError, ~r/slug_owned_langs/, fn ->
          Catalogue.update_item(item, %{slug: %{}}, data_owned_paths: [], slug_owned_langs: bad)
        end
      end
    end

    test "an owned path missing from attrs is left alone", %{item: item} do
      assert {:ok, updated} =
               Catalogue.update_item(item, %{description: "only this"},
                 data_owned_paths: @compare
               )

      assert updated.description == "only this"
      assert updated.data == item.data
    end

    test "logged_data_paths and log_metadata land in the entry", %{item: item} do
      meta = %{"via" => "api", "key_prefix" => "abcd1234"}

      {:ok, _} =
        Catalogue.update_item(item, %{data: %{"ecommerce" => %{"compare_at_price" => "9.50"}}},
          data_owned_paths: @compare,
          logged_data_paths: @compare ++ [["ecommerce", "tags"]],
          log_metadata: meta,
          actor_uuid: @actor
        )

      row = assert_activity_logged("item.updated", resource_uuid: item.uuid, actor_uuid: @actor)
      assert row.metadata["via"] == "api"

      # tags did not move, so it is not in the diff
      assert row.metadata["changes"] == %{
               "data.ecommerce.compare_at_price" => %{"from" => "", "to" => "9.50"}
             }
    end

    test "returns :not_found when the row is gone", %{item: item} do
      {:ok, _} = Catalogue.permanently_delete_item(item)

      assert {:error, :not_found} =
               Catalogue.update_item(item, %{name: "Ghost"}, data_owned_paths: [])
    end

    test "refuses :data_owned_keys together with :data_owned_paths", %{item: item} do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        Catalogue.update_item(item, %{}, data_owned_keys: ["meta"], data_owned_paths: @compare)
      end
    end

    test "refuses malformed paths", %{item: item} do
      for bad <- [[["_trash"]], [[]], [[""]], [["a", 1]], "ecommerce", [["ok"], "no"]] do
        assert_raise ArgumentError, ~r/data_owned_paths/, fn ->
          Catalogue.update_item(item, %{}, data_owned_paths: bad)
        end
      end
    end

    test "without the option data is still replaced wholesale", %{item: item} do
      {:ok, updated} = Catalogue.update_item(item, %{data: %{"only" => "this"}})
      assert updated.data == %{"only" => "this"}
    end
  end

  describe "update_category/3 with :data_owned_paths" do
    test "sets the external id and keeps the other data", %{catalogue: catalogue} do
      category = fixture_category(catalogue, %{name: "Shelf", data: %{"meta" => %{"k" => "v"}}})

      {:ok, updated} =
        Catalogue.update_category(category, %{data: %{"api" => %{"external_id" => "C-1"}}},
          data_owned_paths: [["api", "external_id"]],
          logged_data_paths: [["api", "external_id"]],
          log_metadata: %{"via" => "api"},
          actor_uuid: @actor
        )

      assert updated.data == %{"meta" => %{"k" => "v"}, "api" => %{"external_id" => "C-1"}}

      row = assert_activity_logged("category.updated", resource_uuid: category.uuid)
      assert row.metadata["via"] == "api"

      assert row.metadata["changes"]["data.api.external_id"] ==
               %{"from" => "", "to" => "C-1"}
    end

    test "returns :not_found when the category is gone", %{catalogue: catalogue} do
      category = fixture_category(catalogue, %{name: "Gone"})
      {:ok, _} = Catalogue.permanently_delete_category(category)

      assert {:error, :not_found} =
               Catalogue.update_category(category, %{name: "x"}, data_owned_paths: [])
    end
  end

  describe "preview_item_update/3" do
    test "reports the diff and writes nothing", %{item: item} do
      attrs = %{name: "New name", data: %{"ecommerce" => %{"compare_at_price" => "5"}}}

      assert {:ok, changes} =
               Catalogue.preview_item_update(item, attrs,
                 data_owned_paths: @compare,
                 logged_data_paths: @compare
               )

      assert changes == %{
               "name" => %{"from" => "Base", "to" => "New name"},
               "data.ecommerce.compare_at_price" => %{"from" => "", "to" => "5"}
             }

      assert Catalogue.get_item(item.uuid).name == "Base"
      assert list_activities() |> Enum.filter(&(&1.action == "item.updated")) == []
    end

    test "an update that changes nothing previews as an empty map", %{item: item} do
      assert {:ok, changes} = Catalogue.preview_item_update(item, %{name: "Base"})
      assert changes == %{}
    end

    test "an invalid update returns the changeset", %{item: item} do
      assert {:error, %Ecto.Changeset{valid?: false}} =
               Catalogue.preview_item_update(item, %{name: ""})
    end
  end
end
