defmodule PhoenixKitCatalogue.Import.ExecutorTest do
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Import.Executor

  defp create_catalogue(attrs \\ %{}) do
    {:ok, c} = Catalogue.create_catalogue(Map.merge(%{name: "Test Catalogue"}, attrs))
    c
  end

  describe "execute/4" do
    test "creates items from import plan" do
      cat = create_catalogue()

      plan = %{
        items: [
          %{name: "Oak Panel", sku: "OAK-1", base_price: Decimal.new("4.88")},
          %{name: "Birch Veneer", sku: "BV-1", base_price: Decimal.new("3.50")}
        ],
        categories_to_create: [],
        custom_fields: [],
        errors: [],
        stats: %{total: 2, valid: 2, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      assert result.created == 2
      assert result.errors == []

      # Verify items exist
      items = Catalogue.list_items()
      names = Enum.map(items, & &1.name)
      assert "Oak Panel" in names
      assert "Birch Veneer" in names

      # Verify we received progress messages
      assert_received {:import_progress, 1, 2}
      assert_received {:import_progress, 2, 2}
      assert_received {:import_result, _result}
    end

    test "creates categories from plan" do
      cat = create_catalogue()

      plan = %{
        items: [
          %{name: "Hook A", _category_name: "Hooks"},
          %{name: "Hinge B", _category_name: "Hinges"}
        ],
        categories_to_create: ["Hinges", "Hooks"],
        custom_fields: [],
        errors: [],
        stats: %{total: 2, valid: 2, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      assert result.categories_created == 2
      assert result.created == 2

      # Verify categories exist
      categories = Catalogue.list_categories_for_catalogue(cat.uuid)
      names = Enum.map(categories, & &1.name)
      assert "Hooks" in names
      assert "Hinges" in names

      # Verify items have category_uuid set
      items = Catalogue.list_items()
      assert Enum.all?(items, fn i -> i.category_uuid != nil end)
    end

    test "allows duplicate SKUs" do
      cat = create_catalogue()
      category = create_category(cat)

      {:ok, _} =
        Catalogue.create_item(%{name: "Existing", sku: "DUP-1", category_uuid: category.uuid})

      plan = %{
        items: [
          %{name: "Duplicate", sku: "DUP-1", base_price: Decimal.new("9.99")},
          %{name: "New Item", sku: "NEW-1", base_price: Decimal.new("5.00")}
        ],
        categories_to_create: [],
        custom_fields: [],
        errors: [],
        stats: %{total: 2, valid: 2, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      assert result.created == 2
      assert result.errors == []
    end

    test "applies language to imported items" do
      cat = create_catalogue()

      plan = %{
        items: [%{name: "Estonian Item", description: "Kirjeldus"}],
        categories_to_create: [],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self(), language: "et")
      assert result.created == 1

      [item] = Catalogue.list_items()
      assert item.data["_primary_language"] == "et"
      assert item.data["et"]["_name"] == "Estonian Item"
    end

    test "applies language to created categories the same way as items" do
      cat = create_catalogue()

      plan = %{
        items: [%{name: "Konks", _category_name: "Konksud"}],
        categories_to_create: ["Konksud"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self(), language: "et")
      assert result.created == 1
      assert result.categories_created == 1

      [category] = Catalogue.list_categories_for_catalogue(cat.uuid)
      # Bare `name` field still holds the imported string for fallback.
      assert category.name == "Konksud"
      # ...AND multilang data is set so the category renders correctly
      # in mixed-language UIs.
      assert category.data["_primary_language"] == "et"
      assert category.data["et"]["_name"] == "Konksud"
    end

    test "matches existing category by translated name when importing in same language" do
      cat = create_catalogue()

      # Pre-existing category with English primary AND an Estonian translation.
      {:ok, _existing} =
        Catalogue.create_category(%{
          name: "Hooks",
          catalogue_uuid: cat.uuid,
          data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "Hooks"},
            "et" => %{"_name" => "Konksud"}
          }
        })

      plan = %{
        items: [%{name: "Konks", _category_name: "Konksud"}],
        categories_to_create: ["Konksud"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self(), language: "et")

      # Reused the existing category, didn't create a new one.
      assert result.created == 1
      assert result.categories_created == 0

      categories = Catalogue.list_categories_for_catalogue(cat.uuid)
      assert length(categories) == 1
      [category] = categories
      assert category.name == "Hooks"
    end

    test "without :match_categories_across_languages, only the current language is matched" do
      cat = create_catalogue()

      # Category whose ONLY translation is in `de` — bare name is also "Hooks".
      {:ok, _existing} =
        Catalogue.create_category(%{
          name: "Hooks",
          catalogue_uuid: cat.uuid,
          data: %{"_primary_language" => "en", "de" => %{"_name" => "Haken"}}
        })

      plan = %{
        items: [%{name: "Konks", _category_name: "Haken"}],
        categories_to_create: ["Haken"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      # Importing in et — neither the et translation (none) nor bare name
      # ("Hooks") matches "Haken", and we're not allowed to peek into
      # `de`, so a NEW category gets created.
      result = Executor.execute(plan, cat.uuid, self(), language: "et")

      assert result.categories_created == 1
      assert length(Catalogue.list_categories_for_catalogue(cat.uuid)) == 2
    end

    test "with :match_categories_across_languages, matches against any language's translation" do
      cat = create_catalogue()

      {:ok, _existing} =
        Catalogue.create_category(%{
          name: "Hooks",
          catalogue_uuid: cat.uuid,
          data: %{"_primary_language" => "en", "de" => %{"_name" => "Haken"}}
        })

      plan = %{
        items: [%{name: "Konks", _category_name: "Haken"}],
        categories_to_create: ["Haken"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      # Same setup as above, but with the cross-language flag on we
      # match the German translation and reuse the existing category.
      result =
        Executor.execute(plan, cat.uuid, self(),
          language: "et",
          match_categories_across_languages: true
        )

      assert result.categories_created == 0
      assert length(Catalogue.list_categories_for_catalogue(cat.uuid)) == 1
    end

    test "matches existing category by bare name as fallback when no translation set" do
      cat = create_catalogue()

      # Pre-existing English-primary category with NO Estonian translation yet.
      {:ok, _existing} =
        Catalogue.create_category(%{
          name: "Hooks",
          catalogue_uuid: cat.uuid,
          data: %{"_primary_language" => "en", "en" => %{"_name" => "Hooks"}}
        })

      plan = %{
        items: [%{name: "Hook A", _category_name: "Hooks"}],
        categories_to_create: ["Hooks"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self(), language: "et")

      # Matched by bare `name` since there's no et translation to match against.
      assert result.created == 1
      assert result.categories_created == 0
      assert length(Catalogue.list_categories_for_catalogue(cat.uuid)) == 1
    end

    test "reuses existing categories instead of creating duplicates" do
      cat = create_catalogue()
      {:ok, _existing_cat} = Catalogue.create_category(%{name: "Hooks", catalogue_uuid: cat.uuid})

      plan = %{
        items: [%{name: "Hook A", _category_name: "Hooks"}],
        categories_to_create: ["Hooks"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      assert result.categories_created == 0
      assert result.created == 1

      # Should still only have 1 category
      categories = Catalogue.list_categories_for_catalogue(cat.uuid)
      assert length(categories) == 1
    end

    test "stores custom data fields" do
      cat = create_catalogue()

      plan = %{
        items: [
          %{name: "Panel", data: %{"color" => "Natural Oak", "original_unit" => "TK"}}
        ],
        categories_to_create: [],
        custom_fields: ["color", "original_unit"],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())
      assert result.created == 1

      [item] = Catalogue.list_items()
      assert item.data["color"] == "Natural Oak"
      assert item.data["original_unit"] == "TK"
    end
  end

  defp create_category(catalogue, attrs \\ %{}) do
    {:ok, c} =
      Catalogue.create_category(
        Map.merge(%{name: "Test Category", catalogue_uuid: catalogue.uuid}, attrs)
      )

    c
  end
end
