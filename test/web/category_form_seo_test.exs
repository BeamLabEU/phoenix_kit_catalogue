defmodule PhoenixKitCatalogue.Web.CategoryFormSeoTest do
  @moduledoc """
  LiveView tests for the category form's per-language `slug` input and
  translatable `seo_title`/`seo_description` fields (Block 1, Task 3).

  See `PhoenixKitCatalogue.Web.ItemFormSeoTest`'s moduledoc for why
  multilang must be explicitly enabled for these tests to exercise the
  per-language branches.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Translations

  @base "/en/admin/catalogue"

  defp edit_category_url(uuid), do: "#{@base}/categories/#{uuid}/edit"

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
      category = fixture_category(catalogue, %{name: "Vases"})

      {:ok, view, _html} = live(conn, edit_category_url(category.uuid))

      view
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "category" => %{
          "name" => "Vases",
          "seo_title" => "Buy Vases",
          "seo_description" => "Nice vases",
          "slug" => %{"en-US" => "vases"}
        }
      })
      |> render_submit()

      saved = Catalogue.get_category!(category.uuid)

      assert Translations.get_translation(saved, "en-US")["_seo_title"] == "Buy Vases"
      assert Translations.get_translation(saved, "en-US")["_seo_description"] == "Nice vases"
      assert saved.slug["en-US"] == "vases"
    end

    test "a category form with no ecommerce extension still renders the slug and seo inputs", %{
      conn: conn
    } do
      enable_multilang!()
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Vases"})

      {:ok, _view, html} = live(conn, edit_category_url(category.uuid))

      assert html =~ ~s(name="category[slug][en-US]")
      assert html =~ ~s(name="category[seo_title]")
      assert html =~ ~s(name="category[seo_description]")
    end
  end

  describe "slug uniqueness" do
    test "a duplicate slug in the same language shows a constraint error and does not save", %{
      conn: conn
    } do
      enable_multilang!()
      catalogue = fixture_catalogue()

      _taken =
        fixture_category(catalogue, %{name: "Other", slug: %{"en-US" => "vases"}})

      category = fixture_category(catalogue, %{name: "Vases 2"})

      {:ok, view, _html} = live(conn, edit_category_url(category.uuid))

      html =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "category" => %{"name" => "Vases 2", "slug" => %{"en-US" => "vases"}}
        })
        |> render_submit()

      assert has_element?(view, "[phx-feedback-for='category[slug][en-US]'] .text-error") or
               html =~ "already taken"

      reloaded = Catalogue.get_category!(category.uuid)
      refute reloaded.slug["en-US"] == "vases"
    end
  end
end
