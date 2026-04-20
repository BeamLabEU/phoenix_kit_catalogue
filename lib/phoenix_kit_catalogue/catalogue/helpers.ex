defmodule PhoenixKitCatalogue.Catalogue.Helpers do
  @moduledoc false
  # Cross-section helpers used by multiple Catalogue submodules.
  # Right now: polymorphic atom/string-keyed map accessors so the same
  # helpers work on Phoenix form params (string-keyed) and IEx /
  # internal-call attrs (atom-keyed).

  @doc "True when `attrs` has the key as either an atom or its string form."
  @spec has_attr?(map(), atom()) :: boolean()
  def has_attr?(attrs, key) when is_map(attrs) and is_atom(key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key))
  end

  @doc """
  Reads `attrs[key]` falling back to `attrs[to_string(key)]`. Returns `nil`
  when neither is present.
  """
  @spec fetch_attr(map(), atom()) :: term() | nil
  def fetch_attr(attrs, key) when is_map(attrs) and is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, to_string(key))
    end
  end

  @doc """
  Writes a value into `attrs` under whichever key form is already present.
  Falls back to matching the rest of the map's key style on a fresh insert
  so that mixed-key maps (which would later trip `Ecto.Changeset.cast/4`)
  don't get introduced here.
  """
  @spec put_attr(map(), atom(), term()) :: map()
  def put_attr(attrs, key, value) when is_map(attrs) and is_atom(key) do
    cond do
      Map.has_key?(attrs, key) ->
        Map.put(attrs, key, value)

      Map.has_key?(attrs, to_string(key)) ->
        Map.put(attrs, to_string(key), value)

      string_keyed?(attrs) ->
        Map.put(attrs, to_string(key), value)

      true ->
        Map.put(attrs, key, value)
    end
  end

  @doc "True when the first key in `attrs` is a binary string."
  @spec string_keyed?(map()) :: boolean()
  def string_keyed?(attrs) when map_size(attrs) == 0, do: false
  def string_keyed?(attrs) when is_map(attrs), do: attrs |> Map.keys() |> hd() |> is_binary()

  @doc """
  Escapes Postgres `LIKE`/`ILIKE` metacharacters so user-supplied search
  text is matched literally. Handles `\\`, `%`, and `_`.
  """
  @spec sanitize_like(String.t()) :: String.t()
  def sanitize_like(query) when is_binary(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
