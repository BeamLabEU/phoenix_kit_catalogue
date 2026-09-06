defmodule PhoenixKitCatalogue.TranslationStatusTest do
  @moduledoc """
  Unit coverage for the catalogue translation-freshness model: fingerprint
  hashing, process-dictionary capture at read time, state transitions, and
  `list/2` filtering/pagination. Item/category cases need no live
  `PhoenixKitAI`; the sets cases (entities-backed) are skipped when the
  entities package lacks the Managed contract, same guard as
  `AITranslatableSetsTest`.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.AITranslatable.Sets
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.TranslationStatus

  defp primary, do: Multilang.primary_language()

  defp create_catalogue_with_item(attrs) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, item} =
      Catalogue.create_item(Map.merge(%{name: "Widget", catalogue_uuid: cat.uuid}, attrs))

    {cat, item}
  end

  defp create_item(attrs \\ %{}) do
    {_cat, item} = create_catalogue_with_item(attrs)
    item
  end

  defp create_category(attrs \\ %{}) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, category} =
      Catalogue.create_category(Map.merge(%{name: "Cards", catalogue_uuid: cat.uuid}, attrs))

    category
  end

  describe "fingerprint/1" do
    test "is independent of field order" do
      a = TranslationStatus.fingerprint(%{"name" => "Widget", "description" => "A thing"})
      b = TranslationStatus.fingerprint(%{"description" => "A thing", "name" => "Widget"})
      assert a == b
    end

    test "trims surrounding whitespace" do
      a = TranslationStatus.fingerprint(%{"name" => "Widget"})
      b = TranslationStatus.fingerprint(%{"name" => "  Widget  "})
      assert a == b
    end

    test "differs when a value differs" do
      a = TranslationStatus.fingerprint(%{"name" => "Widget"})
      b = TranslationStatus.fingerprint(%{"name" => "Gadget"})
      refute a == b
    end
  end

  describe "capture_fingerprint/3 + captured_fingerprint/2" do
    test "round-trips within the same process" do
      uuid = Ecto.UUID.generate()
      :ok = TranslationStatus.capture_fingerprint("catalogue_item", uuid, %{"name" => "Widget"})

      assert TranslationStatus.captured_fingerprint("catalogue_item", uuid) ==
               TranslationStatus.fingerprint(%{"name" => "Widget"})
    end

    test "nothing captured → nil" do
      assert TranslationStatus.captured_fingerprint("catalogue_item", Ecto.UUID.generate()) == nil
    end
  end

  describe "state/2 — item" do
    test "no translation → :missing" do
      item = create_item()
      assert TranslationStatus.state(item, "fr") == :missing
    end

    test "translation written outside put_translation/4 → :unknown" do
      item = create_item()

      new_data = AITranslatable.force_put_language(item.data, "fr", %{"_name" => "Widget FR"})
      {:ok, item} = Catalogue.update_item(item, %{data: new_data})

      assert TranslationStatus.state(item, "fr") == :unknown
    end

    test "after put_translation/4 → :fresh" do
      item = create_item()
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert TranslationStatus.state(reloaded, "fr") == :fresh
    end

    test "source changes after a fresh translation → :stale" do
      item = create_item()
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])
      translated = Catalogue.get_item(item.uuid)

      {:ok, _} = Catalogue.update_item(translated, %{name: "Widget Mk2"})
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.state(reloaded, "fr") == :stale
    end

    test "stamp_fresh/2 flips :stale (or :unknown) back to :fresh" do
      item = create_item()

      new_data = AITranslatable.force_put_language(item.data, "fr", %{"_name" => "Widget FR"})
      {:ok, item} = Catalogue.update_item(item, %{data: new_data})
      assert TranslationStatus.state(item, "fr") == :unknown

      assert {:ok, _} = TranslationStatus.stamp_fresh(item, "fr")
      reloaded = Catalogue.get_item(item.uuid)
      assert TranslationStatus.state(reloaded, "fr") == :fresh
    end

    test "stamp_fresh/2 refuses when there is nothing translated" do
      item = create_item()
      assert {:error, :no_translation} = TranslationStatus.stamp_fresh(item, "fr")
    end
  end

  describe "state/2 — category" do
    test "round-trips missing → fresh → stale" do
      category = create_category()
      assert TranslationStatus.state(category, "fr") == :missing

      {:ok, _} = AITranslatable.put_translation(category, "fr", %{"name" => "Cartes"}, [])
      translated = Catalogue.get_category(category.uuid)
      assert TranslationStatus.state(translated, "fr") == :fresh

      {:ok, _} = Catalogue.update_category(translated, %{name: "Cards Mk2"})
      reloaded = Catalogue.get_category(category.uuid)
      assert TranslationStatus.state(reloaded, "fr") == :stale
    end
  end

  describe "process-dictionary capture (write reflects the READ-time source)" do
    test "a source mutation between source_fields/2 and put_translation/4 doesn't affect the write" do
      item = create_item(%{name: "Widget"})

      # Simulate the TranslateWorker's read step.
      _ = AITranslatable.source_fields(item, primary())

      # A sync lands on the row while the (multi-second) AI call is
      # in flight — same race the design source describes (§4.1).
      {:ok, mutated} = Catalogue.update_item(item, %{name: "Mutated"})

      {:ok, _} = AITranslatable.put_translation(mutated, "fr", %{"name" => "Traduit"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      stored_fp = reloaded.data["_translation_fingerprints"]["fr"]
      assert stored_fp == TranslationStatus.fingerprint(%{"name" => "Widget"})
      refute stored_fp == TranslationStatus.fingerprint(%{"name" => "Mutated"})
    end

    test "state/2, a read-only check, does not clobber a fingerprint an in-flight RETRANSLATION job already captured" do
      # `state/2` only reaches the fingerprint-computing branch once a
      # translation already exists for the pair (the :missing branch
      # short-circuits first) — so this reproduces the retranslate case:
      # a resource already translated once, whose source changes again.
      item = create_item(%{name: "Widget"})
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])

      {:ok, v2} = item.uuid |> Catalogue.get_item() |> Catalogue.update_item(%{name: "Widget V2"})

      # Job B's actual read step for the retranslation.
      _ = AITranslatable.source_fields(v2, primary())

      {:ok, v3} = Catalogue.update_item(v2, %{name: "Widget V3"})

      # Something else in the SAME process — e.g. the admin translations
      # page re-checking freshness against the now-latest source — calls
      # the read-only `state/2` in between. It must not go through the
      # capturing `source_fields/2` internally and overwrite what job B
      # already stashed for this uuid.
      assert TranslationStatus.state(v3, "fr") == :stale

      {:ok, _} = AITranslatable.put_translation(v3, "fr", %{"name" => "Widget V2 FR"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      stored_fp = reloaded.data["_translation_fingerprints"]["fr"]
      assert stored_fp == TranslationStatus.fingerprint(%{"name" => "Widget V2"})
      refute stored_fp == TranslationStatus.fingerprint(%{"name" => "Widget V3"})
    end
  end

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    describe "state/2 — sets" do
      setup do
        AttributeSets.register_deletion_guard()
        PhoenixKit.Settings.update_setting("entities_enabled", "true")
        on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
        :ok
      end

      defp create_set!(name \\ "Ikea colors") do
        {:ok, set} = AttributeSets.create_set(%{name: name}, actor_uuid: Ecto.UUID.generate())
        set
      end

      defp create_value!(set, label) do
        {:ok, value} =
          AttributeSets.create_value(set, %{label: label}, actor_uuid: Ecto.UUID.generate())

        value
      end

      test "set label: missing → fresh → stale" do
        set = create_set!("Ikea colors")
        assert TranslationStatus.state(set, "fr-FR") == :missing

        {:ok, _} = Sets.put_translation(set, "fr-FR", %{"label" => "Couleurs"}, [])
        translated = PhoenixKitEntities.get_entity(set.uuid)
        assert TranslationStatus.state(translated, "fr-FR") == :fresh

        {:ok, renamed} = PhoenixKitEntities.update_entity(translated, %{display_name: "Colours"})
        assert TranslationStatus.state(renamed, "fr-FR") == :stale
      end

      test "set label: stamp_fresh flips an unknown pair to fresh" do
        set = create_set!("Ikea colors")

        # Translated outside `put_translation/4` — no fingerprint
        # recorded, so the pair is `:unknown`, not `:missing`/`:stale`.
        {:ok, translated} =
          PhoenixKitEntities.set_entity_translation(set, "fr-FR", %{"display_name" => "Couleurs"})

        assert TranslationStatus.state(translated, "fr-FR") == :unknown

        assert {:ok, _} = TranslationStatus.stamp_fresh(translated, "fr-FR")
        reloaded = PhoenixKitEntities.get_entity(set.uuid)
        assert TranslationStatus.state(reloaded, "fr-FR") == :fresh
      end

      test "value title: missing → fresh → stale, and stamp_fresh flips it back" do
        set = create_set!()
        value = create_value!(set, "Oak")
        assert TranslationStatus.state(value, "fr-FR") == :missing

        {:ok, _} = Sets.put_translation(value, "fr-FR", %{"title" => "Chêne"}, [])
        translated = PhoenixKitEntities.EntityData.get(value.uuid)
        assert TranslationStatus.state(translated, "fr-FR") == :fresh

        {:ok, renamed} = PhoenixKitEntities.EntityData.update(translated, %{title: "Oak Mk2"})
        assert TranslationStatus.state(renamed, "fr-FR") == :stale

        assert {:ok, _} = TranslationStatus.stamp_fresh(renamed, "fr-FR")
        reloaded = PhoenixKitEntities.EntityData.get(value.uuid)
        assert TranslationStatus.state(reloaded, "fr-FR") == :fresh
      end
    end

    describe "list/2 — sets" do
      setup do
        AttributeSets.register_deletion_guard()
        PhoenixKit.Settings.update_setting("entities_enabled", "true")
        on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
        :ok
      end

      test "lists set-label rows across every set" do
        set_a = create_set!("Ikea colors")
        set_b = create_set!("Ikea sizes")

        rows = TranslationStatus.list(:set_label, langs: ["fr-FR"])
        uuids = Enum.map(rows, & &1.uuid)

        assert set_a.uuid in uuids
        assert set_b.uuid in uuids
      end

      test "lists set-value rows for every set's values, not just the first (batched query)" do
        set_a = create_set!("Ikea colors")
        set_b = create_set!("Ikea sizes")
        value_a = create_value!(set_a, "Oak")
        value_b = create_value!(set_b, "Large")

        rows = TranslationStatus.list(:set_value, langs: ["fr-FR"])
        uuids = Enum.map(rows, & &1.uuid)

        assert value_a.uuid in uuids
        assert value_b.uuid in uuids
      end
    end
  end

  describe "list/2 — item" do
    test "filters by state and paginates" do
      {cat, translated} = create_catalogue_with_item(%{name: "Alpha"})
      {:ok, missing} = Catalogue.create_item(%{name: "Beta", catalogue_uuid: cat.uuid})
      {:ok, _other_missing} = Catalogue.create_item(%{name: "Gamma", catalogue_uuid: cat.uuid})

      {:ok, _} = AITranslatable.put_translation(translated, "fr", %{"name" => "Alpha FR"}, [])

      all =
        TranslationStatus.list(:item, catalogue_uuid: cat.uuid, langs: ["fr"], per_page: 50)

      assert length(all) == 3
      assert Enum.find(all, &(&1.uuid == translated.uuid)).state == :fresh
      assert Enum.find(all, &(&1.uuid == missing.uuid)).state == :missing

      missing_only =
        TranslationStatus.list(:item,
          catalogue_uuid: cat.uuid,
          langs: ["fr"],
          state: :missing,
          per_page: 50
        )

      assert length(missing_only) == 2
      assert Enum.all?(missing_only, &(&1.state == :missing))

      page1 =
        TranslationStatus.list(:item,
          catalogue_uuid: cat.uuid,
          langs: ["fr"],
          per_page: 1,
          page: 1
        )

      page2 =
        TranslationStatus.list(:item,
          catalogue_uuid: cat.uuid,
          langs: ["fr"],
          per_page: 1,
          page: 2
        )

      assert length(page1) == 1
      assert length(page2) == 1
      refute hd(page1).uuid == hd(page2).uuid
    end
  end
end
