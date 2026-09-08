defmodule PhoenixKitCatalogue.Catalogue.TranslationsTest do
  @moduledoc """
  Unit tests for `PhoenixKitCatalogue.Catalogue.Translations`'
  `translated_seo_title/2` and `translated_seo_description/2` (Block 1,
  Task 3) — previously untested. Unlike `translated_name/2` /
  `translated_description/2`, these have no DB-column counterpart to
  fall back to: `seo_title`/`seo_description` only ever live under the
  multilang `data` override.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Catalogue.Translations

  describe "translated_seo_title/2" do
    test "returns the locale's override when present" do
      record = %{
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_seo_title" => "Buy Vase"}
        }
      }

      assert Translations.translated_seo_title(record, "en-US") == "Buy Vase"
    end

    test "returns nil when the locale has no seo_title override" do
      record = %{
        data: %{"_primary_language" => "en-US", "en-US" => %{"_name" => "Vase"}}
      }

      assert Translations.translated_seo_title(record, "en-US") == nil
    end

    test "returns nil for a nil locale" do
      record = %{data: %{"_primary_language" => "en-US", "en-US" => %{"_seo_title" => "x"}}}
      assert Translations.translated_seo_title(record, nil) == nil
    end

    test "returns nil for a nil record" do
      assert Translations.translated_seo_title(nil, "en-US") == nil
    end

    test "has no DB-column fallback, unlike translated_name/2" do
      # A record with no `:data` at all (so `safe_translation/2` rescues
      # to `%{}`) and, for contrast, a top-level `:seo_title` key that
      # must NOT be used as a fallback — there is no such column in the
      # schema, so the absence of a match must stay nil rather than
      # silently reading an unrelated field.
      record = %{name: "Vase", seo_title: "Should never surface"}

      assert Translations.translated_seo_title(record, "en-US") == nil
    end
  end

  describe "translated_seo_description/2" do
    test "returns the locale's override when present" do
      record = %{
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_seo_description" => "Nice vase"}
        }
      }

      assert Translations.translated_seo_description(record, "en-US") == "Nice vase"
    end

    test "returns nil when the locale has no seo_description override" do
      record = %{
        data: %{"_primary_language" => "en-US", "en-US" => %{"_name" => "Vase"}}
      }

      assert Translations.translated_seo_description(record, "en-US") == nil
    end

    test "returns nil for a nil locale" do
      record = %{
        data: %{"_primary_language" => "en-US", "en-US" => %{"_seo_description" => "x"}}
      }

      assert Translations.translated_seo_description(record, nil) == nil
    end

    test "returns nil for a nil record" do
      assert Translations.translated_seo_description(nil, "en-US") == nil
    end

    test "has no DB-column fallback, unlike translated_description/2" do
      record = %{description: "Vase", seo_description: "Should never surface"}

      assert Translations.translated_seo_description(record, "en-US") == nil
    end
  end
end
