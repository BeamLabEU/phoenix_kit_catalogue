defmodule PhoenixKitCatalogue.Catalogue.Tree do
  @moduledoc false
  # Recursive tree helpers for the category adjacency list (V103).
  # Used by the cascade operations (trash/restore/permanent-delete),
  # cross-catalogue move, cycle checks, and search expansion.
  #
  # All public functions run one recursive CTE. For UIs that already
  # have every category in the catalogue loaded (e.g. the detail view),
  # prefer `build_index/1` + `walk_subtree/2` — same shape, no DB trip.
  #
  # ## Cycle safety
  #
  # The context API guards against cycles (`move_category_under/3`
  # rejects a descendant parent, `Category.changeset` rejects a
  # self-parent), so a well-formed DB never contains a cycle. As
  # defense in depth against corrupted data or direct SQL writes, the
  # CTEs use `UNION` (not `UNION ALL`) — Postgres drops rows already in
  # the working table before the next iteration, which breaks any
  # cycle by emptying the working set. No infinite loop.

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Schemas.Category

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Returns `[uuid]` for every descendant of `root_uuid`, not including
  `root_uuid` itself. Empty list for a leaf.
  """
  @spec descendant_uuids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def descendant_uuids(root_uuid) when is_binary(root_uuid) do
    subtree_uuids_for([root_uuid]) -- [root_uuid]
  end

  @doc """
  Returns `[uuid]` for `root_uuid` and every descendant. Order
  unspecified. Used for subtree updates (trash, move_to_catalogue,
  permanent delete).
  """
  @spec subtree_uuids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def subtree_uuids(root_uuid) when is_binary(root_uuid) do
    subtree_uuids_for([root_uuid])
  end

  @doc """
  Returns every UUID in the union of subtrees seeded by `roots`.
  Duplicates (when one seed is an ancestor of another) are collapsed.
  Used to expand a search scope from selected categories down into
  their descendants.
  """
  @spec subtree_uuids_for([Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def subtree_uuids_for([]), do: []

  def subtree_uuids_for(roots) when is_list(roots) do
    initial =
      from(c in Category,
        where: c.uuid in ^roots,
        select: %{uuid: c.uuid}
      )

    recursion =
      from(c in Category,
        join: t in "category_tree",
        on: c.parent_uuid == t.uuid,
        select: %{uuid: c.uuid}
      )

    cte = initial |> union(^recursion)

    from(t in "category_tree", select: t.uuid)
    |> recursive_ctes(true)
    |> with_cte("category_tree", as: ^cte)
    |> repo().all()
  end

  @doc """
  Returns `[uuid]` for every ancestor of `uuid`, walking up to the root.
  Excludes `uuid` itself. Order unspecified.
  """
  @spec ancestor_uuids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def ancestor_uuids(uuid) when is_binary(uuid) do
    initial =
      from(c in Category,
        where: c.uuid == ^uuid,
        select: %{uuid: c.uuid, parent_uuid: c.parent_uuid}
      )

    recursion =
      from(c in Category,
        join: t in "category_tree",
        on: c.uuid == t.parent_uuid,
        select: %{uuid: c.uuid, parent_uuid: c.parent_uuid}
      )

    cte = initial |> union(^recursion)

    from(t in "category_tree",
      where: t.uuid != ^uuid,
      select: t.uuid
    )
    |> recursive_ctes(true)
    |> with_cte("category_tree", as: ^cte)
    |> repo().all()
  end

  @doc """
  Returns the list of ancestor categories ordered from root → direct
  parent. Excludes the category itself. Used for breadcrumbs.
  """
  @spec ancestors_in_order(Ecto.UUID.t()) :: [Category.t()]
  def ancestors_in_order(uuid) when is_binary(uuid) do
    case ancestor_uuids(uuid) do
      [] ->
        []

      uuids ->
        by_uuid =
          from(c in Category, where: c.uuid in ^uuids)
          |> repo().all()
          |> Map.new(&{&1.uuid, &1})

        # Walk from the category's direct parent up; then reverse so
        # the caller gets root-first order. Using the loaded map means
        # no extra round trips per hop.
        uuid
        |> walk_up(by_uuid, [])
        |> Enum.reverse()
    end
  end

  defp walk_up(uuid, by_uuid, acc) do
    case Map.get(by_uuid, uuid) do
      %Category{parent_uuid: nil} = cat -> [cat | acc]
      %Category{parent_uuid: parent_uuid} = cat -> walk_up(parent_uuid, by_uuid, [cat | acc])
      nil -> acc
    end
  end

  @doc """
  Builds a `%{parent_uuid => [child_category, ...]}` index from a flat
  list of categories. Children are kept in the list's incoming order
  (callers are expected to pass them pre-sorted by position/name).
  Root categories land under the `nil` key.
  """
  @spec build_children_index([Category.t()]) :: %{
          (Ecto.UUID.t() | nil) => [Category.t()]
        }
  def build_children_index(categories) when is_list(categories) do
    categories
    |> Enum.group_by(& &1.parent_uuid)
    |> Map.new(fn {k, children} -> {k, children} end)
  end

  @doc """
  Walks a preloaded tree depth-first starting at `root_uuid` (or at
  every root if `nil` is passed), invoking `fun.(category, depth)` for
  each node. Depth starts at `0` for the seed.
  """
  @spec walk_subtree(
          %{(Ecto.UUID.t() | nil) => [Category.t()]},
          Ecto.UUID.t() | nil,
          (Category.t(), non_neg_integer() -> any())
        ) :: :ok
  def walk_subtree(index, root_uuid, fun) when is_function(fun, 2) do
    index
    |> Map.get(root_uuid, [])
    |> Enum.each(&do_walk(&1, index, 0, fun))

    :ok
  end

  defp do_walk(%Category{} = cat, index, depth, fun) do
    fun.(cat, depth)

    index
    |> Map.get(cat.uuid, [])
    |> Enum.each(&do_walk(&1, index, depth + 1, fun))
  end
end
