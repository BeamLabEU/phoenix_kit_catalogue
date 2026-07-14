defmodule PhoenixKitCatalogue.ItemSupplierInfosTest do
  @moduledoc """
  Tests for the ItemSupplierInfos context and ItemSupplierInfo schema/changeset.
  Covers CRUD, set_primary uniqueness guarantee, and the Suppliers facade.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  alias PhoenixKitCatalogue.Catalogue.Suppliers
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_catalogue do
    {:ok, c} =
      Catalogue.create_catalogue(%{
        name: "Test Cat #{System.unique_integer([:positive])}"
      })

    c
  end

  defp create_item(catalogue) do
    {:ok, item} =
      Catalogue.create_item(%{
        name: "Item #{System.unique_integer([:positive])}",
        catalogue_uuid: catalogue.uuid
      })

    item
  end

  defp create_supplier do
    {:ok, s} =
      Catalogue.create_supplier(%{name: "Supplier #{System.unique_integer([:positive])}"})

    s
  end

  defp create_info(item, supplier, attrs \\ %{}) do
    base = %{
      "item_uuid" => item.uuid,
      "supplier_uuid" => supplier.uuid,
      "supplier_source" => "local",
      "supplier_name_snapshot" => supplier.name
    }

    {:ok, info} = ItemSupplierInfos.create(Map.merge(base, attrs))
    info
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Schema / changeset
  # ═══════════════════════════════════════════════════════════════════════════

  describe "ItemSupplierInfo.changeset/2" do
    test "requires item_uuid, supplier_uuid, supplier_source" do
      cs = ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{})
      refute cs.valid?
      errors = Ecto.Changeset.traverse_errors(cs, fn {m, _} -> m end)
      assert errors[:item_uuid]
      assert errors[:supplier_uuid]
      assert errors[:supplier_source]
    end

    test "rejects invalid supplier_source" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "bogus"
        })

      refute cs.valid?
    end

    test "accepts all valid supplier_sources" do
      for src <- ~w(crm_company crm_contact local) do
        cs =
          ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
            item_uuid: UUIDv7.generate(),
            supplier_uuid: UUIDv7.generate(),
            supplier_source: src
          })

        assert cs.valid?, "expected source #{src} to be valid"
      end
    end

    test "rejects negative unit_cost" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          unit_cost: -1
        })

      refute cs.valid?
    end

    test "accepts zero unit_cost" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          unit_cost: 0
        })

      assert cs.valid?
    end

    test "rejects invalid currency (non-3-uppercase)" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          currency: "eu"
        })

      refute cs.valid?
    end

    test "accepts valid 3-uppercase currency" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          currency: "EUR"
        })

      assert cs.valid?
    end

    test "rejects valid_to before valid_from" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          valid_from: ~D[2026-06-01],
          valid_to: ~D[2026-05-01]
        })

      refute cs.valid?
    end

    test "accepts valid_from == valid_to" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          valid_from: ~D[2026-06-01],
          valid_to: ~D[2026-06-01]
        })

      assert cs.valid?
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Context CRUD
  # ═══════════════════════════════════════════════════════════════════════════

  describe "ItemSupplierInfos context" do
    test "create/1 persists a row" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()

      assert {:ok, info} =
               ItemSupplierInfos.create(%{
                 "item_uuid" => item.uuid,
                 "supplier_uuid" => supplier.uuid,
                 "supplier_source" => "local"
               })

      assert info.item_uuid == item.uuid
      assert info.supplier_uuid == supplier.uuid
      assert info.is_primary == false
    end

    test "list_for_item/1 returns rows ordered by position then inserted_at" do
      cat = create_catalogue()
      item = create_item(cat)
      s1 = create_supplier()
      s2 = create_supplier()

      info1 = create_info(item, s1, %{"position" => 2})
      info2 = create_info(item, s2, %{"position" => 1})

      infos = ItemSupplierInfos.list_for_item(item.uuid)
      assert [^info2, ^info1] = infos
    end

    test "get/1 fetches by uuid" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)

      assert %ItemSupplierInfo{} = ItemSupplierInfos.get(info.uuid)
    end

    test "get/1 returns nil for unknown uuid" do
      assert is_nil(ItemSupplierInfos.get(UUIDv7.generate()))
    end

    test "update/2 changes fields" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)

      assert {:ok, updated} = ItemSupplierInfos.update(info, %{"supplier_sku" => "NEW-SKU"})
      assert updated.supplier_sku == "NEW-SKU"
    end

    test "delete/1 removes the row" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)

      assert {:ok, _} = ItemSupplierInfos.delete(info)
      assert is_nil(ItemSupplierInfos.get(info.uuid))
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # set_primary
  # ═══════════════════════════════════════════════════════════════════════════

  describe "set_primary/1" do
    test "sets is_primary on the target row" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)

      assert {:ok, updated} = ItemSupplierInfos.set_primary(info)
      assert updated.is_primary
    end

    test "clears existing primary before setting new one" do
      cat = create_catalogue()
      item = create_item(cat)
      s1 = create_supplier()
      s2 = create_supplier()

      info1 = create_info(item, s1)
      info2 = create_info(item, s2)

      {:ok, _} = ItemSupplierInfos.set_primary(info1)
      {:ok, _} = ItemSupplierInfos.set_primary(info2)

      # Only info2 should be primary now
      assert ItemSupplierInfos.get(info2.uuid).is_primary
      refute ItemSupplierInfos.get(info1.uuid).is_primary
    end

    test "only one primary per item after multiple set_primary calls" do
      cat = create_catalogue()
      item = create_item(cat)
      s1 = create_supplier()
      s2 = create_supplier()
      s3 = create_supplier()

      info1 = create_info(item, s1)
      info2 = create_info(item, s2)
      info3 = create_info(item, s3)

      {:ok, _} = ItemSupplierInfos.set_primary(info1)
      {:ok, _} = ItemSupplierInfos.set_primary(info2)
      {:ok, _} = ItemSupplierInfos.set_primary(info3)

      primaries =
        ItemSupplierInfos.list_for_item(item.uuid)
        |> Enum.filter(& &1.is_primary)

      assert length(primaries) == 1
      assert hd(primaries).uuid == info3.uuid
    end

    test "primary_for_item/1 returns the primary row" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)
      {:ok, _} = ItemSupplierInfos.set_primary(info)

      assert %ItemSupplierInfo{uuid: uuid} = ItemSupplierInfos.primary_for_item(item.uuid)
      assert uuid == info.uuid
    end

    test "primary_for_item/1 returns nil when no primary" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      _info = create_info(item, supplier)

      assert is_nil(ItemSupplierInfos.primary_for_item(item.uuid))
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Suppliers facade
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Suppliers.resolve/1 — local path" do
    test "resolves a local supplier" do
      supplier = create_supplier()

      assert {:ok, resolved} = Suppliers.resolve(supplier.uuid)
      assert resolved.uuid == supplier.uuid
      assert resolved.name == supplier.name
      assert resolved.source == :local
      assert is_nil(resolved.email)
    end

    test "returns :error for unknown uuid" do
      assert :error = Suppliers.resolve(UUIDv7.generate())
    end
  end

  describe "Suppliers.resolve/1 — guarded CRM path (CRM absent)" do
    test "falls back to local when CRM module is not loaded" do
      # CRM is not present in the catalogue test env; the guard should
      # mean we only hit the local path — no crash or exception.
      supplier = create_supplier()
      assert {:ok, %{source: :local}} = Suppliers.resolve(supplier.uuid)
    end
  end

  describe "Suppliers.list_all/0" do
    test "includes local suppliers" do
      s1 = create_supplier()
      s2 = create_supplier()

      all = Suppliers.list_all()
      uuids = Enum.map(all, & &1.uuid)

      assert s1.uuid in uuids
      assert s2.uuid in uuids
    end

    test "each entry has required keys" do
      _supplier = create_supplier()

      all = Suppliers.list_all()
      assert Enum.all?(all, &Map.has_key?(&1, :uuid))
      assert Enum.all?(all, &Map.has_key?(&1, :name))
      assert Enum.all?(all, &Map.has_key?(&1, :source))
    end
  end

  describe "Suppliers.primary_for_item/1" do
    test "delegates to ItemSupplierInfos.primary_for_item/1" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)
      {:ok, _} = ItemSupplierInfos.set_primary(info)

      result = Suppliers.primary_for_item(item.uuid)
      assert result.uuid == info.uuid
    end
  end
end
