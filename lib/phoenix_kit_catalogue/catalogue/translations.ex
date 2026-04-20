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
end
