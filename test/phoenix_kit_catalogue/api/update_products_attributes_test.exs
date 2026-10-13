defmodule PhoenixKitCatalogue.API.UpdateProductsAttributesTest do
  @moduledoc "`update_products` with attribute values: validated before any write."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.ApiCase

  @tool "catalogue.update_products"

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Update colors"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
      {:ok, blue} = Catalogue.create_attribute_set_value(set, %{label: "Blue"})
      catalogue = fixture_catalogue(%{name: "Update Attr Cat"})
      item = fixture_item(%{name: "Colourful", catalogue_uuid: catalogue.uuid})
      %{catalogue: catalogue, item: item, set: set, red: red, blue: blue}
    end

    defp run_update(ctx, changes),
      do:
        ApiCase.call(@tool, %{
          "catalogue_id" => ctx.catalogue.uuid,
          "items" => [%{"ref" => %{"id" => ctx.item.uuid}, "changes" => changes}]
        })

    test "attaches the set, replaces the selection, and an attributes-only change counts as updated",
         ctx do
      assert {:ok, %{"results" => [%{"action" => "updated"}]}} =
               run_update(ctx, %{
                 "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
               })

      assert PhoenixKitCatalogue.API.Attributes.selection(ctx.item.uuid, ctx.set.uuid) == [
               ctx.red.slug
             ]

      assert {:ok, %{"results" => [%{"action" => "updated"}]}} =
               run_update(ctx, %{
                 "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.blue.slug]}]
               })

      assert PhoenixKitCatalogue.API.Attributes.selection(ctx.item.uuid, ctx.set.uuid) == [
               ctx.blue.slug
             ]
    end

    test "re-sending the current selection is unchanged, not updated", ctx do
      input = %{"attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]}
      assert {:ok, %{"results" => [%{"action" => "updated"}]}} = run_update(ctx, input)

      # the same selection again: nothing changed
      assert {:ok, %{"results" => [%{"action" => "unchanged"}], "summary" => %{"unchanged" => 1}}} =
               run_update(ctx, input)
    end

    test "an unknown value rejects the whole row before anything is written", ctx do
      assert {:ok, %{"results" => [row]}} =
               run_update(ctx, %{
                 "name" => "Renamed",
                 "attributes" => [%{"set_id" => ctx.set.uuid, "values" => ["nope"]}]
               })

      assert row["action"] == "error"
      assert row["error"]["code"] == "validation_failed"
      assert row["error"]["context"]["unknown"] == ["nope"]
      assert Catalogue.get_item!(ctx.item.uuid).name == "Colourful"
      assert Catalogue.list_attribute_set_attachments(ctx.item.uuid) == []
    end

    test "a dry run shows the selection that would change", ctx do
      {:ok, _} = Catalogue.attach_attribute_set(ctx.item.uuid, ctx.set.uuid)
      :ok = Catalogue.set_attribute_set_selection(ctx.item.uuid, ctx.set.uuid, [ctx.red.slug])

      assert {:preview, %{"rows" => [row]}, _} =
               ApiCase.call(
                 @tool,
                 %{
                   "catalogue_id" => ctx.catalogue.uuid,
                   "items" => [
                     %{
                       "ref" => %{"id" => ctx.item.uuid},
                       "changes" => %{
                         "attributes" => [
                           %{"set_id" => ctx.set.uuid, "values" => [ctx.blue.slug]}
                         ]
                       }
                     }
                   ]
                 },
                 %{dry_run?: true}
               )

      assert row["changes"]["attributes." <> ctx.set.uuid] == %{
               "from" => ctx.red.slug,
               "to" => ctx.blue.slug
             }

      assert PhoenixKitCatalogue.API.Attributes.selection(ctx.item.uuid, ctx.set.uuid) == [
               ctx.red.slug
             ]
    end

    test "attribute writes announce no per-item event, only the one bulk event", ctx do
      :ok = PubSub.subscribe()
      flush()

      assert {:ok, %{"results" => [%{"action" => "updated", "id" => id}]}} =
               run_update(ctx, %{
                 "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
               })

      cat_uuid = ctx.catalogue.uuid
      assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, [^id], _from}
      refute_receive {:catalogue_data_changed, :item, ^id, _}, 100
      assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    end

    defp flush do
      receive do
        _ -> flush()
      after
        0 -> :ok
      end
    end
  end
end
