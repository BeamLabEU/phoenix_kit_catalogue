defmodule PhoenixKitCatalogue.Web.TableQuery do
  @moduledoc """
  Pure, in-memory search → filter → sort pipeline over a list of row maps
  (catalogues/suppliers/manufacturers already loaded by the LiveView).
  """
  alias PhoenixKitCatalogue.Web.TableConfig

  @spec apply([map()], TableConfig.scope(), map()) :: [map()]
  def apply(rows, scope, opts) do
    rows
    |> search(Map.get(opts, :search, ""))
    |> filter(scope, Map.get(opts, :filters, %{}))
    |> sort(scope, Map.get(opts, :sort_by), Map.get(opts, :sort_dir, :asc))
  end

  @spec search([map()], String.t() | nil, (map() -> String.t() | nil)) :: [map()]
  def search(rows, q, field_fn \\ & &1.name)

  def search(rows, q, field_fn) when is_binary(q) and q != "" do
    needle = String.downcase(q)
    Enum.filter(rows, fn r -> String.contains?(String.downcase(field_fn.(r) || ""), needle) end)
  end

  def search(rows, _, _), do: rows

  @spec filter([map()], TableConfig.scope(), map()) :: [map()]
  def filter(rows, scope, filters) when is_map(filters) do
    Enum.reduce(filters, rows, fn
      {_id, val}, acc when val in [nil, "", "all"] -> acc
      {id, val}, acc -> Enum.filter(acc, &filter_match?(scope, id, &1, val))
    end)
  end

  def filter(rows, _scope, _), do: rows

  defp filter_match?(_scope, "folder", row, val), do: to_string(row[:folder_uuid]) == val

  defp filter_match?(_scope, id, row, val),
    do: to_string(Map.get(row, String.to_existing_atom(id))) == val

  @spec sort([map()], TableConfig.scope(), String.t() | nil, :asc | :desc) :: [map()]
  def sort(rows, scope, sort_by, dir) when is_binary(sort_by) do
    case TableConfig.column_map(scope)[sort_by] do
      %{sort_key: key} when is_function(key, 1) -> Enum.sort_by(rows, key, dir)
      _ -> rows
    end
  end

  def sort(rows, _scope, _sort_by, _dir), do: rows

  @spec enum_options([map()], TableConfig.scope(), String.t()) :: [{String.t(), String.t()}]
  def enum_options(rows, _scope, "folder") do
    rows
    |> Enum.map(&{to_string(&1[:folder_uuid]), &1[:folder_name]})
    |> Enum.reject(fn {uuid, _} -> uuid in ["", "nil"] end)
    |> Enum.uniq()
    |> Enum.sort_by(fn {_u, name} -> String.downcase(name || "") end)
  end

  def enum_options(rows, _scope, id) do
    key = String.to_existing_atom(id)

    rows
    |> Enum.map(&to_string(Map.get(&1, key)))
    |> Enum.reject(&(&1 in ["", "nil"]))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, &1})
  end
end
