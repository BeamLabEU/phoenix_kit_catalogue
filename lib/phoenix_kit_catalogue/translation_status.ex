defmodule PhoenixKitCatalogue.TranslationStatus do
  @moduledoc """
  Freshness of catalogue AI translations: a per-(resource, language)
  fingerprint of the source text, and the state it implies.

  ## Fingerprints

  `fingerprint/1` hashes a `source_fields/2`-shaped map (the same shape the
  `PhoenixKitAI.Translatable` adapters — `PhoenixKitCatalogue.AITranslatable`
  and `PhoenixKitCatalogue.AITranslatable.Sets` — hand the AI engine) into a
  single sha256 hex digest, order-independent across fields.

  The fingerprint must reflect the source text **as read at translation
  time**, not whatever it looks like when the translation is written back —
  a sync can land on the row in between (design source doc §4.1). So
  `capture_fingerprint/3` stashes it in the calling process's dictionary
  when `source_fields/2` runs, keyed by `{resource_type, uuid}`;
  `put_translation/4` in each adapter reads it back via
  `captured_fingerprint/2` and writes it under the target language's key —
  falling back to hashing the freshly-locked row's OWN current source only
  when nothing was captured (a direct call bypassing `source_fields/2`).

  Storage (catalogue-owned keys, additive JSONB — see the block-6 plan's
  amendment vs the original design source):

    * `%Item{}` / `%Category{}` → `data["_translation_fingerprints"][lang]`
    * `%PhoenixKitEntities{}` (a catalogue set's blueprint) →
      `settings["translation_fingerprints"][lang]`
    * `%PhoenixKitEntities.EntityData{}` (a set's value) →
      `metadata["translation_fingerprints"][lang]`

  ## States

  `state/2` folds a (resource, language) pair into one of four states:

    * `:missing` — the source is non-empty but there is no translation
    * `:unknown` — a translation exists but has no recorded fingerprint
      (pre-existing translations from before this model shipped, or one
      written outside `put_translation/4`)
    * `:stale`   — the translation's fingerprint no longer matches the
      current source
    * `:fresh`   — the translation's fingerprint matches the current source

  `unknown` is deliberately never auto-swept (see the sweep worker,
  Task 4) — an operator decides its fate via `stamp_fresh/2` ("the current
  source is the reference") or an explicit retranslate.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.AITranslatable.Sets
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  @type state :: :missing | :stale | :unknown | :fresh

  # The multilang-override field keys the item/category adapter exposes
  # (`PhoenixKitCatalogue.AITranslatable`'s engine-facing names) — a
  # resource counts as "translated" for a language when at least one of
  # these has a non-blank override.
  @override_fields ~w(name description summary seo_title seo_description)

  defp repo, do: RepoHelper.repo()
  defp source_lang, do: Multilang.primary_language()

  # ── Fingerprinting ────────────────────────────────────────────────

  @doc """
  sha256 hex digest of `source_fields`, order-independent: fields are
  sorted by key, each rendered as `"field=trimmed value"`, joined by `"\\n"`.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(source_fields) when is_map(source_fields) do
    source_fields
    |> Enum.sort_by(fn {field, _value} -> field end)
    |> Enum.map_join("\n", fn {field, value} -> "#{field}=#{String.trim(to_string(value))}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Records the fingerprint of `source_fields` for `{resource_type, uuid}` in
  the CALLING PROCESS's dictionary. Meant to be called from inside a
  `source_fields/2` implementation, right before the value is handed to
  the AI engine — see the moduledoc.
  """
  @spec capture_fingerprint(String.t(), Ecto.UUID.t(), map()) :: :ok
  def capture_fingerprint(resource_type, uuid, source_fields) do
    Process.put({:pk_catalogue_fp, resource_type, uuid}, fingerprint(source_fields))
    :ok
  end

  @doc "Reads back a fingerprint captured earlier in THIS process, or `nil`."
  @spec captured_fingerprint(String.t(), Ecto.UUID.t()) :: String.t() | nil
  def captured_fingerprint(resource_type, uuid) do
    Process.get({:pk_catalogue_fp, resource_type, uuid})
  end

  # ── States ────────────────────────────────────────────────────────

  @doc "The freshness state of `resource`'s translation into `lang`."
  @spec state(struct(), String.t()) :: state()
  def state(resource, lang) do
    cond do
      not translated?(resource, lang) -> :missing
      is_nil(stored_fingerprint(resource, lang)) -> :unknown
      stored_fingerprint(resource, lang) == current_fingerprint(resource) -> :fresh
      true -> :stale
    end
  end

  @doc """
  Operator action: "the current source is canonical" — writes the CURRENT
  source's fingerprint under `lang` without calling the AI, flipping the
  pair to `:fresh` (or leaving `:missing` alone — see the guard below: a
  resource with no translation for `lang` has nothing to stamp).
  """
  @spec stamp_fresh(struct(), String.t()) :: {:ok, struct()} | {:error, term()}
  def stamp_fresh(resource, lang) do
    if translated?(resource, lang) do
      locked_stamp(resource, lang)
    else
      {:error, :no_translation}
    end
  end

  defp locked_stamp(%schema{uuid: uuid}, lang) do
    repo().transaction(fn ->
      query = where(schema, [r], r.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        fresh -> apply_stamp(fresh, lang)
      end
    end)
  end

  defp apply_stamp(fresh, lang) do
    {field, fp_key} = fingerprint_location(fresh)
    fp = fresh |> current_source_fields() |> fingerprint()
    current = Map.get(fresh, field) || %{}
    fingerprints = current |> Map.get(fp_key, %{}) |> Map.put(lang, fp)
    new_value = Map.put(current, fp_key, fingerprints)

    case fresh |> Ecto.Changeset.change(%{field => new_value}) |> repo().update() do
      {:ok, updated} -> updated
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp fingerprint_location(%Item{}), do: {:data, "_translation_fingerprints"}
  defp fingerprint_location(%Category{}), do: {:data, "_translation_fingerprints"}
  defp fingerprint_location(%Entities{}), do: {:settings, "translation_fingerprints"}
  defp fingerprint_location(%EntityData{}), do: {:metadata, "translation_fingerprints"}

  defp translated?(%Item{data: data}, lang), do: any_override_present?(data, lang)
  defp translated?(%Category{data: data}, lang), do: any_override_present?(data, lang)

  defp translated?(%Entities{} = set, lang) do
    set |> Entities.get_entity_translations() |> Map.get(lang) |> is_map()
  end

  defp translated?(%EntityData{} = value, lang) do
    case Multilang.get_raw_language_data(value.data, lang) do
      %{"_title" => title} when is_binary(title) -> String.trim(title) != ""
      _ -> false
    end
  end

  defp any_override_present?(data, lang) do
    raw = Multilang.get_raw_language_data(data, lang)

    Enum.any?(@override_fields, fn field ->
      case Map.get(raw, "_" <> field) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end)
  end

  defp stored_fingerprint(resource, lang) do
    {field, fp_key} = fingerprint_location(resource)
    get_in(Map.get(resource, field) || %{}, [fp_key, lang])
  end

  defp current_fingerprint(resource), do: resource |> current_source_fields() |> fingerprint()

  defp current_source_fields(%Item{} = r), do: AITranslatable.source_fields(r, source_lang())
  defp current_source_fields(%Category{} = r), do: AITranslatable.source_fields(r, source_lang())
  defp current_source_fields(%Entities{} = r), do: Sets.source_fields(r, source_lang())
  defp current_source_fields(%EntityData{} = r), do: Sets.source_fields(r, source_lang())

  # ── Listing ───────────────────────────────────────────────────────

  @doc """
  Lists (resource, language) rows for `type`, one per language in
  `opts[:langs]`.

  ## Options

    * `:langs` — target languages to report on (default `[]` — an empty
      list yields no rows; callers pick the languages that matter to them,
      e.g. the enabled non-default set or a single language filter)
    * `:state` — one state atom or a list of them; unfiltered when absent
    * `:catalogue_uuid` — scope `:item`/`:category` rows to one catalogue
      (ignored for `:set_label`/`:set_value`, which are catalogue-wide)
    * `:page` / `:per_page` — 1-indexed pagination (defaults `1` / `50`)
  """
  @spec list(:item | :category | :set_label | :set_value, keyword()) :: [map()]
  def list(type, opts \\ []) do
    langs = Keyword.get(opts, :langs, [])
    states = opts |> Keyword.get(:state) |> List.wrap()
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    type
    |> resources_for(Keyword.get(opts, :catalogue_uuid))
    |> Enum.flat_map(&rows_for(type, &1, langs))
    |> Enum.sort_by(&{&1.name, &1.lang})
    |> filter_states(states)
    |> Enum.drop((page - 1) * per_page)
    |> Enum.take(per_page)
  end

  defp resources_for(:item, nil), do: Catalogue.list_items()

  defp resources_for(:item, catalogue_uuid),
    do: Catalogue.list_items_for_catalogue(catalogue_uuid)

  defp resources_for(:category, nil),
    do: repo().all(from(c in Category, where: c.status != "deleted"))

  defp resources_for(:category, catalogue_uuid),
    do: Catalogue.list_categories_for_catalogue(catalogue_uuid)

  defp resources_for(:set_label, _catalogue_uuid), do: AttributeSets.list_sets()

  defp resources_for(:set_value, _catalogue_uuid) do
    AttributeSets.list_sets() |> Enum.flat_map(&AttributeSets.list_values/1)
  end

  defp rows_for(type, resource, langs) do
    Enum.map(langs, fn lang ->
      %{
        type: type,
        uuid: resource.uuid,
        name: resource_name(resource),
        lang: lang,
        state: state(resource, lang),
        updated_at: resource_updated_at(resource)
      }
    end)
  end

  defp resource_name(%Item{name: name}), do: name
  defp resource_name(%Category{name: name}), do: name
  defp resource_name(%Entities{display_name: name}), do: name
  defp resource_name(%EntityData{title: title}), do: title

  defp resource_updated_at(%Item{updated_at: t}), do: t
  defp resource_updated_at(%Category{updated_at: t}), do: t
  defp resource_updated_at(%Entities{date_updated: t}), do: t
  defp resource_updated_at(%EntityData{date_updated: t}), do: t

  defp filter_states(rows, []), do: rows
  defp filter_states(rows, states), do: Enum.filter(rows, &(&1.state in states))
end
