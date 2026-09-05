defmodule PhoenixKitCatalogue.Web.ItemFormSeoTest do
  @moduledoc """
  LiveView tests for the item form's per-language `slug` input and
  translatable `seo_title`/`seo_description` fields (Block 1, Task 3).

  Multilang is DB-settings-backed (see
  `PhoenixKitCatalogue.MultilangPreserveConformanceTest`'s moduledoc), so
  every test here enables the Languages module with two languages
  before mounting — without it `@multilang_enabled` stays `false` and
  `merge_translatable_params/4` never touches `data` at all.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Translations

  @base "/en/admin/catalogue"

  defp edit_item_url(item_uuid), do: "#{@base}/items/#{item_uuid}/edit"

  defp enable_multilang! do
    {:ok, _} = PhoenixKit.Modules.Languages.enable_system()
    {:ok, _} = PhoenixKit.Modules.Languages.add_language("fr-FR")
    :ok
  end

  describe "slug + seo fields on save" do
    test "stores seo_title/seo_description under the primary language and the per-language slug",
         %{conn: conn} do
      enable_multilang!()
      catalogue = fixture_catalogue()
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      view
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "item" => %{
          "name" => "Vase",
          "seo_title" => "Buy Vase",
          "seo_description" => "Nice",
          "slug" => %{"en-US" => "vase"}
        }
      })
      |> render_submit()

      saved = Catalogue.get_item!(item.uuid)

      assert Translations.get_translation(saved, "en-US")["_seo_title"] == "Buy Vase"
      assert Translations.get_translation(saved, "en-US")["_seo_description"] == "Nice"
      assert saved.slug["en-US"] == "vase"
    end

    test "an item form with no ecommerce extension still renders the slug and seo inputs", %{
      conn: conn
    } do
      enable_multilang!()
      catalogue = fixture_catalogue()
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase"})

      {:ok, _view, html} = live(conn, edit_item_url(item.uuid))

      assert html =~ ~s(name="item[slug][en-US]")
      assert html =~ ~s(name="item[seo_title]")
      assert html =~ ~s(name="item[seo_description]")
    end
  end

  describe "slug uniqueness" do
    test "a duplicate slug in the same language shows a constraint error and does not save", %{
      conn: conn
    } do
      enable_multilang!()
      catalogue = fixture_catalogue()

      _taken =
        fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Other", slug: %{"en-US" => "vase"}})

      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase 2"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      html =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => %{"name" => "Vase 2", "slug" => %{"en-US" => "vase"}}
        })
        |> render_submit()

      assert has_element?(view, "[phx-feedback-for='item[slug][en-US]'] .text-error") or
               html =~ "already taken"

      reloaded = Catalogue.get_item!(item.uuid)
      refute reloaded.slug["en-US"] == "vase"
    end
  end
end
