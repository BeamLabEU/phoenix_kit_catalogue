defmodule PhoenixKitCatalogue.Catalogue.SlugsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Catalogue.Slugs
  alias PhoenixKitCatalogue.Schemas.Item

  describe "from_title/3" do
    test "uses the head segment before a pipe" do
      assert Slugs.from_title("Étagère Murale | Étagères Imprimées", "fr-FR") ==
               "etagere-murale"
    end

    test "uses the head segment before a spaced dash" do
      assert Slugs.from_title("Vase en Bois - Édition Limitée", "fr-FR") == "vase-en-bois"
    end

    test "caps at 60 characters on a word boundary" do
      title = Enum.map_join(1..10, " ", &"wordword#{&1}")
      slug = Slugs.from_title(title, "en-US")

      assert String.length(slug) <= 60
      refute String.ends_with?(slug, "-")
      assert Enum.all?(String.split(slug, "-"), &(&1 =~ ~r/^wordword\d+$/))
    end

    test "an unromanizable title falls back to a stable item-<hash> slug" do
      assert Slugs.from_title("測試", "fr-FR") == "item-" <> hash("測試")
    end

    test "the identity tail is NOT carried when the title falls back to the hash" do
      slug = Slugs.from_title("測試", "fr-FR", default_slug: "wooden-vase-22153")

      refute slug =~ "22153"
      assert slug == "item-" <> hash("測試")
    end

    test "a numeric identity tail is carried from the default slug" do
      assert Slugs.from_title("Vase en Bois", "fr-FR", default_slug: "wooden-vase-22153") ==
               "vase-en-bois-22153"
    end

    test "the tail is not duplicated when the derived slug already ends with it" do
      assert Slugs.from_title("Vase en Bois 22153", "fr-FR", default_slug: "wooden-vase-22153") ==
               "vase-en-bois-22153"
    end

    test "no tail is carried when the default slug has none" do
      assert Slugs.from_title("Vase en Bois", "fr-FR", default_slug: "wooden-vase") ==
               "vase-en-bois"
    end

    defp hash(text) do
      :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    end
  end

  describe "maybe_generate/3" do
    test "fills a missing language from the multilang name and keeps an existing one" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: "Wooden Vase",
          slug: %{"en-US" => "wooden-vase"},
          data: %{
            "_primary_language" => "en-US",
            "en-US" => %{"_name" => "Wooden Vase"},
            "fr-FR" => %{"_name" => "Vase en Bois"}
          }
        })

      updated = Slugs.maybe_generate(changeset, :slug, from: :name)
      slug = Ecto.Changeset.get_field(updated, :slug)

      assert slug["en-US"] == "wooden-vase"
      assert slug["fr-FR"] == "vase-en-bois"
    end

    test "carries the primary language's identity tail onto a generated secondary slug" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: "Wooden Vase",
          slug: %{"en-US" => "wooden-vase-22153"},
          data: %{
            "_primary_language" => "en-US",
            "en-US" => %{"_name" => "Wooden Vase"},
            "fr-FR" => %{"_name" => "Vase en Bois"}
          }
        })

      updated = Slugs.maybe_generate(changeset, :slug, from: :name)
      slug = Ecto.Changeset.get_field(updated, :slug)

      assert slug["fr-FR"] == "vase-en-bois-22153"
    end

    test "does nothing when every present language already has a slug" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: "Wooden Vase",
          slug: %{"en-US" => "wooden-vase"},
          data: %{"_primary_language" => "en-US", "en-US" => %{"_name" => "Wooden Vase"}}
        })

      updated = Slugs.maybe_generate(changeset, :slug, from: :name)

      assert updated == changeset
    end

    test "does nothing when the derivable title is blank" do
      changeset =
        %Item{}
        |> Ecto.Changeset.change(%{
          name: nil,
          slug: %{},
          data: %{"_primary_language" => "en-US", "en-US" => %{}}
        })

      updated = Slugs.maybe_generate(changeset, :slug, from: :name)

      assert Ecto.Changeset.get_field(updated, :slug) == %{}
    end
  end
end
