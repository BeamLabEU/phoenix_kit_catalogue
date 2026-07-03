defmodule PhoenixKitCatalogue.Import.Matcher do
  @moduledoc """
  Matches PRO100 rows to existing catalogue items by digits-only SKU. The index
  is built once over the selected catalogue's items; resolution is O(1).
  """
  alias PhoenixKitCatalogue.Pro100.Id
  alias PhoenixKitCatalogue.Schemas.Item

  @spec index([Item.t()]) :: %{String.t() => [Item.t()]}
  def index(items) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      case Id.digits_only(item.sku) do
        "" -> acc
        key -> Map.update(acc, key, [item], &[item | &1])
      end
    end)
  end

  @spec resolve(map(), String.t()) ::
          {:matched, Item.t()} | {:ambiguous, [Item.t()]} | :unmatched
  def resolve(_index, ""), do: :unmatched

  def resolve(index, id) do
    case Map.get(index, id) do
      nil -> :unmatched
      [one] -> {:matched, one}
      many -> {:ambiguous, many}
    end
  end
end
