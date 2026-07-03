defmodule PhoenixKitCatalogue.Import.Pro100Plan do
  @moduledoc """
  Builds the PRO100 sync diff/report: matched rows become per-field change sets
  (`base_price`, materials `unit`) plus a `data["pro100"]` round-trip blob;
  unmatched/ambiguous rows go to `:skipped` for the report. Pure — no DB.
  """
  alias PhoenixKitCatalogue.Import.{Mapper, Matcher}

  @spec build([map()], map()) :: %{updates: [map()], skipped: [map()], stats: map()}
  def build(rows, index) do
    # Group rows by matched item UUID (newest-first) so that when multiple
    # PRO100 rows resolve to the same catalogue item, we compute exactly ONE
    # change entry per item rather than emitting independent writes that
    # would silently overwrite each other on apply. Policy: last-row-wins —
    # see change/3 below for why the diff is computed against the LAST row
    # only, not folded field-by-field across rows.
    {by_uuid, uuid_order, skipped} =
      Enum.reduce(rows, {%{}, [], []}, fn row, {by_uuid, order, skips} ->
        case Matcher.resolve(index, row.id) do
          {:matched, item} ->
            {new_by_uuid, new_order} =
              case Map.get(by_uuid, item.uuid) do
                nil ->
                  {Map.put(by_uuid, item.uuid, %{item: item, rows: [row]}), [item.uuid | order]}

                entry ->
                  {Map.put(by_uuid, item.uuid, %{entry | rows: [row | entry.rows]}), order}
              end

            {new_by_uuid, new_order, skips}

          {:ambiguous, items} ->
            {by_uuid, order, [%{row: row, reason: :ambiguous, items: items} | skips]}

          :unmatched ->
            {by_uuid, order, [%{row: row, reason: :unmatched} | skips]}
        end
      end)

    # Restore input order (first occurrence of each item) and reverse skipped.
    updates =
      uuid_order
      |> Enum.reverse()
      |> Enum.map(fn uuid ->
        %{item: item, rows: rows_for_item} = by_uuid[uuid]
        # `rows_for_item` accumulated newest-first; the head is the last row
        # in file order for this item, and the sole source of truth for the
        # applied change (see change/3).
        [last_row | earlier_rows] = rows_for_item
        change(item, last_row, earlier_rows)
      end)

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

  # Diffs against the TRUE pre-import `item`, using only the last row for
  # this item's own field values/data. Diffing each collided row independently
  # and then folding the resulting *changes* maps (the previous approach) is
  # unsound: a row whose raw value happens to equal `item`'s pristine value
  # produces an empty diff and so can never "win" a Map.merge, even when it's
  # the last row and should be authoritative — e.g. item.base_price = 80,
  # row1 says 100 (diff recorded), row2 (later, same item) says 80 (looks
  # like "no change" against the pristine item, contributes no key) — the
  # fold would keep row1's 80->100 even though the last row says 80. Diffing
  # the last row directly against `item` sidesteps that: the correct final
  # value for a repeatedly-asserted field is always the last row's value,
  # and comparing straight to `item` gets the diff (or lack thereof) right
  # regardless of what intermediate rows said. Earlier rows' diagnostic
  # flags (e.g. `:unit_unrecognized`) are still surfaced since they're
  # informational and non-exclusive, not per-item state.
  defp change(item, row, earlier_rows) do
    {price_changes, _} = price_change(item, row)
    {unit_changes, flags, extra_data} = unit_change(item, row)
    earlier_flags = Enum.flat_map(earlier_rows, fn r -> elem(unit_change(item, r), 1) end)

    changes = Map.merge(price_changes, unit_changes)
    data = build_data(item, row, extra_data)

    %{
      item: item,
      row: row,
      changes: changes,
      data: data,
      flags: Enum.uniq(flags ++ earlier_flags),
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
end
