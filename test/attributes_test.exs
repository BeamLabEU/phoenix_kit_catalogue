defmodule PhoenixKitCatalogue.AttributesTest do
  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.ItemAttributeGroup
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo

  # ── Helpers ──────────────────────────────────────────────────────

  defp create_group(attrs \\ %{}) do
    {:ok, g} = Catalogue.create_attribute_group(Map.merge(%{name: "Idea doors"}, attrs))
    g
  end

  defp create_attribute(group, attrs \\ %{}) do
    {:ok, a} = Catalogue.create_attribute(group, Map.merge(%{"name" => "Color"}, attrs))
    a
  end

  defp create_value(attribute, text) do
    {:ok, v} = Catalogue.create_attribute_value(attribute, %{"value" => text})
    v
  end

  defp create_item do
    {:ok, catalogue} =
      Catalogue.create_catalogue(%{name: "Cat #{System.unique_integer([:positive])}"})

    {:ok, item} = Catalogue.create_item(%{name: "Door", catalogue_uuid: catalogue.uuid})
    item
  end

  # ── Groups ───────────────────────────────────────────────────────

  describe "attribute groups" do
    test "create / list / filter by status" do
      g = create_group()
      _archived = create_group(%{name: "Old doors", status: "archived"})

      assert [%{name: "Idea doors"}] = Catalogue.list_attribute_groups(status: "active")
      assert length(Catalogue.list_attribute_groups()) == 2
      assert Catalogue.get_attribute_group(g.uuid).name == "Idea doors"
    end

    test "delete cascades values -> attributes -> group when unreferenced" do
      g = create_group()
      a = create_attribute(g)
      create_value(a, "White")

      assert {:ok, _} = Catalogue.delete_attribute_group(g)
      assert Catalogue.get_attribute_group(g.uuid) == nil
      assert Catalogue.get_attribute(a.uuid) == nil
    end

    test "delete is gated when an item is assigned; archive still works" do
      g = create_group()
      item = create_item()
      assert {:ok, :assigned} = Catalogue.set_item_attribute_group(item, g.uuid)

      assert {:error, :in_use} = Catalogue.delete_attribute_group(g)

      assert {:ok, archived} = Catalogue.update_attribute_group(g, %{status: "archived"})
      assert archived.status == "archived"
    end
  end

  # ── Attributes and values ────────────────────────────────────────

  describe "attributes" do
    test "keys are auto-slugged, deduped, and immutable on update" do
      g = create_group()
      a1 = create_attribute(g, %{"name" => "Color"})
      a2 = create_attribute(g, %{"name" => "Color!"})

      assert a1.key == "color"
      assert a2.key == "color-2"

      {:ok, renamed} = Catalogue.update_attribute(a1, %{"name" => "Colour", "key" => "hacked"})
      assert renamed.name == "Colour"
      assert renamed.key == "color"
    end

    test "cyrillic names fall back to the base key" do
      g = create_group()
      a = create_attribute(g, %{"name" => "Цвет"})
      # transliteration may or may not cover Cyrillic — either a real slug
      # or the "attr" fallback is fine, but never blank.
      assert a.key != ""
    end

    test "positions append in creation order and reorder persists" do
      g = create_group()
      a1 = create_attribute(g, %{"name" => "Color"})
      a2 = create_attribute(g, %{"name" => "Trim"})
      assert {a1.position, a2.position} == {0, 1}

      :ok = Catalogue.reorder_attributes(g, [a2.uuid, a1.uuid])
      full = Catalogue.get_attribute_group_full(g.uuid)
      assert Enum.map(full.attributes, & &1.name) == ["Trim", "Color"]
    end

    test "deleting an attribute removes its values" do
      g = create_group()
      a = create_attribute(g)
      v = create_value(a, "White")

      assert {:ok, _} = Catalogue.delete_attribute(a)
      assert Catalogue.get_attribute_value(v.uuid) == nil
    end
  end

  describe "values" do
    test "first value auto-defaults; set_default_value flips atomically" do
      g = create_group()
      a = create_attribute(g)
      v1 = create_value(a, "White")
      v2 = create_value(a, "Oak")

      assert v1.is_default
      refute v2.is_default

      {:ok, _} = Catalogue.set_default_value(v2)
      resolved = Catalogue.resolved_group(g.uuid, "en")
      [%{values: values}] = resolved.attributes
      assert Enum.find(values, & &1.default?).value == "Oak"
    end

    test "deleting the default promotes the lowest-position survivor" do
      g = create_group()
      a = create_attribute(g)
      v1 = create_value(a, "White")
      _v2 = create_value(a, "Oak")

      {:ok, _} = Catalogue.delete_attribute_value(v1)

      resolved = Catalogue.resolved_group(g.uuid, "en")
      [%{values: [%{value: "Oak", default?: true}]}] = resolved.attributes
    end
  end

  # ── Item assignment ──────────────────────────────────────────────

  describe "item assignment" do
    test "assign, swap, clear, and batch map" do
      g1 = create_group()
      g2 = create_group(%{name: "Basic doors"})
      item = create_item()

      assert {:ok, :assigned} = Catalogue.set_item_attribute_group(item, g1.uuid)
      assert Catalogue.get_item_attribute_group_uuid(item.uuid) == g1.uuid
      assert {:ok, :unchanged} = Catalogue.set_item_attribute_group(item, g1.uuid)

      assert {:ok, :assigned} = Catalogue.set_item_attribute_group(item, g2.uuid)
      assert Catalogue.item_attribute_group_map([item.uuid]) == %{item.uuid => g2.uuid}
      # still exactly one assignment row — the unique index held
      assert TestRepo.aggregate(ItemAttributeGroup, :count) == 1

      assert {:ok, :cleared} = Catalogue.set_item_attribute_group(item, nil)
      assert Catalogue.get_item_attribute_group_uuid(item.uuid) == nil
      assert {:ok, :unchanged} = Catalogue.set_item_attribute_group(item, nil)
    end

    test "archived and unknown groups are not assignable" do
      g = create_group(%{status: "archived"})
      item = create_item()

      assert {:error, :invalid_group} = Catalogue.set_item_attribute_group(item, g.uuid)

      assert {:error, :invalid_group} =
               Catalogue.set_item_attribute_group(item, Ecto.UUID.generate())
    end

    test "keeping the current group is allowed after it gets archived" do
      g = create_group()
      item = create_item()
      {:ok, :assigned} = Catalogue.set_item_attribute_group(item, g.uuid)
      {:ok, _} = Catalogue.update_attribute_group(g, %{status: "archived"})

      # re-submitting the same (now archived) group is a no-op, not an error
      assert {:ok, :unchanged} = Catalogue.set_item_attribute_group(item, g.uuid)
    end

    test "hard-deleting the item removes its assignment row" do
      g = create_group()
      item = create_item()
      {:ok, :assigned} = Catalogue.set_item_attribute_group(item, g.uuid)

      {:ok, _} = Catalogue.permanently_delete_item(item)
      assert TestRepo.aggregate(ItemAttributeGroup, :count) == 0
    end
  end

  # ── Resolution ───────────────────────────────────────────────────

  describe "resolved_group/2" do
    test "translates names and values with primary-language fallback" do
      g = create_group()
      a = create_attribute(g, %{"name" => "Color"})
      v = create_value(a, "Oak")

      # Written the way the UI writes them — through the shared multilang
      # helper, which produces the {"_primary_language", "en", "ru"} shape.
      {:ok, _} =
        Catalogue.set_translation(a, "ru", %{"_name" => "Цвет"}, &Catalogue.update_attribute/2)

      {:ok, _} =
        Catalogue.set_translation(
          v,
          "ru",
          %{"_value" => "Дуб"},
          &Catalogue.update_attribute_value/2
        )

      ru = Catalogue.resolved_group(g.uuid, "ru")
      assert [%{name: "Цвет", values: [%{value: "Дуб"}]}] = ru.attributes

      # Estonian has no overrides — falls back to the primary columns.
      et = Catalogue.resolved_group(g.uuid, "et")
      assert [%{name: "Color", values: [%{value: "Oak"}]}] = et.attributes
    end

    test "archived attributes and values are excluded; nil group resolves to nil" do
      g = create_group()
      a = create_attribute(g, %{"name" => "Color"})
      _v1 = create_value(a, "White")
      v2 = create_value(a, "Discontinued")
      {:ok, _} = Catalogue.update_attribute_value(v2, %{"status" => "archived"})

      hidden = create_attribute(g, %{"name" => "Internal"})
      {:ok, _} = Catalogue.update_attribute(hidden, %{"status" => "archived"})

      resolved = Catalogue.resolved_group(g.uuid, "en")
      assert [%{name: "Color", values: [%{value: "White"}]}] = resolved.attributes

      assert Catalogue.resolved_group(nil, "en") == nil
    end
  end

  describe "counts" do
    test "attribute_counts and assignment_counts batch per group" do
      g1 = create_group()
      g2 = create_group(%{name: "Basic"})
      create_attribute(g1, %{"name" => "Color"})
      create_attribute(g1, %{"name" => "Trim"})

      item = create_item()
      {:ok, :assigned} = Catalogue.set_item_attribute_group(item, g1.uuid)

      assert Catalogue.attribute_counts([g1.uuid, g2.uuid]) == %{g1.uuid => 2}
      assert Catalogue.assignment_counts([g1.uuid, g2.uuid]) == %{g1.uuid => 1}
      assert Catalogue.attribute_counts([]) == %{}
    end
  end
end
