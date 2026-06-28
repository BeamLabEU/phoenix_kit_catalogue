defmodule PhoenixKitCatalogue.Import.Pro100Plan do
  @moduledoc """
  Builds the PRO100 sync diff/report: matched rows become per-field change sets
  (`base_price`, materials `unit`) plus a `data["pro100"]` round-trip blob;
  unmatched/ambiguous rows go to `:skipped` for the report. Pure — no DB.
  """
  alias PhoenixKitCatalogue.Import.{Mapper, Matcher}

  @spec build([map()], map()) :: %{updates: [map()], skipped: [map()], stats: map()}
  def build(rows, index) do
    {updates, skipped} =
      Enum.reduce(rows, {[], []}, fn row, {ups, skips} ->
        case Matcher.resolve(index, row.id) do
          {:matched, item} -> {[change(item, row) | ups], skips}
          {:ambiguous, _} -> {ups, [%{row: row, reason: :ambiguous} | skips]}
          :unmatched -> {ups, [%{row: row, reason: :unmatched} | skips]}
        end
      end)

    updates = Enum.reverse(updates)
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
end
