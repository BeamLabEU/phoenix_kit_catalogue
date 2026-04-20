defmodule PhoenixKitCatalogue.Catalogue.Search do
  @moduledoc """
  Item search — global, per-catalogue, and per-category, with optional
  scope composition (`catalogue_uuids` AND `category_uuids`).

  Matches case-insensitively against `name`, `description`, `sku`, and
  the multilang `data` JSONB. Excludes items in deleted catalogues or
  deleted categories. Uncategorized items are included unless a
  `:category_uuids` filter narrows the search.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.Helpers
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Searches items with flexible scope.

  ## Options

    * `:catalogue_uuids` — list of catalogue UUIDs to scope to. `nil` or `[]` = all.
    * `:category_uuids` — list of category UUIDs to scope to. `nil` or `[]` = all + uncategorized.
    * `:limit` — max results (default 50).
    * `:offset` — paging offset (default 0).
  """
  @spec search_items(String.t(), keyword()) :: [Item.t()]
  def search_items(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    query
    |> search_items_base(opts)
    |> order_by([i, _cat, _c], asc: i.name, asc: i.uuid)
    |> limit(^limit)
    |> offset(^offset)
    |> preload([:catalogue, category: :catalogue, manufacturer: []])
    |> repo().all()
  end

  @doc """
  Returns the total number of items matching `search_items/2`'s filters.
  Ignores `:limit`/`:offset`. Same scope opts as `search_items/2`.
  """
  @spec count_search_items(String.t(), keyword()) :: non_neg_integer()
  def count_search_items(query, opts \\ []) do
    query
    |> search_items_base(opts)
    |> select([i], count(i.uuid))
    |> repo().one()
  end

  @doc """
  Searches items within a specific catalogue. Convenience wrapper
  around `search_items/2` with `catalogue_uuids: [catalogue_uuid]`,
  but orders by category position first (then item name) for a stable
  walk through a catalogue's categories.
  """
  @spec search_items_in_catalogue(Ecto.UUID.t(), String.t(), keyword()) :: [Item.t()]
  def search_items_in_catalogue(catalogue_uuid, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    opts = Keyword.put(opts, :catalogue_uuids, [catalogue_uuid])

    query
    |> search_items_base(opts)
    |> order_by([i, _cat, c], asc_nulls_last: c.position, asc: i.name, asc: i.uuid)
    |> limit(^limit)
    |> offset(^offset)
    |> preload([:catalogue, category: :catalogue, manufacturer: []])
    |> repo().all()
  end

  @doc "Total match count for `search_items_in_catalogue/3`."
  @spec count_search_items_in_catalogue(Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def count_search_items_in_catalogue(catalogue_uuid, query) do
    count_search_items(query, catalogue_uuids: [catalogue_uuid])
  end

  @doc """
  Searches items within a specific category. Convenience wrapper around
  `search_items/2` with `category_uuids: [category_uuid]`.
  """
  @spec search_items_in_category(Ecto.UUID.t(), String.t(), keyword()) :: [Item.t()]
  def search_items_in_category(category_uuid, query, opts \\ []) do
    opts = Keyword.put(opts, :category_uuids, [category_uuid])
    search_items(query, opts)
  end

  @doc "Total match count for `search_items_in_category/3`."
  @spec count_search_items_in_category(Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def count_search_items_in_category(category_uuid, query) do
    count_search_items(query, category_uuids: [category_uuid])
  end

  # Builds the shared base query (joins + status + text-match + scope filters).
  defp search_items_base(query_str, opts) do
    pattern = "%#{Helpers.sanitize_like(query_str)}%"
    catalogue_uuids = opts[:catalogue_uuids]
    category_uuids = opts[:category_uuids]

    from(i in Item,
      join: cat in Catalogue,
      on: i.catalogue_uuid == cat.uuid,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where: i.status != "deleted" and cat.status != "deleted",
      where: is_nil(c.uuid) or c.status != "deleted",
      where:
        ilike(i.name, ^pattern) or
          ilike(i.description, ^pattern) or
          ilike(i.sku, ^pattern) or
          fragment("?::text ILIKE ?", i.data, ^pattern)
    )
    |> maybe_scope_catalogues(catalogue_uuids)
    |> maybe_scope_categories(category_uuids)
  end

  defp maybe_scope_catalogues(query, uuids) when uuids in [nil, []], do: query

  defp maybe_scope_catalogues(query, uuids) when is_list(uuids) do
    from([i, _cat, _c] in query, where: i.catalogue_uuid in ^uuids)
  end

  defp maybe_scope_categories(query, uuids) when uuids in [nil, []], do: query

  defp maybe_scope_categories(query, uuids) when is_list(uuids) do
    from([i, _cat, _c] in query, where: i.category_uuid in ^uuids)
  end
end
