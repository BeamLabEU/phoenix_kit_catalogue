defmodule PhoenixKitCatalogue.CatalogueTest do
  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue

  # ── Helpers ──────────────────────────────────────────────────────

  defp create_manufacturer(attrs \\ %{}) do
    {:ok, m} = Catalogue.create_manufacturer(Map.merge(%{name: "Test Manufacturer"}, attrs))
    m
  end

  defp create_supplier(attrs \\ %{}) do
    {:ok, s} = Catalogue.create_supplier(Map.merge(%{name: "Test Supplier"}, attrs))
    s
  end

  defp create_catalogue(attrs \\ %{}) do
    {:ok, c} = Catalogue.create_catalogue(Map.merge(%{name: "Test Catalogue"}, attrs))
    c
  end

  defp create_category(catalogue, attrs \\ %{}) do
    {:ok, c} =
      Catalogue.create_category(
        Map.merge(%{name: "Test Category", catalogue_uuid: catalogue.uuid}, attrs)
      )

    c
  end

  defp create_item(attrs \\ %{}) do
    {:ok, i} = Catalogue.create_item(Map.merge(%{name: "Test Item"}, attrs))
    i
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturers
  # ═══════════════════════════════════════════════════════════════════

  describe "manufacturers" do
    test "create_manufacturer/1 with valid attrs" do
      assert {:ok, m} = Catalogue.create_manufacturer(%{name: "Blum"})
      assert m.name == "Blum"
      assert m.status == "active"
    end

    test "create_manufacturer/1 requires name" do
      assert {:error, changeset} = Catalogue.create_manufacturer(%{})
      assert errors_on(changeset).name
    end

    test "list_manufacturers/0 returns all" do
      create_manufacturer(%{name: "A"})
      create_manufacturer(%{name: "B"})
      assert length(Catalogue.list_manufacturers()) == 2
    end

    test "list_manufacturers/1 filters by status" do
      create_manufacturer(%{name: "Active", status: "active"})
      create_manufacturer(%{name: "Inactive", status: "inactive"})
      assert length(Catalogue.list_manufacturers(status: "active")) == 1
    end

    test "update_manufacturer/2" do
      m = create_manufacturer()
      assert {:ok, updated} = Catalogue.update_manufacturer(m, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "delete_manufacturer/1" do
      m = create_manufacturer()
      assert {:ok, _} = Catalogue.delete_manufacturer(m)
      assert is_nil(Catalogue.get_manufacturer(m.uuid))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Suppliers
  # ═══════════════════════════════════════════════════════════════════

  describe "suppliers" do
    test "create_supplier/1 with valid attrs" do
      assert {:ok, s} = Catalogue.create_supplier(%{name: "Distributor"})
      assert s.name == "Distributor"
      assert s.status == "active"
    end

    test "create_supplier/1 requires name" do
      assert {:error, changeset} = Catalogue.create_supplier(%{})
      assert errors_on(changeset).name
    end

    test "list_suppliers/1 filters by status" do
      create_supplier(%{name: "Active", status: "active"})
      create_supplier(%{name: "Inactive", status: "inactive"})
      assert length(Catalogue.list_suppliers(status: "active")) == 1
    end

    test "delete_supplier/1" do
      s = create_supplier()
      assert {:ok, _} = Catalogue.delete_supplier(s)
      assert is_nil(Catalogue.get_supplier(s.uuid))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturer ↔ Supplier links
  # ═══════════════════════════════════════════════════════════════════

  describe "manufacturer-supplier links" do
    test "link and unlink" do
      m = create_manufacturer()
      s = create_supplier()

      assert {:ok, _} = Catalogue.link_manufacturer_supplier(m.uuid, s.uuid)
      assert s.uuid in Catalogue.linked_supplier_uuids(m.uuid)

      assert {:ok, _} = Catalogue.unlink_manufacturer_supplier(m.uuid, s.uuid)
      assert Catalogue.linked_supplier_uuids(m.uuid) == []
    end

    test "sync_manufacturer_suppliers/2 returns {:ok, :synced}" do
      m = create_manufacturer()
      s1 = create_supplier(%{name: "S1"})
      s2 = create_supplier(%{name: "S2"})

      assert {:ok, :synced} =
               Catalogue.sync_manufacturer_suppliers(m.uuid, [s1.uuid, s2.uuid])

      assert MapSet.new(Catalogue.linked_supplier_uuids(m.uuid)) == MapSet.new([s1.uuid, s2.uuid])

      # Remove s1, keep s2
      assert {:ok, :synced} = Catalogue.sync_manufacturer_suppliers(m.uuid, [s2.uuid])
      assert Catalogue.linked_supplier_uuids(m.uuid) == [s2.uuid]
    end

    test "list_suppliers_for_manufacturer/1" do
      m = create_manufacturer()
      s = create_supplier()
      Catalogue.link_manufacturer_supplier(m.uuid, s.uuid)

      suppliers = Catalogue.list_suppliers_for_manufacturer(m.uuid)
      assert length(suppliers) == 1
      assert hd(suppliers).uuid == s.uuid
    end

    test "list_manufacturers_for_supplier/1" do
      m = create_manufacturer()
      s = create_supplier()
      Catalogue.link_manufacturer_supplier(m.uuid, s.uuid)

      manufacturers = Catalogue.list_manufacturers_for_supplier(s.uuid)
      assert length(manufacturers) == 1
      assert hd(manufacturers).uuid == m.uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Catalogues
  # ═══════════════════════════════════════════════════════════════════

  describe "catalogues" do
    test "create_catalogue/1 defaults markup_percentage to 0" do
      assert {:ok, c} = Catalogue.create_catalogue(%{name: "Kitchen"})
      assert c.name == "Kitchen"
      assert c.status == "active"
      assert Decimal.equal?(c.markup_percentage, Decimal.new("0"))
    end

    test "create_catalogue/1 with markup_percentage" do
      assert {:ok, c} = Catalogue.create_catalogue(%{name: "Kitchen", markup_percentage: 15.0})
      assert Decimal.equal?(c.markup_percentage, Decimal.new("15.0"))
    end

    test "create_catalogue/1 requires name" do
      assert {:error, changeset} = Catalogue.create_catalogue(%{})
      assert errors_on(changeset).name
    end

    test "create_catalogue/1 validates markup_percentage >= 0" do
      assert {:error, changeset} =
               Catalogue.create_catalogue(%{name: "X", markup_percentage: -5})

      assert errors_on(changeset).markup_percentage
    end

    test "list_catalogues/0 excludes deleted" do
      create_catalogue(%{name: "Active"})
      c2 = create_catalogue(%{name: "To Delete"})
      Catalogue.trash_catalogue(c2)

      catalogues = Catalogue.list_catalogues()
      assert length(catalogues) == 1
      assert hd(catalogues).name == "Active"
    end

    test "list_catalogues/1 with status filter" do
      create_catalogue(%{name: "Active"})
      c2 = create_catalogue(%{name: "Deleted"})
      Catalogue.trash_catalogue(c2)

      assert length(Catalogue.list_catalogues(status: "deleted")) == 1
    end

    test "get_catalogue!/2 filters items by mode" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Active Item", category_uuid: category.uuid})
      item2 = create_item(%{name: "Deleted Item", category_uuid: category.uuid})
      Catalogue.trash_item(item2)

      active = Catalogue.get_catalogue!(cat.uuid, mode: :active)
      active_items = active.categories |> hd() |> Map.get(:items)
      assert length(active_items) == 1
      assert hd(active_items).name == "Active Item"

      deleted = Catalogue.get_catalogue!(cat.uuid, mode: :deleted)
      deleted_items = deleted.categories |> hd() |> Map.get(:items)
      assert length(deleted_items) == 1
      assert hd(deleted_items).name == "Deleted Item"
    end

    test "get_catalogue!/2 filters categories by mode" do
      cat = create_catalogue()
      create_category(cat, %{name: "Active Cat"})
      deleted_cat = create_category(cat, %{name: "Deleted Cat"})
      Catalogue.trash_category(deleted_cat)

      active = Catalogue.get_catalogue!(cat.uuid, mode: :active)
      assert length(active.categories) == 1
      assert hd(active.categories).name == "Active Cat"
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Catalogue soft-delete cascading
  # ═══════════════════════════════════════════════════════════════════

  describe "catalogue soft-delete cascade" do
    test "trash_catalogue cascades to categories and items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, _} = Catalogue.trash_catalogue(cat)

      assert Catalogue.get_catalogue(cat.uuid).status == "deleted"
      assert Catalogue.get_category(category.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "restore_catalogue cascades to categories and items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})
      Catalogue.trash_catalogue(cat)

      cat = Catalogue.get_catalogue(cat.uuid)
      {:ok, _} = Catalogue.restore_catalogue(cat)

      assert Catalogue.get_catalogue(cat.uuid).status == "active"
      assert Catalogue.get_category(category.uuid).status == "active"
      assert Catalogue.get_item(item.uuid).status == "active"
    end

    test "permanently_delete_catalogue removes everything" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, _} = Catalogue.permanently_delete_catalogue(cat)

      assert is_nil(Catalogue.get_catalogue(cat.uuid))
      assert is_nil(Catalogue.get_category(category.uuid))
      assert is_nil(Catalogue.get_item(item.uuid))
    end

    test "deleted_catalogue_count/0" do
      create_catalogue(%{name: "Active"})
      c2 = create_catalogue(%{name: "Deleted"})
      Catalogue.trash_catalogue(c2)

      assert Catalogue.deleted_catalogue_count() >= 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Categories
  # ═══════════════════════════════════════════════════════════════════

  describe "categories" do
    test "create_category/1" do
      cat = create_catalogue()
      assert {:ok, c} = Catalogue.create_category(%{name: "Frames", catalogue_uuid: cat.uuid})
      assert c.name == "Frames"
      assert c.status == "active"
    end

    test "create_category/1 requires name and catalogue_uuid" do
      assert {:error, changeset} = Catalogue.create_category(%{})
      assert errors_on(changeset).name
      assert errors_on(changeset).catalogue_uuid
    end

    test "list_categories_for_catalogue/1 excludes deleted" do
      cat = create_catalogue()
      create_category(cat, %{name: "Active"})
      deleted = create_category(cat, %{name: "Deleted"})
      Catalogue.trash_category(deleted)

      categories = Catalogue.list_categories_for_catalogue(cat.uuid)
      assert length(categories) == 1
      assert hd(categories).name == "Active"
    end

    test "list_all_categories/0 excludes deleted catalogues and categories" do
      cat = create_catalogue(%{name: "MyCat"})
      create_category(cat, %{name: "Active"})
      deleted = create_category(cat, %{name: "Deleted"})
      Catalogue.trash_category(deleted)

      all = Catalogue.list_all_categories()
      names = Enum.map(all, & &1.name)
      assert "MyCat / Active" in names
      refute "MyCat / Deleted" in names
    end

    test "next_category_position/1" do
      cat = create_catalogue()
      assert Catalogue.next_category_position(cat.uuid) == 0
      create_category(cat, %{position: 0})
      assert Catalogue.next_category_position(cat.uuid) == 1
      create_category(cat, %{position: 5})
      assert Catalogue.next_category_position(cat.uuid) == 6
    end

    test "swap_category_positions/2 atomically swaps" do
      cat = create_catalogue()
      c1 = create_category(cat, %{name: "First", position: 0})
      c2 = create_category(cat, %{name: "Second", position: 1})

      assert {:ok, _} = Catalogue.swap_category_positions(c1, c2)

      assert Catalogue.get_category(c1.uuid).position == 1
      assert Catalogue.get_category(c2.uuid).position == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Category soft-delete cascading
  # ═══════════════════════════════════════════════════════════════════

  describe "category soft-delete cascade" do
    test "trash_category cascades to items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, _} = Catalogue.trash_category(category)

      assert Catalogue.get_category(category.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "restore_category cascades to items and restores parent catalogue" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})
      Catalogue.trash_catalogue(cat)

      # Restore the category — should also restore catalogue (upward) and items (downward)
      category = Catalogue.get_category(category.uuid)
      {:ok, _} = Catalogue.restore_category(category)

      assert Catalogue.get_catalogue(cat.uuid).status == "active"
      assert Catalogue.get_category(category.uuid).status == "active"
      assert Catalogue.get_item(item.uuid).status == "active"
    end

    test "permanently_delete_category removes category and items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, _} = Catalogue.permanently_delete_category(category)

      assert is_nil(Catalogue.get_category(category.uuid))
      assert is_nil(Catalogue.get_item(item.uuid))
      # Catalogue should still exist
      assert Catalogue.get_catalogue(cat.uuid)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Category move
  # ═══════════════════════════════════════════════════════════════════

  describe "move_category_to_catalogue/2" do
    test "moves category to another catalogue" do
      cat1 = create_catalogue(%{name: "Source"})
      cat2 = create_catalogue(%{name: "Target"})
      category = create_category(cat1, %{name: "Moving"})

      {:ok, moved} = Catalogue.move_category_to_catalogue(category, cat2.uuid)

      assert moved.catalogue_uuid == cat2.uuid
      assert Catalogue.list_categories_for_catalogue(cat1.uuid) == []
      assert length(Catalogue.list_categories_for_catalogue(cat2.uuid)) == 1
    end

    test "assigns next position in target catalogue" do
      cat1 = create_catalogue(%{name: "Source"})
      cat2 = create_catalogue(%{name: "Target"})
      create_category(cat2, %{name: "Existing", position: 3})
      category = create_category(cat1, %{name: "Moving", position: 0})

      {:ok, moved} = Catalogue.move_category_to_catalogue(category, cat2.uuid)

      assert moved.position == 4
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Items
  # ═══════════════════════════════════════════════════════════════════

  describe "items" do
    test "create_item/1 with valid attrs" do
      assert {:ok, i} = Catalogue.create_item(%{name: "Oak Panel"})
      assert i.name == "Oak Panel"
      assert i.status == "active"
      assert i.unit == "piece"
    end

    test "create_item/1 requires name" do
      assert {:error, changeset} = Catalogue.create_item(%{})
      assert errors_on(changeset).name
    end

    test "create_item/1 validates status" do
      assert {:error, changeset} = Catalogue.create_item(%{name: "X", status: "bogus"})
      assert errors_on(changeset).status
    end

    test "create_item/1 validates unit" do
      assert {:error, changeset} = Catalogue.create_item(%{name: "X", unit: "bogus"})
      assert errors_on(changeset).unit
    end

    test "create_item/1 validates base_price >= 0" do
      assert {:error, changeset} = Catalogue.create_item(%{name: "X", base_price: -1})
      assert errors_on(changeset).base_price
    end

    test "create_item/1 with base_price" do
      assert {:ok, i} = Catalogue.create_item(%{name: "Panel", base_price: "25.50"})
      assert Decimal.equal?(i.base_price, Decimal.new("25.50"))
    end

    test "update_item/2" do
      item = create_item()
      assert {:ok, updated} = Catalogue.update_item(item, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "get_item!/1 preloads category and manufacturer" do
      cat = create_catalogue()
      category = create_category(cat)
      m = create_manufacturer()
      item = create_item(%{name: "X", category_uuid: category.uuid, manufacturer_uuid: m.uuid})

      loaded = Catalogue.get_item!(item.uuid)
      assert loaded.category.uuid == category.uuid
      assert loaded.manufacturer.uuid == m.uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item soft-delete
  # ═══════════════════════════════════════════════════════════════════

  describe "item soft-delete" do
    test "trash_item/1 sets status to deleted" do
      item = create_item()
      {:ok, trashed} = Catalogue.trash_item(item)
      assert trashed.status == "deleted"
    end

    test "restore_item/1 sets status back to active" do
      item = create_item()
      {:ok, trashed} = Catalogue.trash_item(item)
      {:ok, restored} = Catalogue.restore_item(trashed)
      assert restored.status == "active"
    end

    test "restore_item/1 cascades upward to deleted parent category" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      Catalogue.trash_category(category)
      assert Catalogue.get_category(category.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"

      item = Catalogue.get_item(item.uuid)
      {:ok, _} = Catalogue.restore_item(item)

      assert Catalogue.get_category(category.uuid).status == "active"
      assert Catalogue.get_item(item.uuid).status == "active"
    end

    test "restore_item/1 cascades upward to deleted parent catalogue" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      Catalogue.trash_catalogue(cat)
      assert Catalogue.get_catalogue(cat.uuid).status == "deleted"
      assert Catalogue.get_category(category.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"

      item = Catalogue.get_item(item.uuid)
      {:ok, _} = Catalogue.restore_item(item)

      assert Catalogue.get_catalogue(cat.uuid).status == "active"
      assert Catalogue.get_category(category.uuid).status == "active"
      assert Catalogue.get_item(item.uuid).status == "active"
    end

    test "permanently_delete_item/1 removes from DB" do
      item = create_item()
      {:ok, _} = Catalogue.permanently_delete_item(item)
      assert is_nil(Catalogue.get_item(item.uuid))
    end

    test "trash_items_in_category/1 bulk soft-deletes" do
      cat = create_catalogue()
      category = create_category(cat)
      i1 = create_item(%{name: "I1", category_uuid: category.uuid})
      i2 = create_item(%{name: "I2", category_uuid: category.uuid})

      Catalogue.trash_items_in_category(category.uuid)

      assert Catalogue.get_item(i1.uuid).status == "deleted"
      assert Catalogue.get_item(i2.uuid).status == "deleted"
    end

    test "trash_items_in_category/1 skips already deleted items" do
      cat = create_catalogue()
      category = create_category(cat)
      i1 = create_item(%{name: "I1", category_uuid: category.uuid})
      Catalogue.trash_item(i1)

      # Should not error
      {count, _} = Catalogue.trash_items_in_category(category.uuid)
      assert count == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item move
  # ═══════════════════════════════════════════════════════════════════

  describe "move_item_to_category/2" do
    test "moves item to a different category" do
      cat = create_catalogue()
      c1 = create_category(cat, %{name: "Source"})
      c2 = create_category(cat, %{name: "Target"})
      item = create_item(%{name: "Moving", category_uuid: c1.uuid})

      {:ok, moved} = Catalogue.move_item_to_category(item, c2.uuid)
      assert moved.category_uuid == c2.uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Deleted counts
  # ═══════════════════════════════════════════════════════════════════

  describe "deleted counts" do
    test "deleted_item_count_for_catalogue/1" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Active", category_uuid: category.uuid})
      i2 = create_item(%{name: "Deleted", category_uuid: category.uuid})
      Catalogue.trash_item(i2)

      assert Catalogue.deleted_item_count_for_catalogue(cat.uuid) == 1
    end

    test "deleted_item_count_for_catalogue/1 does not count uncategorized items" do
      cat = create_catalogue()
      item = create_item(%{name: "Orphan"})
      Catalogue.trash_item(item)

      # Uncategorized items don't belong to any catalogue
      assert Catalogue.deleted_item_count_for_catalogue(cat.uuid) == 0
    end

    test "deleted_category_count_for_catalogue/1" do
      cat = create_catalogue()
      create_category(cat, %{name: "Active"})
      c2 = create_category(cat, %{name: "Deleted"})
      Catalogue.trash_category(c2)

      assert Catalogue.deleted_category_count_for_catalogue(cat.uuid) == 1
    end

    test "deleted_count_for_catalogue/1 sums items and categories" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})
      Catalogue.trash_item(item)

      c2 = create_category(cat, %{name: "Deleted Cat"})
      Catalogue.trash_category(c2)

      assert Catalogue.deleted_count_for_catalogue(cat.uuid) >= 2
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Uncategorized items
  # ═══════════════════════════════════════════════════════════════════

  describe "uncategorized items" do
    test "list_uncategorized_items/1 active mode excludes deleted" do
      create_item(%{name: "Active Orphan"})
      i2 = create_item(%{name: "Deleted Orphan"})
      Catalogue.trash_item(i2)

      active = Catalogue.list_uncategorized_items(mode: :active)
      names = Enum.map(active, & &1.name)
      assert "Active Orphan" in names
      refute "Deleted Orphan" in names
    end

    test "list_uncategorized_items/1 deleted mode shows only deleted" do
      create_item(%{name: "Active Orphan"})
      i2 = create_item(%{name: "Deleted Orphan"})
      Catalogue.trash_item(i2)

      deleted = Catalogue.list_uncategorized_items(mode: :deleted)
      names = Enum.map(deleted, & &1.name)
      refute "Active Orphan" in names
      assert "Deleted Orphan" in names
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Sale price calculation
  # ═══════════════════════════════════════════════════════════════════

  describe "sale price" do
    alias PhoenixKitCatalogue.Schemas.Item

    test "sale_price/2 with markup" do
      item = %Item{base_price: Decimal.new("100.00")}
      markup = Decimal.new("20.0")

      assert Decimal.equal?(Item.sale_price(item, markup), Decimal.new("120.00"))
    end

    test "sale_price/2 with nil base_price" do
      item = %Item{base_price: nil}
      assert is_nil(Item.sale_price(item, Decimal.new("20.0")))
    end

    test "sale_price/2 with nil markup returns base_price" do
      item = %Item{base_price: Decimal.new("50.00")}
      assert Decimal.equal?(Item.sale_price(item, nil), Decimal.new("50.00"))
    end

    test "sale_price/2 with zero markup returns base_price" do
      item = %Item{base_price: Decimal.new("50.00")}
      assert Decimal.equal?(Item.sale_price(item, Decimal.new("0")), Decimal.new("50.00"))
    end

    test "sale_price/2 rounds to 2 decimal places" do
      item = %Item{base_price: Decimal.new("33.33")}
      markup = Decimal.new("33.33")

      result = Item.sale_price(item, markup)
      assert Decimal.equal?(result, Decimal.new("44.44"))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item pricing (full API)
  # ═══════════════════════════════════════════════════════════════════

  describe "item_pricing/1" do
    test "returns base_price, markup_percentage, and computed price" do
      cat = create_catalogue(%{name: "Marked Up", markup_percentage: 20})
      category = create_category(cat)
      item = create_item(%{name: "Panel", base_price: "100.00", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.base_price, Decimal.new("100.00"))
      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("20"))
      assert Decimal.equal?(pricing.price, Decimal.new("120.00"))
    end

    test "uses 0% markup when catalogue has default" do
      cat = create_catalogue(%{name: "No Markup"})
      category = create_category(cat)
      item = create_item(%{name: "Panel", base_price: "50.00", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("0"))
      assert Decimal.equal?(pricing.price, Decimal.new("50.00"))
    end

    test "uses 0% markup for uncategorized items" do
      item = create_item(%{name: "Orphan", base_price: "75.00"})

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("0"))
      assert Decimal.equal?(pricing.price, Decimal.new("75.00"))
    end

    test "returns nil price when base_price is nil" do
      cat = create_catalogue(%{name: "Cat", markup_percentage: 10})
      category = create_category(cat)
      item = create_item(%{name: "No Price", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)

      assert is_nil(pricing.base_price)
      assert is_nil(pricing.price)
      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("10"))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Search
  # ═══════════════════════════════════════════════════════════════════

  describe "search_items/1 (global)" do
    test "finds items by name" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Oak Panel 18mm", category_uuid: category.uuid})
      create_item(%{name: "Birch Veneer", category_uuid: category.uuid})

      results = Catalogue.search_items("oak")
      assert length(results) == 1
      assert hd(results).name == "Oak Panel 18mm"
    end

    test "finds items by SKU" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Panel", sku: "OAK-18", category_uuid: category.uuid})

      results = Catalogue.search_items("OAK-18")
      assert length(results) == 1
    end

    test "finds items by description" do
      cat = create_catalogue()
      category = create_category(cat)

      create_item(%{
        name: "Panel",
        description: "Premium hardwood panel",
        category_uuid: category.uuid
      })

      results = Catalogue.search_items("hardwood")
      assert length(results) == 1
    end

    test "is case-insensitive" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Oak Panel", category_uuid: category.uuid})

      assert length(Catalogue.search_items("OAK PANEL")) == 1
      assert length(Catalogue.search_items("oak panel")) == 1
    end

    test "excludes deleted items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Deleted Oak", category_uuid: category.uuid})
      Catalogue.trash_item(item)

      assert Catalogue.search_items("oak") == []
    end

    test "excludes items in deleted catalogues" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Hidden Oak", category_uuid: category.uuid})
      Catalogue.trash_catalogue(cat)

      assert Catalogue.search_items("oak") == []
    end

    test "preloads category with catalogue and manufacturer" do
      cat = create_catalogue(%{name: "Kitchen"})
      category = create_category(cat, %{name: "Frames"})
      m = create_manufacturer(%{name: "Blum"})
      create_item(%{name: "Oak Panel", category_uuid: category.uuid, manufacturer_uuid: m.uuid})

      [item] = Catalogue.search_items("oak")
      assert item.category.name == "Frames"
      assert item.category.catalogue.name == "Kitchen"
      assert item.manufacturer.name == "Blum"
    end

    test "respects limit option" do
      cat = create_catalogue()
      category = create_category(cat)
      for n <- 1..5, do: create_item(%{name: "Oak #{n}", category_uuid: category.uuid})

      assert length(Catalogue.search_items("oak", limit: 3)) == 3
    end

    test "handles LIKE special characters safely" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "100% Oak", category_uuid: category.uuid})

      # Should not treat % as wildcard
      assert Catalogue.search_items("100%") == [hd(Catalogue.search_items("100%"))]
    end
  end

  describe "search_items_in_catalogue/2" do
    test "only returns items within the specified catalogue" do
      cat1 = create_catalogue(%{name: "Kitchen"})
      cat2 = create_catalogue(%{name: "Bathroom"})
      c1 = create_category(cat1)
      c2 = create_category(cat2)
      create_item(%{name: "Oak Panel", category_uuid: c1.uuid})
      create_item(%{name: "Oak Shelf", category_uuid: c2.uuid})

      results = Catalogue.search_items_in_catalogue(cat1.uuid, "oak")
      assert length(results) == 1
      assert hd(results).name == "Oak Panel"
    end

    test "returns empty for no match" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Birch Veneer", category_uuid: category.uuid})

      assert Catalogue.search_items_in_catalogue(cat.uuid, "oak") == []
    end
  end

  describe "search_items_in_category/2" do
    test "only returns items within the specified category" do
      cat = create_catalogue()
      c1 = create_category(cat, %{name: "Frames"})
      c2 = create_category(cat, %{name: "Doors"})
      create_item(%{name: "Oak Frame", category_uuid: c1.uuid})
      create_item(%{name: "Oak Door", category_uuid: c2.uuid})

      results = Catalogue.search_items_in_category(c1.uuid, "oak")
      assert length(results) == 1
      assert hd(results).name == "Oak Frame"
    end

    test "excludes deleted items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Oak Panel", category_uuid: category.uuid})
      Catalogue.trash_item(item)

      assert Catalogue.search_items_in_category(category.uuid, "oak") == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item listing
  # ═══════════════════════════════════════════════════════════════════

  describe "list_items/1" do
    test "returns all non-deleted items" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Active", category_uuid: category.uuid})
      deleted = create_item(%{name: "Deleted", category_uuid: category.uuid})
      Catalogue.trash_item(deleted)

      items = Catalogue.list_items()
      names = Enum.map(items, & &1.name)
      assert "Active" in names
      refute "Deleted" in names
    end

    test "filters by status" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Active", category_uuid: category.uuid, status: "active"})
      create_item(%{name: "Inactive", category_uuid: category.uuid, status: "inactive"})

      items = Catalogue.list_items(status: "inactive")
      assert length(items) == 1
      assert hd(items).name == "Inactive"
    end

    test "respects limit" do
      cat = create_catalogue()
      category = create_category(cat)
      for n <- 1..5, do: create_item(%{name: "Item #{n}", category_uuid: category.uuid})

      assert length(Catalogue.list_items(limit: 3)) == 3
    end

    test "preloads category with catalogue and manufacturer" do
      cat = create_catalogue(%{name: "Kitchen"})
      category = create_category(cat, %{name: "Frames"})
      m = create_manufacturer(%{name: "Blum"})
      create_item(%{name: "Panel", category_uuid: category.uuid, manufacturer_uuid: m.uuid})

      [item] = Catalogue.list_items()
      assert item.category.name == "Frames"
      assert item.category.catalogue.name == "Kitchen"
      assert item.manufacturer.name == "Blum"
    end
  end

  describe "list_items_for_category/1" do
    test "returns non-deleted items ordered by name" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Zebra", category_uuid: category.uuid})
      create_item(%{name: "Alpha", category_uuid: category.uuid})
      deleted = create_item(%{name: "Gone", category_uuid: category.uuid})
      Catalogue.trash_item(deleted)

      items = Catalogue.list_items_for_category(category.uuid)
      assert length(items) == 2
      assert hd(items).name == "Alpha"
    end
  end

  describe "list_items_for_catalogue/1" do
    test "returns items across categories ordered by position then name" do
      cat = create_catalogue()
      c1 = create_category(cat, %{name: "Second", position: 1})
      c2 = create_category(cat, %{name: "First", position: 0})
      create_item(%{name: "B Item", category_uuid: c1.uuid})
      create_item(%{name: "A Item", category_uuid: c2.uuid})

      items = Catalogue.list_items_for_catalogue(cat.uuid)
      assert length(items) == 2
      # First position category's items come first
      assert hd(items).name == "A Item"
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Active counts
  # ═══════════════════════════════════════════════════════════════════

  describe "item_count_for_catalogue/1" do
    test "counts non-deleted items" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Active", category_uuid: category.uuid})
      deleted = create_item(%{name: "Deleted", category_uuid: category.uuid})
      Catalogue.trash_item(deleted)

      assert Catalogue.item_count_for_catalogue(cat.uuid) == 1
    end
  end

  describe "category_count_for_catalogue/1" do
    test "counts non-deleted categories" do
      cat = create_catalogue()
      create_category(cat, %{name: "Active"})
      deleted = create_category(cat, %{name: "Deleted"})
      Catalogue.trash_category(deleted)

      assert Catalogue.category_count_for_catalogue(cat.uuid) == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Supplier-manufacturer sync (reverse direction)
  # ═══════════════════════════════════════════════════════════════════

  describe "sync_supplier_manufacturers/2" do
    test "syncs manufacturer links for a supplier" do
      s = create_supplier()
      m1 = create_manufacturer(%{name: "M1"})
      m2 = create_manufacturer(%{name: "M2"})

      assert {:ok, :synced} = Catalogue.sync_supplier_manufacturers(s.uuid, [m1.uuid, m2.uuid])

      assert MapSet.new(Catalogue.linked_manufacturer_uuids(s.uuid)) ==
               MapSet.new([m1.uuid, m2.uuid])

      # Remove m1, keep m2
      assert {:ok, :synced} = Catalogue.sync_supplier_manufacturers(s.uuid, [m2.uuid])
      assert Catalogue.linked_manufacturer_uuids(s.uuid) == [m2.uuid]
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Multilang
  # ═══════════════════════════════════════════════════════════════════

  describe "multilang" do
    test "set_translation/4 and get_translation/2 round-trip" do
      cat = create_catalogue(%{name: "Kitchen"})

      {:ok, updated} =
        Catalogue.set_translation(cat, "ja", %{"_name" => "キッチン"}, &Catalogue.update_catalogue/2)

      data = Catalogue.get_translation(updated, "ja")
      assert data["_name"] == "キッチン"
    end

    test "get_translation/2 returns empty map for missing language" do
      cat = create_catalogue(%{name: "Kitchen"})
      data = Catalogue.get_translation(cat, "ja")
      assert data == %{}
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Schema validations
  # ═══════════════════════════════════════════════════════════════════

  describe "schema validations" do
    test "catalogue status must be valid" do
      assert {:error, changeset} = Catalogue.create_catalogue(%{name: "X", status: "bogus"})
      assert errors_on(changeset).status
    end

    test "category status must be valid" do
      cat = create_catalogue()

      assert {:error, changeset} =
               Catalogue.create_category(%{
                 name: "X",
                 catalogue_uuid: cat.uuid,
                 status: "bogus"
               })

      assert errors_on(changeset).status
    end

    test "item status allows deleted" do
      assert {:ok, i} = Catalogue.create_item(%{name: "X", status: "deleted"})
      assert i.status == "deleted"
    end

    test "manufacturer status must be valid" do
      assert {:error, changeset} = Catalogue.create_manufacturer(%{name: "X", status: "bogus"})
      assert errors_on(changeset).status
    end

    test "supplier status must be valid" do
      assert {:error, changeset} = Catalogue.create_supplier(%{name: "X", status: "bogus"})
      assert errors_on(changeset).status
    end

    test "item name max length" do
      long_name = String.duplicate("a", 256)
      assert {:error, changeset} = Catalogue.create_item(%{name: long_name})
      assert errors_on(changeset).name
    end

    test "item sku uniqueness" do
      create_item(%{name: "A", sku: "SKU-001"})
      assert {:error, changeset} = Catalogue.create_item(%{name: "B", sku: "SKU-001"})
      assert errors_on(changeset).sku
    end
  end
end
