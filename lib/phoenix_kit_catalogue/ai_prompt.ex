defmodule PhoenixKitCatalogue.AIPrompt do
  @moduledoc """
  Idempotent provisioning of the catalogue's AI-translation prompt.

  `PhoenixKitAI.Translations.default_prompt_uuid/0` (the shared
  `phoenixkit-translate-content` prompt) hard-codes six field slots
  (`name`/`title`/`summary`/`description`/`body`/`content`) and only two of
  those match `AITranslatable`'s vocabulary — every catalogue call would
  render the other four as literal, unbound `{{placeholder}}` text (the
  engine substitutes variables globally, with no notion of "this field
  wasn't sent"). This module gives catalogue its own prompt instead, whose
  vocabulary is exactly `AITranslatable`'s five fields, plus the
  measurement-unit rule the shared prompt has no reason to carry.

  ## Rollout

  The prompt is content-addressed: `ensure_prompt/0` is idempotent by
  slug, and `Prompt.metadata["content_sha"]` (sha256 hex of `@content`)
  tells it whether the stored row still matches this module's template.
  Editing `@content` and redeploying makes every next `ensure_prompt/0`
  call update the stored prompt to match — no version counter, because
  the content already is the version.
  """

  alias PhoenixKitAI.Prompt

  # `PhoenixKitAI.create_prompt/1` derives a prompt's slug from its name
  # via `PhoenixKit.Utils.Slug.slugify/1`, overriding any `:slug` passed at
  # creation time — so this name MUST slugify to `@slug`, or the
  # idempotency lookup below never matches and every call re-attempts the
  # create (same constraint `PhoenixKitAI.Translations` documents for its
  # own shared prompt's `@prompt_name`/`@prompt_slug` pair).
  @name "PhoenixKit Catalogue Translation"
  @slug "phoenixkit-catalogue-translation"
  @managed_by "phoenix_kit_catalogue"

  @content """
  Translate the following catalogue fields from {{SourceLanguage}} to {{TargetLanguage}}.

  RULES:
  - Preserve formatting exactly (line breaks, spacing).
  - Measurements keep their numbers and unit abbreviations unchanged (e.g.
    "30 cm" stays "30 cm"); translate the unit WORDS themselves instead
    (e.g. "inches" becomes the target language's word for inches), never
    their abbreviations.
  - Keep any "|" separators in the source text exactly as they appear, in
    the same positions.
  - The translated seo_title must stay at or under 70 characters.
  - A field below whose value still looks like an unfilled template slot —
    its own field name wrapped in a pair of double curly braces, with no
    real text — was never bound by the caller: skip it silently, do not
    emit a marker for it, and do not translate that literal text.
  - Output ONLY the structured markers below — no commentary, no preface,
    no closing remarks.

  OUTPUT FORMAT — for each field below that has a real (non-placeholder,
  non-blank) value, emit ONE marker named after the field (uppercase),
  followed by the translation:

      ---<FIELD_NAME_UPPERCASE>---
      [translated value]

  === SOURCE ===

  Name: {{name}}

  Description: {{description}}

  Summary: {{summary}}

  Seo_title: {{seo_title}}

  Seo_description: {{seo_description}}
  """

  @doc "The prompt's slug — stable across redeploys, used for the idempotent lookup."
  @spec slug() :: String.t()
  def slug, do: @slug

  @doc """
  Ensures the catalogue translation prompt exists in the database and
  matches this module's current `@content`, creating or updating it as
  needed.

  Idempotent by slug: repeated calls return the same uuid as long as
  `@content` hasn't changed. When it has (a redeploy shipped an edited
  template), the next call updates the stored prompt in place and keeps
  the same uuid — callers holding an old `prompt_uuid` still resolve to
  the current rules.
  """
  @spec ensure_prompt() :: {:ok, String.t()} | {:error, term()}
  def ensure_prompt do
    case PhoenixKitAI.get_prompt_by_slug(@slug) do
      nil -> create_prompt()
      %Prompt{} = prompt -> maybe_update(prompt)
    end
  end

  defp create_prompt do
    attrs = %{
      name: @name,
      slug: @slug,
      description:
        "Catalogue item/category translation: name, description, summary, SEO title/description.",
      content: @content,
      metadata: %{"managed_by" => @managed_by, "content_sha" => content_sha()}
    }

    case PhoenixKitAI.create_prompt(attrs) do
      {:ok, %Prompt{} = prompt} ->
        {:ok, prompt.uuid}

      # Lost a create race — another node inserted the same slug first.
      # Re-read it and fall through the same up-to-date check below; per
      # the module doc, both writers agree on `@content`, so this is
      # idempotent either way.
      {:error, %Ecto.Changeset{}} ->
        case PhoenixKitAI.get_prompt_by_slug(@slug) do
          nil -> {:error, :prompt_unavailable}
          %Prompt{} = prompt -> maybe_update(prompt)
        end
    end
  end

  defp maybe_update(%Prompt{metadata: metadata} = prompt) do
    sha = content_sha()

    if Map.get(metadata || %{}, "content_sha") == sha do
      {:ok, prompt.uuid}
    else
      attrs = %{
        content: @content,
        metadata: Map.merge(metadata || %{}, %{"managed_by" => @managed_by, "content_sha" => sha})
      }

      case PhoenixKitAI.update_prompt(prompt, attrs) do
        {:ok, %Prompt{} = updated} -> {:ok, updated.uuid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp content_sha do
    :crypto.hash(:sha256, @content) |> Base.encode16(case: :lower)
  end
end
