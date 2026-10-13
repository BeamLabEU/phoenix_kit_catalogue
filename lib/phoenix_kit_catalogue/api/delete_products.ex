defmodule PhoenixKitCatalogue.API.DeleteProducts do
  @moduledoc false
  # Tool `catalogue.delete_products` (spec 6.1, 4.4): trash, never delete.

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.Common
  alias PhoenixKitCatalogue.Catalogue

  @tool "catalogue.delete_products"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"], writable: true) do
      resolutions = API.resolve_refs(input["refs"], kind: :item, catalogue_uuid: catalogue.uuid)
      plan = plan(resolutions, catalogue)

      if ctx.dry_run?, do: preview(plan), else: execute(plan, catalogue, ctx)
    end
  end

  # --- planning (reads only) ---------------------------------------------------------

  # `{:remove, ref, item}`, `{:already, ref, item}` (an id already in the trash),
  # `{:rejected, ref, message}` or `{:resolution_error, ref, reason}`.
  defp plan(resolutions, catalogue) do
    trashed = trashed_by_id(resolutions, catalogue)

    {planned, _seen} =
      Enum.map_reduce(resolutions, MapSet.new(), fn
        {ref, {:ok, item}}, seen ->
          if MapSet.member?(seen, item.uuid),
            do: {{:rejected, ref, "The same item appears twice in this request."}, seen},
            else: {{:remove, ref, item}, MapSet.put(seen, item.uuid)}

        {ref, {:error, :not_found}}, seen ->
          case trashed_item(trashed, ref) do
            nil -> {{:resolution_error, ref, :not_found}, seen}
            item -> {{:already, ref, item}, seen}
          end

        {ref, {:error, reason}}, seen ->
          {{:resolution_error, ref, reason}, seen}
      end)

    planned
  end

  # An `id` that matched no LIVE item may name one that is already in the trash.
  defp trashed_by_id(resolutions, catalogue) do
    refs =
      for {%{"id" => id} = ref, {:error, :not_found}} <- resolutions,
          match?({:ok, _}, Ecto.UUID.cast(id)),
          do: ref

    case refs do
      [] ->
        %{}

      refs ->
        refs
        |> API.resolve_refs(kind: :item, catalogue_uuid: catalogue.uuid, include_deleted: true)
        |> Enum.flat_map(fn
          {_ref, {:ok, %{status: "deleted"} = item}} -> [{item.uuid, item}]
          _other -> []
        end)
        |> Map.new()
    end
  end

  defp trashed_item(trashed, %{"id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Map.get(trashed, uuid)
      :error -> nil
    end
  end

  defp trashed_item(_trashed, _ref), do: nil

  # --- dry run -------------------------------------------------------------------------

  defp preview(plan) do
    plan
    |> Enum.map(fn
      {:remove, ref, item} ->
        Common.row_ok(ref, "removed", item.uuid, %{
          "name" => item.name,
          "changes" => %{"status" => %{"from" => item.status, "to" => "deleted"}}
        })

      other ->
        outcome_row(other)
    end)
    |> Common.preview()
  end

  # --- execution -------------------------------------------------------------------------

  defp execute(plan, catalogue, ctx) do
    opts = Common.write_opts(ctx, @tool, broadcast: false)

    rows =
      Enum.map(plan, fn
        {:remove, ref, item} -> trash(ref, item, opts)
        other -> outcome_row(other)
      end)

    removed = for %{"action" => "removed", "id" => id} <- rows, do: id
    Catalogue.broadcast_item_batch_change(catalogue.uuid, :trashed, removed)

    Common.batch_result(rows)
  end

  defp trash(ref, item, opts) do
    case Catalogue.trash_item(item, opts) do
      {:ok, _trashed} ->
        Common.row_ok(ref, "removed", item.uuid)

      {:error, :not_found} ->
        Common.row_error(ref, :not_found, "The item no longer exists.")

      {:error, _reason} ->
        Common.row_error(ref, :internal_error, "The item could not be moved to the trash.")
    end
  end

  # Rows that do not depend on the mode.
  defp outcome_row({:already, ref, item}), do: Common.row_ok(ref, "unchanged", item.uuid)

  defp outcome_row({:rejected, ref, message}),
    do:
      Common.row_error(ref, :validation_failed, message, %{
        "errors" => [%{"path" => "refs", "message" => message}]
      })

  defp outcome_row({:resolution_error, ref, reason}), do: Common.resolution_error(ref, reason)
end
