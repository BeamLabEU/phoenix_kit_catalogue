defmodule PhoenixKitCatalogue.API.SetTranslationsTest do
  @moduledoc "`catalogue.set_translations` (spec 6.1, 6.4)."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_item: 1]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.ApiCase

  @tool "catalogue.set_translations"

  setup do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    {:ok, _} = Languages.add_language("fr-FR")
    on_exit(fn -> Languages.disable_system() end)

    %{
      catalogue: fixture_catalogue(%{name: "Translations Cat"}),
      primary: Multilang.primary_language()
    }
  end

  defp item(catalogue, name, extra \\ %{}),
    do: fixture_item(Map.merge(%{name: name, catalogue_uuid: catalogue.uuid}, extra))

  defp translate(catalogue, entries, overrides \\ %{}),
    do: ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid, "items" => entries}, overrides)

  defp entry(item, translations),
    do: %{"ref" => %{"id" => item.uuid}, "translations" => translations}

  defp rows({:ok, %{"results" => rows}}), do: rows

  test "writes the buckets and a generated slug, leaves everything else, and logs the diff",
       %{catalogue: catalogue, primary: primary} do
    a =
      item(catalogue, "Oak panel", %{
        description: "Solid oak",
        slug: %{primary => "oak-panel"},
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

    result =
      translate(catalogue, [
        entry(a, %{
          "de-DE" => %{
            "name" => "Eichenplatte",
            "description" => "Massiv",
            "seo_title" => "Eiche kaufen"
          }
        })
      ])

    assert {:ok, %{"summary" => %{"updated" => 1}}} = result

    reread = Catalogue.get_item!(a.uuid)
    assert reread.data["_primary_language"] == primary

    assert reread.data["de-DE"] == %{
             "_name" => "Eichenplatte",
             "_description" => "Massiv",
             "_seo_title" => "Eiche kaufen"
           }

    assert reread.data["ecommerce"] == %{"shop_status" => "active"}
    assert reread.name == "Oak panel"
    assert reread.description == "Solid oak"
    assert reread.slug == %{primary => "oak-panel", "de-DE" => "eichenplatte"}

    log =
      assert_activity_logged("item.updated",
        resource_uuid: a.uuid,
        actor_uuid: ApiCase.user_uuid()
      )

    assert log.metadata["via"] == "api"
    assert log.metadata["tool"] == "catalogue.set_translations"
    assert log.metadata["changes"]["data.de-DE._name"] == %{"from" => "", "to" => "Eichenplatte"}
    assert log.metadata["changes"]["slug.de-DE"] == %{"from" => "", "to" => "eichenplatte"}
    assert log.metadata["changes"]["data._primary_language"] == %{"from" => "", "to" => primary}

    assert {:ok, %{"results" => [%{"item" => %{"translations" => translations}}]}} =
             ApiCase.call("catalogue.get_products", %{
               "catalogue_id" => catalogue.uuid,
               "refs" => [%{"id" => a.uuid}],
               "fields" => ["translations"]
             })

    assert translations["de-DE"]["name"] == "Eichenplatte"
    assert translations["de-DE"]["slug"] == "eichenplatte"
    assert translations[primary]["name"] == "Oak panel"
  end

  test "an item that is already multilang keeps its other buckets", %{
    catalogue: catalogue,
    primary: primary
  } do
    a =
      item(catalogue, "Oak panel", %{
        data: %{
          "_primary_language" => primary,
          primary => %{"_name" => "Oak panel"},
          "fr-FR" => %{"_name" => "Panneau"}
        }
      })

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             translate(catalogue, [entry(a, %{"de-DE" => %{"name" => "Platte"}})])

    data = Catalogue.get_item!(a.uuid).data
    assert data["fr-FR"] == %{"_name" => "Panneau"}
    assert data[primary] == %{"_name" => "Oak panel"}
    assert data["de-DE"] == %{"_name" => "Platte"}

    log = assert_activity_logged("item.updated", resource_uuid: a.uuid)
    refute Map.has_key?(log.metadata["changes"], "data._primary_language")
  end

  test "an explicit slug is normalised and capped at a word boundary", %{catalogue: catalogue} do
    a = item(catalogue, "Oak")
    b = item(catalogue, "Pine")
    long = String.duplicate("wordy ", 30)

    assert {:ok, %{"summary" => %{"updated" => 2}}} =
             translate(catalogue, [
               entry(a, %{"de-DE" => %{"slug" => "My Great Slug!"}}),
               entry(b, %{"de-DE" => %{"slug" => long}})
             ])

    assert Catalogue.get_item!(a.uuid).slug["de-DE"] == "my-great-slug"

    capped = Catalogue.get_item!(b.uuid).slug["de-DE"]
    assert String.length(capped) <= 60
    assert String.starts_with?(capped, "wordy-wordy")
    refute String.ends_with?(capped, "-")
  end

  test "an explicit slug another item holds is refused; nothing else of that row is written",
       %{catalogue: catalogue} do
    item(catalogue, "Holder", %{slug: %{"de-DE" => "belegt"}})
    a = item(catalogue, "Oak")

    assert [row] =
             rows(
               translate(catalogue, [
                 entry(a, %{"de-DE" => %{"slug" => "belegt", "name" => "Eiche"}})
               ])
             )

    assert row["action"] == "error"
    assert row["error"]["code"] == "validation_failed"
    assert [%{"path" => "translations.de-DE.slug"}] = row["error"]["context"]["errors"]

    reread = Catalogue.get_item!(a.uuid)
    assert reread.slug == %{}
    refute Map.has_key?(reread.data, "de-DE")
  end

  test "a generated slug that is taken gets -2; two items of one request get different ones",
       %{catalogue: catalogue} do
    item(catalogue, "Holder", %{slug: %{"de-DE" => "eiche"}})
    a = item(catalogue, "Oak A")
    b = item(catalogue, "Oak B")
    c = item(catalogue, "Oak C")

    assert {:ok, %{"summary" => %{"updated" => 3}}} =
             translate(catalogue, [
               entry(a, %{"de-DE" => %{"name" => "Eiche"}}),
               entry(b, %{"de-DE" => %{"name" => "Eiche"}}),
               entry(c, %{"de-DE" => %{"name" => "Eiche"}})
             ])

    slugs = for i <- [a, b, c], do: Catalogue.get_item!(i.uuid).slug["de-DE"]
    assert Enum.sort(slugs) == ["eiche-2", "eiche-3", "eiche-4"]
  end

  test "an existing slug is never rewritten by a name", %{catalogue: catalogue} do
    a = item(catalogue, "Oak", %{slug: %{"de-DE" => "alt"}})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             translate(catalogue, [entry(a, %{"de-DE" => %{"name" => "Ganz anders"}})])

    assert Catalogue.get_item!(a.uuid).slug["de-DE"] == "alt"
  end

  test "null clears a field, prunes an empty bucket and removes the slug", %{catalogue: catalogue} do
    a = item(catalogue, "Oak")

    {:ok, _} =
      translate(catalogue, [entry(a, %{"de-DE" => %{"name" => "Eiche", "seo_title" => "T"}})])

    assert Catalogue.get_item!(a.uuid).slug["de-DE"] == "eiche"

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             translate(catalogue, [
               entry(a, %{"de-DE" => %{"name" => nil, "seo_title" => nil, "slug" => nil}})
             ])

    reread = Catalogue.get_item!(a.uuid)
    refute Map.has_key?(reread.data, "de-DE")
    refute Map.has_key?(reread.slug, "de-DE")
  end

  test "only a slug on flat data does not turn the item multilang", %{catalogue: catalogue} do
    a = item(catalogue, "Oak", %{data: %{"meta" => %{"k" => "v"}}})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             translate(catalogue, [entry(a, %{"de-DE" => %{"slug" => "eiche"}})])

    reread = Catalogue.get_item!(a.uuid)
    assert reread.slug["de-DE"] == "eiche"
    assert reread.data == %{"meta" => %{"k" => "v"}}
  end

  test "a bare code resolves to the one enabled dialect; unknown and disabled codes list the enabled ones",
       %{catalogue: catalogue} do
    a = item(catalogue, "Oak")

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             translate(catalogue, [entry(a, %{"fr" => %{"name" => "Chêne"}})])

    assert Catalogue.get_item!(a.uuid).data["fr-FR"] == %{"_name" => "Chêne"}

    for bad <- ["xx", "es-ES", "Deutsch"] do
      assert [row] = rows(translate(catalogue, [entry(a, %{bad => %{"name" => "x"}})]))
      assert row["action"] == "error", "#{bad} was accepted"
      assert row["error"]["code"] == "validation_failed"
      assert "de-DE" in row["error"]["context"]["allowed"]
      assert "fr-FR" in row["error"]["context"]["allowed"]
    end
  end

  test "a bare code that matches two enabled dialects is ambiguous", %{catalogue: catalogue} do
    {:ok, _} = Languages.add_language("de-AT")
    a = item(catalogue, "Oak")

    assert [row] = rows(translate(catalogue, [entry(a, %{"de" => %{"name" => "Eiche"}})]))
    assert row["action"] == "error"
    assert row["error"]["message"] =~ "several"
    assert Enum.sort(row["error"]["context"]["allowed"]) == ["de-AT", "de-DE"]
  end

  test "two keys that mean one language are refused", %{catalogue: catalogue} do
    a = item(catalogue, "Oak")

    assert [row] =
             rows(
               translate(catalogue, [
                 entry(a, %{"fr" => %{"name" => "A"}, "fr-FR" => %{"name" => "B"}})
               ])
             )

    assert row["action"] == "error"
    assert Catalogue.get_item!(a.uuid).data == %{}
  end

  test "the primary language is refused, in full and as a bare code", %{
    catalogue: catalogue,
    primary: primary
  } do
    a = item(catalogue, "Oak")
    base = DialectMapper.extract_base(primary)

    for key <- [primary, base] do
      assert [row] = rows(translate(catalogue, [entry(a, %{key => %{"name" => "Other name"}})]))
      assert row["action"] == "error", "#{key} was accepted"
      assert row["error"]["message"] =~ "catalogue.update_products"
    end

    reread = Catalogue.get_item!(a.uuid)
    assert reread.name == "Oak"
    assert reread.data == %{}
  end

  test "an item whose stored primary language is a bare code refuses its enabled dialect",
       %{catalogue: catalogue} do
    data = %{"_primary_language" => "de", "de" => %{"_name" => "Eiche"}}
    a = item(catalogue, "Oak", %{data: data})

    assert [row] = rows(translate(catalogue, [entry(a, %{"de-DE" => %{"name" => "Andere"}})]))
    assert row["action"] == "error"
    assert row["error"]["message"] =~ "catalogue.update_products"
    assert Catalogue.get_item!(a.uuid).data == data
  end

  test "flat data with bare translation keys is refused and left alone", %{catalogue: catalogue} do
    a = item(catalogue, "Oak", %{data: %{"name" => "legacy", "ecommerce" => %{"k" => 1}}})

    assert [row] = rows(translate(catalogue, [entry(a, %{"de-DE" => %{"name" => "Eiche"}})]))
    assert row["action"] == "error"
    assert row["error"]["message"] =~ "legacy"
    assert Catalogue.get_item!(a.uuid).data == %{"name" => "legacy", "ecommerce" => %{"k" => 1}}
  end

  test "bad rows are reported at their position and never poison the others", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Oak")
    b = item(catalogue, "Pine")
    item(catalogue, "Twin 1", %{sku: "TWIN"})
    item(catalogue, "Twin 2", %{sku: "TWIN"})

    result =
      translate(catalogue, [
        entry(a, %{"de-DE" => %{"name" => "Eiche"}}),
        %{"ref" => %{"sku" => "TWIN"}, "translations" => %{"de-DE" => %{"name" => "Zwilling"}}},
        entry(b, %{}),
        entry(b, %{"de-DE" => %{}}),
        entry(b, %{"de-DE" => %{"name" => "   "}}),
        entry(a, %{"fr-FR" => %{"name" => "Chêne"}}),
        entry(b, %{"de-DE" => %{"name" => "Kiefer"}})
      ])

    rows = rows(result)

    assert Enum.map(rows, & &1["action"]) ==
             ["updated", "error", "error", "error", "error", "error", "updated"]

    assert Enum.map(rows, &get_in(&1, ["error", "code"])) ==
             [
               nil,
               "ambiguous_ref",
               "validation_failed",
               "validation_failed",
               "validation_failed",
               "validation_failed",
               nil
             ]

    assert Catalogue.get_item!(a.uuid).data["de-DE"] == %{"_name" => "Eiche"}
    refute Map.has_key?(Catalogue.get_item!(a.uuid).data, "fr-FR")
    assert Catalogue.get_item!(b.uuid).data["de-DE"] == %{"_name" => "Kiefer"}
  end

  test "the schema refuses unknown fields at both levels and a non-object translations", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Oak")

    assert {:error, :validation_failed, _, %{errors: errors}} =
             translate(catalogue, [entry(a, %{"de-DE" => %{"name" => "x", "base_price" => 1}})])

    assert Enum.any?(errors, &(&1.path == "items[0].translations.de-DE.base_price"))

    assert {:error, :validation_failed, _, %{errors: errors}} =
             translate(catalogue, [%{"ref" => %{"id" => a.uuid}, "translations" => "de-DE"}])

    assert Enum.any?(errors, &(&1.path == "items[0].translations"))

    assert {:error, :validation_failed, _, %{errors: errors}} =
             translate(catalogue, [
               %{"ref" => %{"id" => a.uuid}, "translations" => %{"de-DE" => %{"data" => %{}}}}
             ])

    assert Enum.any?(errors, &(&1.path == "items[0].translations.de-DE.data"))
  end

  test "a dry run previews the diff, writes nothing, and the fingerprint follows the state",
       %{catalogue: catalogue, primary: primary} do
    a = item(catalogue, "Oak")
    entries = [entry(a, %{"de-DE" => %{"name" => "Eiche"}})]

    assert {:preview, %{"rows" => [row], "summary" => %{"updated" => 1}}, fingerprint} =
             translate(catalogue, entries, %{dry_run?: true})

    assert row["changes"] == %{
             "data.de-DE._name" => %{"from" => "", "to" => "Eiche"},
             "data._primary_language" => %{"from" => "", "to" => primary},
             "slug.de-DE" => %{"from" => "", "to" => "eiche"}
           }

    reread = Catalogue.get_item!(a.uuid)
    assert reread.data == %{}
    assert reread.slug == %{}
    refute_activity_logged("item.updated", resource_uuid: a.uuid)

    assert {:preview, _, ^fingerprint} = translate(catalogue, entries, %{dry_run?: true})

    {:ok, _} = Catalogue.update_item(reread, %{slug: %{"de-DE" => "schon-da"}})
    assert {:preview, _, other} = translate(catalogue, entries, %{dry_run?: true})
    assert other != fingerprint
  end
end
