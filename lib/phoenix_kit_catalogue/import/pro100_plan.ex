defmodule PhoenixKitCatalogue.Import.Pro100Plan do
  @moduledoc """
  Builds the PRO100 sync diff/report: matched rows become per-field change sets
  (`base_price`, materials `unit`) plus a `data["pro100"]` round-trip blob;
  unmatched/ambiguous rows go to `:skipped` for the report. Pure — no DB.
  """
  alias PhoenixKitCatalogue.Import.{Mapper, Matcher}

  @spec build([map()], map()) :: %{updates: [map()], skipped: [map()], stats: map()}
  def build(rows, index) do
    # Accumulate changes in a map keyed by item UUID so that if multiple PRO100
    # rows resolve to the same catalogue item we fold them into ONE change entry
    # rather than emitting two independent writes (each built from the item's
    # pre-import snapshot) that would silently overwrite each other on apply.
    # Policy: last-row-wins for conflicting fields — an explicit, intentional
    # choice implemented as a reduce, not as an accidental second DB write.
    {by_uuid, uuid_order, skipped} =
      Enum.reduce(rows, {%{}, [], []}, fn row, {by_uuid, order, skips} ->
        case Matcher.resolve(index, row.id) do
          {:matched, item} ->
            c = change(item, row)

            {new_by_uuid, new_order} =
              if Map.has_key?(by_uuid, item.uuid) do
                {Map.update!(by_uuid, item.uuid, &merge_changes(&1, c)), order}
              else
                {Map.put(by_uuid, item.uuid, c), [item.uuid | order]}
              end

            {new_by_uuid, new_order, skips}

          {:ambiguous, _} ->
            {by_uuid, order, [%{row: row, reason: :ambiguous} | skips]}

          :unmatched ->
            {by_uuid, order, [%{row: row, reason: :unmatched} | skips]}
        end
      end)

    # Restore input order (first occurrence of each item) and reverse skipped.
    updates = uuid_order |> Enum.reverse() |> Enum.map(&by_uuid[&1])
    skipped = Enum.reverse(skipped)

    %{
      updates: updates,
      skipped: skipped,
      stats: %{
        update: Enum.count(updates, &(&1.status == :update)),
        nochange: Enum.count(updates, &(&1.status == :nochange)),
        unmatched: Enum.count(skipped, &(&1.reason == :unmatched)),
        ambiguous: Enum.count(skipped, &(&1.reason == :ambiguous))
      }
    }
  end

  defp change(item, row) do
    {price_changes, _} = price_change(item, row)
    {unit_changes, flags, extra_data} = unit_change(item, row)

    changes = Map.merge(price_changes, unit_changes)
    data = build_data(item, row, extra_data)

    %{
      item: item,
      row: row,
      changes: changes,
      data: data,
      flags: flags,
      status: if(map_size(changes) > 0, do: :update, else: :nochange)
    }
  end

  defp price_change(item, %{base_price: new}) when not is_nil(new) do
    cond do
      is_nil(item.base_price) -> {%{base_price: {nil, new}}, :changed}
      Decimal.equal?(item.base_price, new) -> {%{}, :same}
      true -> {%{base_price: {item.base_price, new}}, :changed}
    end
  end

  defp price_change(_item, _row), do: {%{}, :same}

  # materials: resolve unit; unknown -> keep current unit, flag + stash raw.
  # furniture (unit: nil) and blank labels fall through to the catch-all.
  defp unit_change(item, %{format: :materials, unit: label})
       when is_binary(label) and label != "" do
    case Mapper.resolve_pro100_unit(label) do
      {:ok, unit} ->
        if unit == item.unit,
          do: {%{}, [], %{}},
          else: {%{unit: {item.unit, unit}}, [], %{}}

      :unknown ->
        {%{}, [:unit_unrecognized], %{"original_unit" => label}}
    end
  end

  defp unit_change(_item, _row), do: {%{}, [], %{}}

  defp build_data(item, row, extra) do
    pro100 = Map.put(row.service, "format", Atom.to_string(row.format))
    base = item.data || %{}

    base
    |> Map.put("pro100", pro100)
    |> Map.merge(extra)
  end

  # Folds a newer change into an existing one when two PRO100 rows resolve to
  # the same item. The newer row wins for all conflicting fields. `data` is
  # merged with Map.merge/2 so the newer row's "pro100" key overwrites the
  # older one. Flags from both rows are kept (concatenated) since they are
  # non-exclusive diagnostics, not per-item state.
  defp merge_changes(existing, newer) do
    merged_status =
      if existing.status == :update or newer.status == :update, do: :update, else: :nochange

    %{
      item: existing.item,
      row: newer.row,
      changes: Map.merge(existing.changes, newer.changes),
      data: Map.merge(existing.data, newer.data),
      flags: existing.flags ++ newer.flags,
      status: merged_status
    }
  end
end
