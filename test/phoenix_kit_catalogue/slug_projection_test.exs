defmodule PhoenixKitCatalogue.SlugProjectionTest do
  # async: false — one test deliberately triggers a Postgrex.Error
  # (duplicate slug) inside its sandboxed connection; keeping the case
  # serial avoids any cross-test interaction with that aborted
  # transaction.
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  defp create_catalogue(attrs \\ %{}) do
    {:ok, c} = Catalogue.create_catalogue(Map.merge(%{name: unique_name("Catalogue")}, attrs))
    c
  end

  defp create_category(catalogue, attrs \\ %{}) do
    {:ok, c} =
      Catalogue.create_category(
        Map.merge(%{name: unique_name("Category"), catalogue_uuid: catalogue.uuid}, attrs)
      )

    c
  end

  defp create_item(catalogue, attrs \\ %{}) do
    {:ok, i} =
      Catalogue.create_item(
        Map.merge(%{name: unique_name("Item"), catalogue_uuid: catalogue.uuid}, attrs)
      )

    i
  end

  defp unique_name(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"

  # The `slug` schema field doesn't exist until Task 2 — set the DB
  # column directly so this task's trigger projections can be tested in
  # isolation. Postgrex's jsonb extension encodes a plain Elixir map
  # itself, and comparing `uuid::text` sidesteps having to hand-encode
  # the 16-byte binary form of a UUID for a raw parameterized query.
  defp put_slug(table, uuid, slug) do
    Repo.query!("UPDATE #{table} SET slug = $1 WHERE uuid::text = $2", [slug, uuid])
  end

  describe "item slug projection" do
    test "a trigger projects every language of an item's slug" do
      catalogue = create_catalogue()
      item = create_item(catalogue)

      put_slug("phoenix_kit_cat_items", item.uuid, %{
        "en-US" => "red-vase",
        "fr-FR" => "vase-rouge"
      })

      %{rows: rows} =
        Repo.query!(
          "SELECT lang, value FROM phoenix_kit_cat_item_slugs WHERE item_uuid::text = $1 ORDER BY lang",
          [item.uuid]
        )

      assert rows == [["en", "red-vase"], ["fr", "vase-rouge"]]
    end

    test "a duplicate slug in the same language raises the pkey constraint" do
      catalogue = create_catalogue()
      item_a = create_item(catalogue)
      item_b = create_item(catalogue)

      put_slug("phoenix_kit_cat_items", item_a.uuid, %{"en-US" => "red-vase"})

      assert_raise Postgrex.Error, ~r/phoenix_kit_cat_item_slugs_pkey/, fn ->
        put_slug("phoenix_kit_cat_items", item_b.uuid, %{"en-US" => "red-vase"})
      end
    end

    test "updating an item's slug drops the old projected value" do
      catalogue = create_catalogue()
      item = create_item(catalogue)

      put_slug("phoenix_kit_cat_items", item.uuid, %{"en-US" => "red-vase"})
      put_slug("phoenix_kit_cat_items", item.uuid, %{"en-US" => "blue-vase"})

      %{rows: rows} =
        Repo.query!(
          "SELECT value FROM phoenix_kit_cat_item_slugs WHERE item_uuid::text = $1",
          [item.uuid]
        )

      assert rows == [["blue-vase"]]
    end
  end

  describe "category slug projection" do
    test "a trigger projects every language of a category's slug" do
      catalogue = create_catalogue()
      category = create_category(catalogue)

      put_slug("phoenix_kit_cat_categories", category.uuid, %{
        "en-US" => "vases",
        "fr-FR" => "vases-fr"
      })

      %{rows: rows} =
        Repo.query!(
          "SELECT lang, value FROM phoenix_kit_cat_category_slugs WHERE category_uuid::text = $1 ORDER BY lang",
          [category.uuid]
        )

      assert rows == [["en", "vases"], ["fr", "vases-fr"]]
    end

    test "a duplicate category slug in the same language raises the pkey constraint" do
      catalogue = create_catalogue()
      category_a = create_category(catalogue)
      category_b = create_category(catalogue)

      put_slug("phoenix_kit_cat_categories", category_a.uuid, %{"en-US" => "vases"})

      assert_raise Postgrex.Error, ~r/phoenix_kit_cat_category_slugs_pkey/, fn ->
        put_slug("phoenix_kit_cat_categories", category_b.uuid, %{"en-US" => "vases"})
      end
    end
  end
end
