defmodule PhoenixKitCatalogue.API.DeleteCategories do
  @moduledoc false
  # Tool `catalogue.delete_categories`: trash, never delete. A category goes the way the
  # admin's delete button takes it by default (`items: :cascade`): its subcategories and
  # the items in its subtree go to the trash with it, stamped as taken by it, so
  # `Catalogue.restore_category/2` brings back exactly that set.

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.Common
  alias PhoenixKitCatalogue.Catalogue

  @tool "catalogue.delete_categories"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"], writable: true) do
      resolutions =
        API.resolve_refs(input["refs"], kind: :category, catalogue_uuid: catalogue.uuid)

      plan = Common.removal_plan(resolutions, catalogue, :category)
      tree = tree(catalogue)

      if ctx.dry_run?, do: preview(plan, tree), else: execute(plan, catalogue, tree, ctx)
    end
  end

  # --- the live tree (reads only) -------------------------------------------------------

  # `parents`: uuid => parent uuid; `children`: uuid => child uuids; `items`: uuid => the live
  # items directly in the category.
  defp tree(catalogue) do
    %{categories: categories, item_counts: items} =
      Catalogue.category_summary_for_catalogue(catalogue.uuid)

    %{
      parents: Map.new(categories, &{&1.uuid, &1.parent_uuid}),
      children: Enum.group_by(categories, & &1.parent_uuid, & &1.uuid),
      items: items
    }
  end

  # The live categories above `uuid`, root first. `acc` stops a corrupt cycle.
  defp ancestors(uuid, tree), do: ancestors(Map.get(tree.parents, uuid), tree, [])

  defp ancestors(nil, _tree, acc), do: acc

  defp ancestors(uuid, tree, acc) do
    if uuid in acc or not Map.has_key?(tree.parents, uuid),
      do: acc,
      else: ancestors(Map.get(tree.parents, uuid), tree, [uuid | acc])
  end

  # `uuid` and everything live below it.
  defp subtree(uuid, tree), do: subtree([uuid], tree, [])

  defp subtree([], _tree, acc), do: acc

  defp subtree([uuid | rest], tree, acc) do
    if uuid in acc,
      do: subtree(rest, tree, acc),
      else: subtree(Map.get(tree.children, uuid, []) ++ rest, tree, [uuid | acc])
  end

  # --- dry run -------------------------------------------------------------------------

  defp preview(plan, tree) do
    taken = removable(plan)

    plan
    |> Enum.map(fn
      {:remove, ref, category} ->
        if covered?(category, taken, tree),
          do: Common.row_ok(ref, "unchanged", category.uuid),
          else: preview_row(ref, category, tree)

      other ->
        Common.removal_row(other)
    end)
    |> Common.preview(%{"requires_confirmation" => true})
  end

  defp preview_row(ref, category, tree) do
    subtree = subtree(category.uuid, tree)

    Common.row_ok(ref, "removed", category.uuid, %{
      "name" => category.name,
      "changes" => %{"status" => %{"from" => category.status, "to" => "deleted"}},
      "subcategories" => length(subtree) - 1,
      "items" => subtree |> Enum.map(&Map.get(tree.items, &1, 0)) |> Enum.sum()
    })
  end

  defp removable(plan), do: MapSet.new(for {:remove, _ref, category} <- plan, do: category.uuid)

  # A category below another one of the request goes with it, whichever comes first.
  defp covered?(category, taken, tree),
    do: category.uuid |> ancestors(tree) |> Enum.any?(&MapSet.member?(taken, &1))

  # --- execution -------------------------------------------------------------------------

  # Ancestors go first (the order the admin's bulk trash uses), so a category listed with one of
  # its descendants takes it, whatever the order of the request: the descendant is then stamped as
  # taken by it and a restore of the ancestor brings it back. The rows are answered in request order.
  defp execute(plan, catalogue, tree, ctx) do
    opts = Common.write_opts(ctx, @tool, broadcast: false, items: :cascade)

    rows =
      plan
      |> Enum.with_index()
      |> Enum.sort_by(fn {entry, _index} -> depth(entry, tree) end)
      |> Enum.map(fn {entry, index} -> {index, run(entry, opts)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    if Enum.any?(rows, &(&1["action"] == "removed")),
      do: Catalogue.broadcast_categories_trashed(catalogue.uuid)

    Common.batch_result(rows)
  end

  defp depth({:remove, _ref, category}, tree), do: category.uuid |> ancestors(tree) |> length()
  defp depth(_entry, _tree), do: 0

  defp run({:remove, ref, category}, opts) do
    case Catalogue.trash_category_outcome(category, opts) do
      {:ok, :trashed, _trashed} ->
        Common.row_ok(ref, "removed", category.uuid)

      # Someone else trashed it after the request was planned, or an ancestor of this
      # request took it.
      {:ok, :already_trashed, _trashed} ->
        Common.row_ok(ref, "unchanged", category.uuid)

      {:error, :not_found} ->
        Common.row_error(ref, :not_found, "The category no longer exists.")

      {:error, _reason} ->
        Common.row_error(ref, :internal_error, "The category could not be moved to the trash.")
    end
  end

  defp run(other, _opts), do: Common.removal_row(other)
end
