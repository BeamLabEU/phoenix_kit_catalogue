defmodule PhoenixKitCatalogue.Catalogue.Helpers do
  @moduledoc false
  # Cross-section helpers used by multiple Catalogue submodules.
  # Polymorphic atom/string-keyed map accessors plus a shared
  # `item_catalogue_uuid/1` lookup that both `Catalogue` and `Rules`
  # use for PubSub broadcast scoping (avoids the duplicate query
  # PR #13 review #2 flagged).

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Schemas.Item

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

  @doc """
  Returns the catalogue UUID an item belongs to, or `nil` if the item
  is missing. Single source of truth for the parent-catalogue lookup
  used by PubSub broadcast scoping in `Catalogue.lookup_parent/2` and
  `Rules.put_catalogue_rules/3` (PR #13 #2 dedupe).
  """
  @spec item_catalogue_uuid(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def item_catalogue_uuid(item_uuid) when is_binary(item_uuid) do
    PhoenixKit.RepoHelper.repo().one(
      from(i in Item, where: i.uuid == ^item_uuid, select: i.catalogue_uuid)
    )
  end
end
