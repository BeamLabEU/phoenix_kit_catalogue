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

  alias PhoenixKitCatalogue.Catalogue.{Helpers, Tree}
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Searches items with flexible scope.

  ## Options

    * `:catalogue_uuids` — list of catalogue UUIDs to scope to. `nil` or `[]` = all.
    * `:category_uuids` — list of category UUIDs to scope to. `nil` or `[]` = all + uncategorized.
      Must contain only non-nil UUIDs; passing `[nil]` raises `ArgumentError`
      (use `:only => :uncategorized_only` for that intent).
    * `:include_descendants` — when `true` (default since V103), each
      entry in `:category_uuids` is expanded to include every descendant
      category in the nested-category tree. Pass `false` to scope
      strictly to the given UUIDs.
    * `:only` — `:uncategorized_only` restricts to items with no
      `category_uuid`; `:categorized_only` restricts to items that
      belong to some category. `nil` (default) is unrestricted.
      Combining `:uncategorized_only` with a non-empty `:category_uuids`
      is a logical contradiction and raises `ArgumentError`.
    * `:limit` — max results (default 50).
    * `:offset` — paging offset (default 0).
    * `:preload` — extra associations appended to the default
      `[:catalogue, category: :catalogue, manufacturer: []]`. Pass
      `[catalogue_rules: :referenced_catalogue]` for smart-pricing.
  """
  @spec search_items(String.t(), keyword()) :: [Item.t()]
  def search_items(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    preloads = Helpers.merge_preloads([:catalogue, category: :catalogue, manufacturer: []], opts)

    # Ordering note: `i.position` is intentionally NOT in the global
    # `search_items/2` order_by. `position` is per-`(catalogue_uuid,
    # category_uuid)` scope, so interleaving across catalogues by raw
    # position is meaningless. Single-catalogue search (see
    # `search_items_in_catalogue/3` below) keeps `i.position` because
    # the scope is narrow enough for it to be coherent.
    query
    |> search_items_base(opts)
    |> order_by([i, _cat, _c], asc: i.name, asc: i.uuid)
    |> limit(^limit)
    |> offset(^offset)
    |> preload(^preloads)
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

  Same `:preload` opt as `search_items/2` (extra associations appended
  to the default `[:catalogue, category: :catalogue, manufacturer: []]`).
  """
  @spec search_items_in_catalogue(Ecto.UUID.t(), String.t(), keyword()) :: [Item.t()]
  def search_items_in_catalogue(catalogue_uuid, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    opts = Keyword.put(opts, :catalogue_uuids, [catalogue_uuid])
    preloads = Helpers.merge_preloads([:catalogue, category: :catalogue, manufacturer: []], opts)

    query
    |> search_items_base(opts)
    |> order_by([i, _cat, c],
      asc_nulls_last: c.position,
      asc: i.position,
      asc: i.name,
      asc: i.uuid
    )
    |> limit(^limit)
    |> offset(^offset)
    |> preload(^preloads)
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
    validate_scope_opts!(opts)

    pattern = "%#{Helpers.sanitize_like(query_str)}%"
    catalogue_uuids = opts[:catalogue_uuids]
    category_uuids = expand_category_scope(opts)
    only = Keyword.get(opts, :only)

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
    |> maybe_scope_only(only)
  end

  # Catches two foot-guns up front so callers see a loud error instead
  # of a silently-wrong empty result set:
  #
  #   * `category_uuids: [nil]` — `WHERE category_uuid IN (NULL)` is a
  #     SQL no-op that returns no rows. The `:only => :uncategorized_only`
  #     option is the correct way to ask for "no category".
  #   * `only: :uncategorized_only` AND a non-empty `:category_uuids` —
  #     a logical contradiction (an item can't simultaneously belong to
  #     a category AND have no category). Always returns 0 rows.
  defp validate_scope_opts!(opts) do
    validate_only!(Keyword.get(opts, :only))
    validate_category_uuids!(opts[:category_uuids], Keyword.get(opts, :only))
  end

  defp validate_only!(nil), do: :ok
  defp validate_only!(:uncategorized_only), do: :ok
  defp validate_only!(:categorized_only), do: :ok

  defp validate_only!(other),
    do: raise(ArgumentError, "unknown :only value #{inspect(other)}")

  defp validate_category_uuids!(nil, _only), do: :ok
  defp validate_category_uuids!([], _only), do: :ok

  defp validate_category_uuids!(uuids, only) when is_list(uuids) do
    if Enum.any?(uuids, &is_nil/1) do
      raise ArgumentError,
            "category_uuids must contain non-nil UUIDs; pass `nil` or `[]` " <>
              "for unscoped, or `only: :uncategorized_only` for items without a category"
    end

    if only == :uncategorized_only do
      raise ArgumentError,
            "only: :uncategorized_only cannot be combined with a non-empty " <>
              "category_uuids — the two scopes contradict each other"
    end

    :ok
  end

  # Expands `:category_uuids` through the V103 nested-category tree so
  # filtering by "Kitchen" also matches items in "Kitchen / Frames".
  # `:include_descendants` defaults to `true`; callers can opt out for
  # the literal-set semantics by passing `false`.
  defp expand_category_scope(opts) do
    case opts[:category_uuids] do
      nil ->
        nil

      [] ->
        []

      uuids when is_list(uuids) ->
        if Keyword.get(opts, :include_descendants, true) do
          Tree.subtree_uuids_for(uuids)
        else
          uuids
        end
    end
  end

  defp maybe_scope_catalogues(query, uuids) when uuids in [nil, []], do: query

  defp maybe_scope_catalogues(query, uuids) when is_list(uuids) do
    from([i, _cat, _c] in query, where: i.catalogue_uuid in ^uuids)
  end

  defp maybe_scope_categories(query, uuids) when uuids in [nil, []], do: query

  defp maybe_scope_categories(query, uuids) when is_list(uuids) do
    from([i, _cat, _c] in query, where: i.category_uuid in ^uuids)
  end

  defp maybe_scope_only(query, nil), do: query

  defp maybe_scope_only(query, :uncategorized_only) do
    from([i, _cat, _c] in query, where: is_nil(i.category_uuid))
  end

  defp maybe_scope_only(query, :categorized_only) do
    from([i, _cat, _c] in query, where: not is_nil(i.category_uuid))
  end
end
