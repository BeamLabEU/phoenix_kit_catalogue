defmodule PhoenixKitCatalogue.Catalogue.AttributeSetsTest do
  @moduledoc """
  The attribute-sets rework (2026-08-18 design doc): provisioned
  managed blueprints, the contract, attachments, and the batched v2
  resolve. Drives the REAL entities API (path dep) — these tests are
  skipped when the entities package in use lacks the Managed contract.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  import PhoenixKitCatalogue.LiveCase, only: [fixture_item: 1]
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Test.Repo

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup do
      # Entities gates on a settings toggle (default false). The delete
      # guard normally registers from the host supervision tree; do it
      # here so the entities-side path is armed too.
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
      :ok
    end

    defp create_set!(name, kind \\ "multi") do
      {:ok, set} =
        AttributeSets.create_set(%{name: name, kind: kind}, actor_uuid: Ecto.UUID.generate())

      set
    end

    describe "set provisioning" do
      test "creates a managed blueprint with the locked contract" do
        set = create_set!("Ikea colors")

        assert set.name == "catalogue_set_ikea_colors"
        assert set.display_name == "Ikea colors"
        assert set.settings["managed_by"] == "catalogue"
        assert set.settings["catalogue"]["kind"] == "multi"
        assert {:ok, %{kind: :multi, default: nil}} = AttributeSets.contract(set)

        # Hidden from the generic entities admin listing.
        generic = PhoenixKitEntities.list_entities(include_managed: false)
        refute Enum.any?(generic, &(&1.uuid == set.uuid))

        # Visible through the catalogue's own listing.
        assert Enum.any?(AttributeSets.list_sets(), &(&1.uuid == set.uuid))
      end

      test "update_set changes kind/default through the owner bypass" do
        set = create_set!("Ikea trims", "fixed")

        {:ok, _} =
          AttributeSets.create_value(set, %{label: "Gold"}, actor_uuid: Ecto.UUID.generate())

        {:ok, updated} =
          AttributeSets.update_set(set, %{kind: "multi", default_value_slug: "gold"})

        assert {:ok, %{kind: :multi, default: "gold"}} = AttributeSets.contract(updated)

        # The same change WITHOUT the owner bypass is refused by entities.
        assert {:error, :locked_key} =
                 PhoenixKitEntities.update_entity(updated, %{
                   "settings" => put_in(updated.settings, ["catalogue", "kind"], "fixed")
                 })
      end

      test "contract rejects tampered blueprints instead of guessing" do
        set = create_set!("Ikea widths")
        broken = put_in(set.settings, ["catalogue", "kind"], "banana")
        assert {:error, :contract_broken} = AttributeSets.contract(%{set | settings: broken})
        assert {:error, :contract_broken} = AttributeSets.contract(%{settings: %{}, name: "x"})
      end
    end

    describe "values" do
      test "values are records with stable slugs, ordered" do
        set = create_set!("Ikea colors")

        {:ok, oak} =
          AttributeSets.create_value(set, %{label: "Oak"}, actor_uuid: Ecto.UUID.generate())

        {:ok, _} =
          AttributeSets.create_value(set, %{label: "Anthracite Grey"},
            actor_uuid: Ecto.UUID.generate()
          )

        assert oak.slug == "oak"
        assert [%{slug: "oak"}, %{slug: "anthracite-grey"}] = AttributeSets.list_values(set)
      end

      test "extras ride the record data" do
        set = create_set!("Ikea colors")

        {:ok, _} =
          PhoenixKitEntities.update_entity(
            set,
            %{
              "fields_definition" => [
                %{"type" => "number", "key" => "price_per_liter", "label" => "Price per liter"}
              ]
            },
            on_behalf_of: "catalogue"
          )

        set = AttributeSets.get_set(set.uuid)

        {:ok, red} =
          AttributeSets.create_value(
            set,
            %{label: "Red", extras: %{"price_per_liter" => 12}},
            actor_uuid: Ecto.UUID.generate()
          )

        assert red.data["price_per_liter"] == 12
      end
    end

    describe "attachments + resolve" do
      test "multi-set attach, order, resolve, detach — the full v2 loop" do
        colors = create_set!("Ikea colors")
        widths = create_set!("Ikea widths", "fixed")

        {:ok, _} =
          AttributeSets.create_value(colors, %{label: "Oak"}, actor_uuid: Ecto.UUID.generate())

        {:ok, _} =
          AttributeSets.create_value(colors, %{label: "White"}, actor_uuid: Ecto.UUID.generate())

        {:ok, _} =
          AttributeSets.create_value(widths, %{label: "600mm"}, actor_uuid: Ecto.UUID.generate())

        {:ok, _} = AttributeSets.update_set(colors, %{default_value_slug: "oak"})

        item = fixture_item(%{name: "Door"})
        other = fixture_item(%{name: "Panel"})

        {:ok, _} = AttributeSets.attach_set(item.uuid, colors.uuid)
        {:ok, _} = AttributeSets.attach_set(item.uuid, widths.uuid)
        {:ok, _} = AttributeSets.attach_set(other.uuid, colors.uuid)

        # Batched resolve: both items, one shape.
        resolved = AttributeSets.resolve_for_items([item.uuid, other.uuid])

        assert %{schema_version: 2, sets: [c, w]} = resolved[item.uuid]
        assert c.key == "catalogue_set_ikea_colors"
        assert c.kind == :multi
        assert c.default == "oak"
        assert [%{key: "oak", label: "Oak"}, %{key: "white"}] = c.values
        assert w.kind == :fixed

        assert %{sets: [%{key: "catalogue_set_ikea_colors"}]} = resolved[other.uuid]

        # Reorder flips the item's set order.
        :ok = AttributeSets.reorder_attachments(item.uuid, [widths.uuid, colors.uuid])
        assert %{sets: [first, _]} = AttributeSets.resolve_for_item(item.uuid)
        assert first.key == "catalogue_set_ikea_widths"

        # Attached sets refuse deletion (catalogue and entities paths).
        assert {:error, :set_in_use} = AttributeSets.delete_set(colors)

        # Detach frees it.
        :ok = AttributeSets.detach_set(item.uuid, colors.uuid)
        :ok = AttributeSets.detach_set(other.uuid, colors.uuid)
        assert {:ok, _} = AttributeSets.delete_set(colors)
      end

      test "attach is idempotent and validates the set exists" do
        set = create_set!("Ikea trims")
        item = fixture_item(%{name: "Door"})

        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        assert length(AttributeSets.list_attachments(item.uuid)) == 1

        assert {:error, :set_not_found} =
                 AttributeSets.attach_set(item.uuid, Ecto.UUID.generate())
      end

      test "orphan pruning clears attachments to vanished blueprints" do
        set = create_set!("Ikea handles")
        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

        # Simulate an out-of-band blueprint delete (repo-level, bypassing
        # the guard) — the PubSub cleanup path prunes the orphan row.
        Repo.delete!(set)
        assert AttributeSets.prune_orphan_attachments(set.uuid) == 1
        assert AttributeSets.list_attachments(item.uuid) == []
      end
    end

    describe "migration from groups" do
      test "explodes groups into sets, preserves keys, is idempotent" do
        actor = Ecto.UUID.generate()

        {:ok, group} = Catalogue.create_attribute_group(%{name: "Ikea doors"})
        {:ok, color} = Catalogue.create_attribute(group, %{"name" => "Color", "kind" => "multi"})
        {:ok, oak} = Catalogue.create_attribute_value(color, %{"value" => "Oak"})
        {:ok, _} = Catalogue.create_attribute_value(color, %{"value" => "White"})
        {:ok, _} = Catalogue.set_default_value(oak)
        {:ok, trim} = Catalogue.create_attribute(group, %{"name" => "Trim", "kind" => "fixed"})
        {:ok, _} = Catalogue.create_attribute_value(trim, %{"value" => "Gold"})

        item = fixture_item(%{name: "Door"})
        {:ok, _} = Catalogue.set_item_attribute_group(item, group.uuid)

        assert {:ok, %{sets: 2, values: 3, attachments: 2}} =
                 AttributeSets.migrate_groups_to_sets(actor_uuid: actor)

        # The item now resolves BOTH sets, keys preserved from the old
        # attribute/value keys so order-line picks keep working.
        %{sets: sets} = AttributeSets.resolve_for_item(item.uuid)
        assert length(sets) == 2

        color_set = Enum.find(sets, &(&1.kind == :multi))
        assert color_set.default == oak.key

        assert Enum.map(color_set.values, & &1.key) |> Enum.sort() ==
                 Enum.sort([oak.key | ["white"]])

        # Idempotent: nothing new on a re-run.
        assert {:ok, %{sets: 0, values: 0, attachments: 0}} =
                 AttributeSets.migrate_groups_to_sets(actor_uuid: actor)
      end
    end

    describe "disabled entities" do
      test "every entry point degrades loudly, none crash" do
        PhoenixKit.Settings.update_setting("entities_enabled", "false")

        assert {:error, :entities_disabled} = AttributeSets.create_set(%{name: "X"})
        assert AttributeSets.list_sets() == []
        assert AttributeSets.get_set(Ecto.UUID.generate()) == nil
        assert AttributeSets.resolve_for_items([Ecto.UUID.generate()]) == %{}
        assert Catalogue.resolve_attribute_sets_for_item(Ecto.UUID.generate()).sets == []
      end
    end
  else
    @tag :skip
    test "entities package lacks the Managed contract — suite skipped" do
      assert true
    end
  end
end
