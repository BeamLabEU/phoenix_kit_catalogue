defmodule PhoenixKitCatalogue.AIPrompt do
  @moduledoc """
  Idempotent provisioning of the catalogue's AI-translation prompts.

  `PhoenixKitAI.Translations.default_prompt_uuid/0` (the shared
  `phoenixkit-translate-content` prompt) hard-codes six field slots
  (`name`/`title`/`summary`/`description`/`body`/`content`) and none of
  those match `catalogue_set_label`'s/`catalogue_set_value`'s vocabulary
  (`label`/`title`) either — every catalogue call would render the
  unmatched slots as literal, unbound `{{placeholder}}` text (the engine
  substitutes variables globally, with no notion of "this field wasn't
  sent"), and a call binding only `label` or only `title` would fail
  `{:missing_fields, [...]}` outright since the shared template has no
  such slot at all. This module gives catalogue its own two prompts
  instead:

    * `ensure_prompt/0` — items/categories, vocabulary `name`/
      `description`/`summary`/`seo_title`/`seo_description`.
    * `ensure_sets_prompt/0` — attribute-set labels/value titles,
      vocabulary `label`/`title`.

  Both carry the same measurement-unit rule the shared prompt has no
  reason to carry — attribute values (e.g. sizes) are exactly where units
  show up.

  ## Rollout

  Each prompt is content-addressed: `ensure_prompt/0`/`ensure_sets_prompt/0`
  are idempotent by their own slug, and `Prompt.metadata["content_sha"]`
  (sha256 hex of the module's template) tells them whether the stored row
  still matches. Editing a template and redeploying makes the next call
  update the stored prompt in place and keep the same uuid — no version
  counter, because the content already is the version.
  """

  alias PhoenixKitAI.Prompt

  # `PhoenixKitAI.create_prompt/1` derives a prompt's slug from its name
  # via `PhoenixKit.Utils.Slug.slugify/1`, overriding any `:slug` passed at
  # creation time — so each name below MUST slugify to its matching slug,
  # or the idempotency lookup never matches and every call re-attempts the
  # create (same constraint `PhoenixKitAI.Translations` documents for its
  # own shared prompt's `@prompt_name`/`@prompt_slug` pair).
  @name "PhoenixKit Catalogue Translation"
  @slug "phoenixkit-catalogue-translation"
  @sets_name "PhoenixKit Catalogue Set Translation"
  @sets_slug "phoenixkit-catalogue-set-translation"
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

  # Attribute-set labels and value titles are short standalone strings
  # (e.g. a set's display name, or a size/color value's title) — the same
  # unit rule as `@content` applies (a value title is exactly where
  # "30 cm" / "12 inches" shows up), but there is no description/SEO
  # vocabulary here, and no separate "|"-joined multi-part text either.
  @sets_content """
  Translate the following catalogue attribute-set fields from {{SourceLanguage}} to {{TargetLanguage}}.

  RULES:
  - Preserve formatting exactly (line breaks, spacing).
  - Measurements keep their numbers and unit abbreviations unchanged (e.g.
    "30 cm" stays "30 cm"); translate the unit WORDS themselves instead
    (e.g. "inches" becomes the target language's word for inches), never
    their abbreviations.
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

  Label: {{label}}

  Title: {{title}}
  """

  @doc "The item/category translation prompt's slug — stable across redeploys."
  @spec slug() :: String.t()
  def slug, do: @slug

  @doc "The attribute-set translation prompt's slug — stable across redeploys."
  @spec sets_slug() :: String.t()
  def sets_slug, do: @sets_slug

  @doc """
  Ensures the catalogue item/category translation prompt exists and
  matches this module's current template, creating or updating it as
  needed.

  Idempotent by slug: repeated calls return the same uuid as long as the
  template hasn't changed. When it has (a redeploy shipped an edited
  template), the next call updates the stored prompt in place and keeps
  the same uuid — callers holding an old `prompt_uuid` still resolve to
  the current rules.
  """
  @spec ensure_prompt() :: {:ok, String.t()} | {:error, term()}
  def ensure_prompt do
    ensure(
      @slug,
      @name,
      @content,
      "Catalogue item/category translation: name, description, summary, SEO title/description."
    )
  end

  @doc """
  Ensures the catalogue attribute-set translation prompt (labels and
  value titles, `{{label}}`/`{{title}}`) exists and matches this module's
  current template — same idempotent-by-slug, content-addressed rollout
  as `ensure_prompt/0`, under its own slug so it never collides with the
  item/category prompt or the shared `phoenixkit-translate-content` one.
  """
  @spec ensure_sets_prompt() :: {:ok, String.t()} | {:error, term()}
  def ensure_sets_prompt do
    ensure(
      @sets_slug,
      @sets_name,
      @sets_content,
      "Catalogue attribute-set translation: set label, value title."
    )
  end

  defp ensure(slug, name, content, description) do
    case PhoenixKitAI.get_prompt_by_slug(slug) do
      nil -> create_prompt(slug, name, content, description)
      %Prompt{} = prompt -> maybe_update(prompt, content)
    end
  end

  defp create_prompt(slug, name, content, description) do
    attrs = %{
      name: name,
      slug: slug,
      description: description,
      content: content,
      metadata: %{"managed_by" => @managed_by, "content_sha" => content_sha(content)}
    }

    case PhoenixKitAI.create_prompt(attrs) do
      {:ok, %Prompt{} = prompt} ->
        {:ok, prompt.uuid}

      # Lost a create race — another node inserted the same slug first.
      # Re-read it and fall through the same up-to-date check below; per
      # the module doc, both writers agree on the template, so this is
      # idempotent either way.
      {:error, %Ecto.Changeset{}} ->
        case PhoenixKitAI.get_prompt_by_slug(slug) do
          nil -> {:error, :prompt_unavailable}
          %Prompt{} = prompt -> maybe_update(prompt, content)
        end
    end
  end

  defp maybe_update(%Prompt{metadata: metadata} = prompt, content) do
    sha = content_sha(content)

    if Map.get(metadata || %{}, "content_sha") == sha do
      {:ok, prompt.uuid}
    else
      attrs = %{
        content: content,
        metadata: Map.merge(metadata || %{}, %{"managed_by" => @managed_by, "content_sha" => sha})
      }

      case PhoenixKitAI.update_prompt(prompt, attrs) do
        {:ok, %Prompt{} = updated} -> {:ok, updated.uuid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp content_sha(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
