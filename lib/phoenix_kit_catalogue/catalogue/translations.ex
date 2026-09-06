defmodule PhoenixKitCatalogue.Catalogue.Translations do
  @moduledoc """
  Multilang `data` JSONB helpers — read merged language data from a
  record and write language-specific overrides through the entity's own
  update function.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  alias PhoenixKit.Utils.Multilang

  @doc """
  Gets translated field data for a record in a specific language.
  Returns merged data (primary language as base + overrides for the
  requested language).
  """
  @spec get_translation(map(), String.t()) :: map()
  def get_translation(record, lang_code) do
    Multilang.get_language_data(record.data || %{}, lang_code)
  end

  @doc """
  Updates the multilang `data` field for a record with language-specific
  field data. For primary language: stores ALL fields. For secondary
  languages: stores only overrides (differences from primary).

  `update_fn` is the entity's update function. It receives `(record, attrs)`
  for 2-arity or `(record, attrs, opts)` for 3-arity when activity-logging
  opts are provided.
  """
  @spec set_translation(map(), String.t(), map(), function(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def set_translation(record, lang_code, field_data, update_fn, opts \\ []) do
    new_data = Multilang.put_language_data(record.data || %{}, lang_code, field_data)

    if opts == [] do
      update_fn.(record, %{data: new_data})
    else
      update_fn.(record, %{data: new_data}, opts)
    end
  end

  @doc """
  The display name for `locale`: the locale's translation override
  (either the `"_name"` shape the shared multilang helper writes or the
  legacy bare `"name"`), falling back to the primary-language column.
  Safe on records without translations and on plain maps.
  """
  @spec translated_name(map() | nil, String.t() | nil) :: String.t() | nil
  def translated_name(nil, _locale), do: nil
  def translated_name(record, nil), do: Map.get(record, :name)

  def translated_name(record, locale) do
    translation = safe_translation(record, locale)

    presence(Map.get(translation, "_name")) ||
      presence(Map.get(translation, "name")) ||
      Map.get(record, :name)
  end

  @doc "Same contract as `translated_name/2`, for `:description`."
  @spec translated_description(map() | nil, String.t() | nil) :: String.t() | nil
  def translated_description(nil, _locale), do: nil
  def translated_description(record, nil), do: Map.get(record, :description)

  def translated_description(record, locale) do
    translation = safe_translation(record, locale)

    presence(Map.get(translation, "_description")) ||
      presence(Map.get(translation, "description")) ||
      Map.get(record, :description)
  end

  @doc """
  The SEO title override for `locale`, or `nil` when unset.

  Unlike `translated_name/2`, there is no DB-column fallback — `seo_title`
  only ever lives under the multilang `data` override (`"_seo_title"`),
  same storage shape as `_name`/`_description` but with no primary-column
  counterpart.
  """
  @spec translated_seo_title(map() | nil, String.t() | nil) :: String.t() | nil
  def translated_seo_title(nil, _locale), do: nil
  def translated_seo_title(_record, nil), do: nil

  def translated_seo_title(record, locale) do
    record |> safe_translation(locale) |> Map.get("_seo_title") |> presence()
  end

  @doc "Same contract as `translated_seo_title/2`, for `_seo_description`."
  @spec translated_seo_description(map() | nil, String.t() | nil) :: String.t() | nil
  def translated_seo_description(nil, _locale), do: nil
  def translated_seo_description(_record, nil), do: nil

  def translated_seo_description(record, locale) do
    record |> safe_translation(locale) |> Map.get("_seo_description") |> presence()
  end

  @doc """
  Replaces `:name` (and `:description` where present) on each record
  with the `locale`-resolved display text, so list/detail surfaces can
  render `record.name` untouched and still honor the viewer's locale.

  Resolve-early by design (the same shape as `resolved_group/2`): the
  alternative — threading a `locale` attr through every table/tile/cell
  component — spreads the concern across dozens of render sites.
  Records without a `:data` map (folders) pass through unchanged, as
  does everything when `locale` is nil. Struct identity is preserved
  (`%{record | ...}`), and mutations are unaffected: status/move/
  reorder writes never take `:name` from these list structs.
  """
  @spec localize(list(), String.t() | nil) :: list()
  def localize(records, locale) when is_list(records) do
    Enum.map(records, &localize_one(&1, locale))
  end

  @doc "Single-record `localize/2`."
  @spec localize_one(map() | nil, String.t() | nil) :: map() | nil
  def localize_one(nil, _locale), do: nil
  def localize_one(record, nil), do: record

  def localize_one(record, locale) do
    if is_map(record) and is_map(Map.get(record, :data)) do
      record
      |> maybe_put_localized(:name, translated_name(record, locale))
      |> maybe_put_localized(:description, translated_description(record, locale))
    else
      record
    end
  end

  defp maybe_put_localized(record, key, value) do
    if Map.has_key?(record, key) and is_binary(value) and value != "" do
      Map.put(record, key, value)
    else
      record
    end
  end

  defp safe_translation(record, locale) do
    get_translation(record, locale)
  rescue
    _ -> %{}
  end

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_), do: nil
end
