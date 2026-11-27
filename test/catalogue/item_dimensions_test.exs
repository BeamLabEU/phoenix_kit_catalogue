defmodule PhoenixKitCatalogue.Catalogue.ItemDimensionsTest do
  @moduledoc """
  The V7 fields through the context: dimensions and pack size on an item,
  the area and volume Postgres derives, the cost unit and pack size on a
  supplier row, and `create_item/2` inside a caller's transaction.
  """
  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Schemas.Item

  defp d(value), do: Decimal.new(value)

  defp same?(%Decimal{} = a, b), do: Decimal.equal?(a, d(b))

  setup do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Sheet goods"})
    %{catalogue: catalogue}
  end

  defp plywood(catalogue, attrs \\ %{}) do
    Catalogue.create_item(
      Map.merge(
        %{
          name: "Birch plywood 18 mm",
          catalogue_uuid: catalogue.uuid,
          unit: "sheet",
          length_mm: 2500,
          width_mm: 1250,
          thickness_mm: 18,
          pack_size: 40
        },
        attrs
      )
    )
  end

  describe "create_item/2 and update_item/3" do
    test "one call creates the whole specification, area and volume included", %{catalogue: c} do
      assert {:ok, item} = plywood(c)

      assert same?(item.length_mm, 2500)
      assert same?(item.width_mm, 1250)
      assert same?(item.thickness_mm, 18)
      assert same?(item.pack_size, 40)
      # What Postgres generated comes back on the struct…
      assert same?(item.area_m2, "3.125")
      assert same?(item.volume_m3, "0.05625")
      # …and is what the pure functions compute.
      assert Decimal.equal?(item.area_m2, Item.area_m2(item))
      assert Decimal.equal?(item.volume_m3, Item.volume_m3(item))

      reloaded = Catalogue.get_item(item.uuid)
      assert same?(reloaded.volume_m3, "0.05625")
    end

    test "the stored and the computed values agree across a range of sizes", %{catalogue: c} do
      for {l, w, t} <- [
            {"2500", "1250", "6.5"},
            {"1525", "1525", "9"},
            {"3050", "1525", "21"},
            {"2440.5", "1220.25", "0.7"},
            {"0.001", "0.001", "0.001"}
          ] do
        assert {:ok, item} = plywood(c, %{length_mm: l, width_mm: w, thickness_mm: t})
        assert Decimal.equal?(item.area_m2, Item.area_m2(item)), "#{l} × #{w}"
        assert Decimal.equal?(item.volume_m3, Item.volume_m3(item)), "#{l} × #{w} × #{t}"
      end
    end

    test "dimensions are stored as given: cross grain is not turned into long grain",
         %{catalogue: c} do
      assert {:ok, cross} = plywood(c, %{length_mm: 1250, width_mm: 2500})
      assert same?(cross.length_mm, 1250)
      assert same?(cross.width_mm, 2500)

      reloaded = Catalogue.get_item(cross.uuid)
      assert same?(reloaded.length_mm, 1250)
      assert same?(reloaded.width_mm, 2500)
    end

    test "6.5 mm keeps its precision", %{catalogue: c} do
      assert {:ok, item} = plywood(c, %{thickness_mm: "6.5"})
      assert same?(Catalogue.get_item(item.uuid).thickness_mm, "6.5")
      assert same?(item.volume_m3, "0.0203125")
    end

    test "every new field is optional", %{catalogue: c} do
      assert {:ok, item} = Catalogue.create_item(%{name: "Hinge", catalogue_uuid: c.uuid})
      assert item.length_mm == nil
      assert item.pack_size == nil
      assert item.area_m2 == nil
      assert item.volume_m3 == nil
    end

    test "an update recomputes the volume, and clearing a dimension clears it", %{catalogue: c} do
      {:ok, item} = plywood(c)

      assert {:ok, thicker} = Catalogue.update_item(item, %{thickness_mm: 21})
      assert same?(thicker.volume_m3, "0.065625")

      assert {:ok, flat} = Catalogue.update_item(thicker, %{thickness_mm: nil})
      assert flat.volume_m3 == nil
      assert same?(flat.area_m2, "3.125")
    end

    test "zero and negative values are refused", %{catalogue: c} do
      for field <- [:length_mm, :width_mm, :thickness_mm, :pack_size], value <- [0, -1] do
        assert {:error, changeset} = plywood(c, %{field => value})
        assert %{^field => ["must be greater than 0"]} = errors_on(changeset)
      end
    end

    test "the area and volume cannot be set from attrs", %{catalogue: c} do
      assert {:ok, item} = plywood(c, %{area_m2: 99, volume_m3: 99})
      assert same?(item.area_m2, "3.125")
      assert same?(item.volume_m3, "0.05625")
    end

    test "a saved item converts", %{catalogue: c} do
      {:ok, item} = plywood(c)
      assert {:ok, m3} = Catalogue.convert(item, 1000, "sheet", "m3")
      assert same?(m3, "56.25")
      assert {:ok, sheets} = Catalogue.convert(item, "56.25", "m3", "sheet")
      assert same?(sheets, 1000)
    end

    test "a host can sum volumes in SQL", %{catalogue: c} do
      {:ok, a} = plywood(c)
      {:ok, b} = plywood(c, %{thickness_mm: "6.5"})

      total =
        Repo.one(
          from(i in Item,
            where: i.uuid in ^[a.uuid, b.uuid],
            select: sum(i.volume_m3 * 1000)
          )
        )

      # 1000 × (0.05625 + 0.0203125)
      assert same?(total, "76.5625")

      by_thickness =
        Repo.all(
          from(i in Item,
            where: i.uuid in ^[a.uuid, b.uuid],
            order_by: i.thickness_mm,
            select: i.uuid
          )
        )

      assert by_thickness == [b.uuid, a.uuid]
    end

    test "a duplicate keeps the dimensions and the pack size", %{catalogue: c} do
      {:ok, item} = plywood(c)
      assert {:ok, copy} = Catalogue.duplicate_item(item)
      copy = Catalogue.get_item(copy.uuid)

      assert same?(copy.length_mm, 2500)
      assert same?(copy.thickness_mm, 18)
      assert same?(copy.pack_size, 40)
      assert same?(copy.volume_m3, "0.05625")
    end
  end

  describe "supplier info" do
    defp supplier_info(item, attrs) do
      Catalogue.create_supplier_info(
        Map.merge(
          %{item_uuid: item.uuid, supplier_uuid: UUIDv7.generate(), supplier_source: "local"},
          attrs
        )
      )
    end

    test "a cost per m³ with the supplier's own pack", %{catalogue: c} do
      {:ok, item} = plywood(c)

      assert {:ok, info} =
               supplier_info(item, %{
                 unit_cost: 830,
                 currency: "EUR",
                 cost_unit: "m3",
                 pack_size: 35
               })

      info = Catalogue.get_supplier_info(info.uuid)
      assert info.cost_unit == "m3"
      assert same?(info.pack_size, 35)

      assert {:ok, per_sheet} = Catalogue.supplier_cost_per(item, info, "sheet")
      assert same?(per_sheet, "46.6875")

      assert {:ok, per_pack} = Catalogue.supplier_cost_per(item, info, "pack")
      assert same?(per_pack, "1634.0625")

      assert {:ok, pack_m3} = Catalogue.convert(item, 1, "pack", "m3", supplier_info: info)
      assert same?(pack_m3, "1.96875")
    end

    test "both are optional; an unknown cost unit and a zero pack are refused", %{catalogue: c} do
      {:ok, item} = plywood(c)

      assert {:ok, info} = supplier_info(item, %{unit_cost: 46})
      assert info.cost_unit == nil
      assert info.pack_size == nil

      assert {:error, changeset} = supplier_info(item, %{cost_unit: "pallet"})
      assert %{cost_unit: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} = supplier_info(item, %{pack_size: 0})
      assert %{pack_size: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "a price revision keeps the cost unit and the pack size", %{catalogue: c} do
      {:ok, item} = plywood(c)

      {:ok, info} =
        supplier_info(item, %{unit_cost: 830, currency: "EUR", cost_unit: "m3", pack_size: 35})

      assert {:ok, successor} = Catalogue.revise_supplier_info_cost(info, Decimal.new(850))

      assert successor.uuid != info.uuid
      assert successor.cost_unit == "m3"
      assert same?(successor.pack_size, 35)
      assert same?(successor.unit_cost, 850)
    end
  end

  describe "create_item/2 inside the caller's transaction" do
    test "a rollback leaves no item and no activity entry", %{catalogue: c} do
      test_pid = self()

      assert {:error, :spec_taken} =
               Repo.transaction(fn ->
                 {:ok, item} = plywood(c, %{name: "Rolled back"})
                 send(test_pid, {:created, item.uuid})
                 # The host's own insert hits its unique index.
                 Repo.rollback(:spec_taken)
               end)

      assert_received {:created, uuid}
      assert Catalogue.get_item(uuid) == nil

      assert Repo.aggregate(
               from(a in "phoenix_kit_activities", where: a.resource_uuid == type(^uuid, UUIDv7)),
               :count
             ) == 0
    end

    test "with broadcast: false nothing is announced until the host does it after its commit",
         %{catalogue: c} do
      PubSub.subscribe()
      attrs = %{name: "Committed", catalogue_uuid: c.uuid, unit: "sheet", thickness_mm: 18}

      # Rolled back: no event at all.
      assert {:error, :spec_taken} =
               Repo.transaction(fn ->
                 {:ok, _item} = Catalogue.create_item(attrs, broadcast: false)
                 Repo.rollback(:spec_taken)
               end)

      refute_receive {:catalogue_data_changed, :item, _, _}, 50

      # Committed: the host announces it itself, once.
      assert {:ok, item} =
               Repo.transaction(fn ->
                 {:ok, item} = Catalogue.create_item(attrs, broadcast: false)
                 item
               end)

      refute_receive {:catalogue_data_changed, :item, _, _}, 50

      assert :ok =
               Catalogue.broadcast_item_batch_change(item.catalogue_uuid, :created, [item.uuid])

      catalogue_uuid = c.uuid
      item_uuid = item.uuid
      assert_receive {:catalogue_bulk_change, ^catalogue_uuid, :created, [^item_uuid], _from}
      assert_receive {:catalogue_data_changed, :item, nil, ^catalogue_uuid}
      assert Catalogue.get_item(item.uuid)
      # The committed item has its activity entry; the rolled-back one has none.
      assert_activity_logged("item.created", resource_uuid: item.uuid)
    end

    test "without it the event goes out before the caller commits — the documented default",
         %{catalogue: c} do
      PubSub.subscribe()
      catalogue_uuid = c.uuid

      assert {:error, :spec_taken} =
               Repo.transaction(fn ->
                 {:ok, item} =
                   Catalogue.create_item(%{name: "Early", catalogue_uuid: c.uuid})

                 assert_receive {:catalogue_data_changed, :item, uuid, ^catalogue_uuid}
                 assert uuid == item.uuid
                 Repo.rollback(:spec_taken)
               end)
    end

    test "an invalid item rolls the caller's transaction back", %{catalogue: c} do
      assert {:error, :rollback} =
               Repo.transaction(fn ->
                 assert {:error, %Ecto.Changeset{}} =
                          Catalogue.create_item(%{
                            name: "Bad",
                            catalogue_uuid: c.uuid,
                            thickness_mm: -1
                          })

                 :unreachable_commit
               end)
    end
  end
end
