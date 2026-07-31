defmodule PhoenixKitCatalogue.Import.Matcher do
  @moduledoc """
  Matches PRO100 rows to existing catalogue items.

  The file identifies a row by a numeric code, which is our SKU reduced to digits
  (`Pro100.Id.digits_only/1`). That reduction is lossy — it drops the decor letter
  and the finish, so `73.U767.18` and `73.U767.PM.18` both become `7376718`.
  Matching on it alone leaves every such row permanently ambiguous: on a real
  export, 28 codes were shared by 62 rows, none of which could ever be updated.

  Resolution therefore tries `{digits, name}` first and falls back to digits alone
  only when that is unique. The name decides when the code cannot; the code still
  decides when the name has drifted.

  Both indexes skip items whose SKU carries no digits. That is what stops a
  code-less file row from matching a SKU-less item by name alone — the file's
  `Tööpind` spacer row (price `0.00`) is named like a real item and would zero
  its price.
  """
  alias PhoenixKitCatalogue.Pro100.Id
  alias PhoenixKitCatalogue.Schemas.Item

  @type t :: %{
          digits: %{String.t() => [Item.t()]},
          digits_name: %{{String.t(), String.t()} => [Item.t()]}
        }

  @spec index([Item.t()]) :: t()
  def index(items) do
    Enum.reduce(items, %{digits: %{}, digits_name: %{}}, fn item, acc ->
      case Id.digits_only(item.sku) do
        "" ->
          acc

        key ->
          %{
            digits: Map.update(acc.digits, key, [item], &[item | &1]),
            digits_name:
              Map.update(acc.digits_name, {key, normalize_name(item.name)}, [item], &[item | &1])
          }
      end
    end)
  end

  @doc """
  Collapses a name to its match key: case-folded, whitespace-collapsed, trimmed.

  Applied to `item.name` when the index is built and to the row name when a row
  is resolved. It must stay a single function: two copies that drift by one
  character make the name stage silently stop matching, and the symptom looks
  like a data problem rather than a code one.

      iex> PhoenixKitCatalogue.Import.Matcher.normalize_name("  MP  U741   ST9 ")
      "mp u741 st9"

      iex> PhoenixKitCatalogue.Import.Matcher.normalize_name(nil)
      ""
  """
  @spec normalize_name(String.t() | nil) :: String.t()
  def normalize_name(nil), do: ""

  def normalize_name(name) when is_binary(name) do
    name |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  @doc """
  Resolves one row against the index.

  Stages, in order: a blank id never matches; `{id, name}` wins when unique; the
  id alone wins when unique; an id held by several items is refused rather than
  guessed.
  """
  @spec resolve(t(), String.t(), String.t() | nil) ::
          {:matched, Item.t()} | {:ambiguous, [Item.t()]} | :unmatched
  def resolve(_index, "", _name), do: :unmatched

  def resolve(index, id, name) do
    case Map.get(index.digits_name, {id, normalize_name(name)}) do
      [one] -> {:matched, one}
      _none_or_several -> resolve_by_digits(index, id)
    end
  end

  defp resolve_by_digits(index, id) do
    case Map.get(index.digits, id) do
      nil -> :unmatched
      [one] -> {:matched, one}
      many -> {:ambiguous, many}
    end
  end
end
