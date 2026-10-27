defmodule PhoenixKitCatalogue.Web.AITranslatePromptTest do
  @moduledoc """
  Regression coverage for the in-form AI-translate button on item/category
  forms: `assign_ai_translation/3` (`Web.Helpers`) must preselect the
  catalogue's own translation prompt (`AIPrompt.ensure_prompt/0`), not the
  shared `phoenixkit-translate-content` default `FormGlue` falls back to.

  The shared prompt has no `seo_title`/`seo_description`/`summary` slots
  (block-6 plan, Task 1 widened `field_columns/1` to include them), so
  dispatching a translation on the shared prompt fails every job with
  `{:missing_fields, [...]}`. Multilang is DB-settings-backed — see
  `ItemFormSeoTest`'s moduledoc — so every test here enables the Languages
  module with a second language before mounting.

  Oban isn't started by the catalogue test environment (see
  `TranslationSweepWorkerTest`'s notes) — each test starts its own
  `:manual`-mode instance against the sandboxed test repo.
  """

  use PhoenixKitCatalogue.LiveCase
  use Oban.Testing, repo: PhoenixKitCatalogue.Test.Repo

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitAI.TranslateWorker
  alias PhoenixKitCatalogue.AIPrompt

  @base "/en/admin/catalogues"
  @lang "fr-FR"

  defp edit_item_url(uuid), do: "#{@base}/items/#{uuid}/edit"
  defp edit_category_url(uuid), do: "#{@base}/categories/#{uuid}/edit"

  defp translate_worker_jobs, do: all_enqueued(worker: TranslateWorker)

  defp enable_multilang! do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language(@lang)
    :ok
  end

  # The modal events re-check the `catalogue` key (`Web.AITranslateGate`).
  setup %{conn: conn} do
    register_catalogue_module()
    {:ok, conn: with_permissions(conn, ["catalogue"])}
  end

  setup do
    start_supervised!({Oban, repo: PhoenixKitCatalogue.Test.Repo, testing: :manual})
    enable_multilang!()

    {:ok, _} = PhoenixKitAI.enable_system()

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Test Endpoint",
        provider: "openrouter",
        api_key: "test-key",
        model: "openai/gpt-4o-mini",
        enabled: true
      })

    on_exit(fn -> PhoenixKitAI.disable_system() end)

    %{endpoint: endpoint}
  end

  describe "item form" do
    test "dispatching an AI translation enqueues a job on the catalogue prompt", %{conn: conn} do
      catalogue = fixture_catalogue()
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "ai_translate_lang", %{"lang" => "*"})

      assert {:ok, catalogue_prompt_uuid} = AIPrompt.ensure_prompt()
      shared_default = PhoenixKitAI.Translations.default_prompt_uuid()

      assert [%{args: %{"resource_uuid" => uuid, "prompt_uuid" => prompt_uuid}} | _] =
               translate_worker_jobs()

      assert uuid == item.uuid
      assert prompt_uuid == catalogue_prompt_uuid
      refute prompt_uuid == shared_default
    end
  end

  describe "category form" do
    test "dispatching an AI translation enqueues a job on the catalogue prompt", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Shelves"})

      {:ok, view, _html} = live(conn, edit_category_url(category.uuid))

      render_click(view, "ai_translate_lang", %{"lang" => "*"})

      assert {:ok, catalogue_prompt_uuid} = AIPrompt.ensure_prompt()
      shared_default = PhoenixKitAI.Translations.default_prompt_uuid()

      assert [%{args: %{"resource_uuid" => uuid, "prompt_uuid" => prompt_uuid}} | _] =
               translate_worker_jobs()

      assert uuid == category.uuid
      assert prompt_uuid == catalogue_prompt_uuid
      refute prompt_uuid == shared_default
    end
  end

  describe "after the catalogue key is revoked mid-session" do
    # What core's live scope refresh does when a role loses a grant while
    # the page is open.
    defp revoke(view) do
      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        scope = permission_scope([])
        %{state | socket: Phoenix.Component.assign(socket, :phoenix_kit_current_scope, scope)}
      end)

      view
    end

    defp refused?(conn, path) do
      {:ok, view, _html} = live(conn, path)
      html = view |> revoke() |> render_click("ai_translate_lang", %{"lang" => "*"})
      html =~ "permission" and translate_worker_jobs() == []
    end

    test "the item form refuses a crafted ai_translate_lang", %{conn: conn} do
      item = fixture_item(%{catalogue_uuid: fixture_catalogue().uuid, name: "Vase"})
      assert refused?(conn, edit_item_url(item.uuid))
    end

    test "the category form refuses a crafted ai_translate_lang", %{conn: conn} do
      category = fixture_category(fixture_catalogue(), %{name: "Shelves"})
      assert refused?(conn, edit_category_url(category.uuid))
    end

    test "the catalogue form refuses a crafted ai_translate_lang", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Kitchens"})
      assert refused?(conn, "#{@base}/#{catalogue.uuid}/edit")
    end

    test "the attribute form refuses a crafted ai_translate_lang", %{conn: conn} do
      {:ok, group} = PhoenixKitCatalogue.Catalogue.create_attribute_group(%{name: "Doors"})
      assert refused?(conn, "#{@base}/attributes/#{group.uuid}/edit")
    end
  end
end
