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

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Catalogue.Translations

  describe "translated_name/2 — primary-locale column precedence" do
    test "primary locale: column and bucket disagree, column wins (the bug)" do
      record = %{
        name: "Fresh Column Title",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_name" => "Stale Bucket Title"}
        }
      }

      assert Translations.translated_name(record, "en-US") == "Fresh Column Title"
    end

    test "primary locale: nil column, bucket populated, bucket wins (legacy row)" do
      record = %{
        name: nil,
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_name" => "Only In Bucket"}
        }
      }

      assert Translations.translated_name(record, "en-US") == "Only In Bucket"
    end

    test "primary locale: blank-string column, bucket populated, bucket wins" do
      record = %{
        name: "",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_name" => "Only In Bucket"}
        }
      }

      assert Translations.translated_name(record, "en-US") == "Only In Bucket"
    end

    test "secondary locale: bucket override wins, exactly as today" do
      record = %{
        name: "Column Title",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_name" => "EN Title"},
          "de" => %{"_name" => "DE Title"}
        }
      }

      assert Translations.translated_name(record, "de") == "DE Title"
    end

    test "secondary locale: no override, falls back to the primary-language bucket, not the column" do
      # Column deliberately disagrees with the primary bucket to prove a
      # secondary-locale read still resolves through the multilang merge
      # (today's behavior) rather than picking up our new column
      # preference, which only applies when locale == the record's own
      # primary language.
      record = %{
        name: "Stale Column",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_name" => "Fresh Primary Bucket"}
        }
      }

      assert Translations.translated_name(record, "de") == "Fresh Primary Bucket"
    end

    test "record's own primary language decides, not the system default" do
      sysdefault = Multilang.primary_language()
      own_primary = if sysdefault == "de", do: "fr", else: "de"

      record = %{
        name: "Fresh Column (record's own primary)",
        data: %{
          "_primary_language" => own_primary,
          own_primary => %{"_name" => "Stale Bucket (record's own primary)"}
        }
      }

      assert Translations.translated_name(record, own_primary) ==
               "Fresh Column (record's own primary)"
    end

    test "degenerate: nil record" do
      assert Translations.translated_name(nil, "en-US") == nil
    end

    test "degenerate: nil locale returns the column untouched" do
      record = %{name: "Column Title", data: %{"_primary_language" => "en-US"}}
      assert Translations.translated_name(record, nil) == "Column Title"
    end

    test "degenerate: data is nil, falls back to the column" do
      record = %{name: "Column Title", data: nil}
      assert Translations.translated_name(record, "en-US") == "Column Title"
    end

    test "degenerate: non-multilang flat data does not crash" do
      record = %{name: "Consistent Value", data: %{"name" => "Consistent Value"}}

      assert Translations.translated_name(record, Multilang.primary_language()) ==
               "Consistent Value"
    end

    test "degenerate: plain map with no :name key falls back to the bucket" do
      record = %{
        data: %{"_primary_language" => "en-US", "en-US" => %{"_name" => "Only Bucket"}}
      }

      assert Translations.translated_name(record, "en-US") == "Only Bucket"
    end
  end

  describe "translated_description/2 — primary-locale column precedence" do
    test "primary locale: column and bucket disagree, column wins (the bug)" do
      record = %{
        description: "Fresh Column Description",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_description" => "Stale Bucket Description"}
        }
      }

      assert Translations.translated_description(record, "en-US") == "Fresh Column Description"
    end

    test "primary locale: nil column, bucket populated, bucket wins (legacy row)" do
      record = %{
        description: nil,
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_description" => "Only In Bucket"}
        }
      }

      assert Translations.translated_description(record, "en-US") == "Only In Bucket"
    end

    test "primary locale: blank-string column, bucket populated, bucket wins" do
      record = %{
        description: "",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_description" => "Only In Bucket"}
        }
      }

      assert Translations.translated_description(record, "en-US") == "Only In Bucket"
    end

    test "secondary locale: bucket override wins, exactly as today" do
      record = %{
        description: "Column Description",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_description" => "EN Description"},
          "de" => %{"_description" => "DE Description"}
        }
      }

      assert Translations.translated_description(record, "de") == "DE Description"
    end

    test "secondary locale: no override, falls back to the primary-language bucket, not the column" do
      record = %{
        description: "Stale Column",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_description" => "Fresh Primary Bucket"}
        }
      }

      assert Translations.translated_description(record, "de") == "Fresh Primary Bucket"
    end

    test "record's own primary language decides, not the system default" do
      sysdefault = Multilang.primary_language()
      own_primary = if sysdefault == "de", do: "fr", else: "de"

      record = %{
        description: "Fresh Column (record's own primary)",
        data: %{
          "_primary_language" => own_primary,
          own_primary => %{"_description" => "Stale Bucket (record's own primary)"}
        }
      }

      assert Translations.translated_description(record, own_primary) ==
               "Fresh Column (record's own primary)"
    end

    test "degenerate: nil record" do
      assert Translations.translated_description(nil, "en-US") == nil
    end

    test "degenerate: nil locale returns the column untouched" do
      record = %{description: "Column Description", data: %{"_primary_language" => "en-US"}}
      assert Translations.translated_description(record, nil) == "Column Description"
    end

    test "degenerate: data is nil, falls back to the column" do
      record = %{description: "Column Description", data: nil}
      assert Translations.translated_description(record, "en-US") == "Column Description"
    end

    test "degenerate: non-multilang flat data does not crash" do
      record = %{description: "Consistent Value", data: %{"description" => "Consistent Value"}}

      assert Translations.translated_description(record, Multilang.primary_language()) ==
               "Consistent Value"
    end

    test "degenerate: plain map with no :description key falls back to the bucket" do
      record = %{
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_description" => "Only Bucket"}
        }
      }

      assert Translations.translated_description(record, "en-US") == "Only Bucket"
    end
  end

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
