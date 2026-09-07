defmodule PhoenixKitCatalogue.Extensions do
  @moduledoc """
  Discovery and absorption for `PhoenixKitCatalogue.Extension` implementers
  — the item/category form "extension slot" (spec §2 principle 8, §4 row
  C4).

  Discovery is duck-typed, mirroring `PhoenixKitAI.Translatables`'
  `ai_translatables/0` pattern: any module registered with
  `PhoenixKit.ModuleRegistry` that exports `catalogue_extensions/0` gets
  its returned modules folded in, filtered to those reporting
  `enabled?/0`. Catalogue never references an implementer by name — an
  unregistered or disabled host changes nothing (spec §4 row C4's
  regression rule: forms without a registered extension render exactly as
  before).
  """

  alias PhoenixKit.ModuleRegistry

  @doc """
  All enabled extension modules contributed by registered `PhoenixKit`
  modules, in registration order, deduplicated.
  """
  @spec all() :: [module()]
  def all do
    ModuleRegistry.all_modules()
    |> Enum.flat_map(&contributed_by/1)
    |> Enum.uniq()
    |> Enum.filter(&enabled?/1)
  end

  defp contributed_by(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :catalogue_extensions, 0) do
      case mod.catalogue_extensions() do
        list when is_list(list) -> list
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp enabled?(ext) do
    Code.ensure_loaded?(ext) and function_exported?(ext, :enabled?, 0) and ext.enabled?()
  rescue
    _ -> false
  end

  @doc """
  Enabled extension modules that render a section for `kind` (`:item` or
  `:category`) — i.e. export `item_section/1` (or `category_section/1`).
  """
  @spec sections(:item | :category) :: [module()]
  def sections(kind) do
    callback = section_callback(kind)
    Enum.filter(all(), &function_exported?(&1, callback, 1))
  end

  defp section_callback(:item), do: :item_section
  defp section_callback(:category), do: :category_section
  defp cast_callback(:item), do: :cast_item
  defp cast_callback(:category), do: :cast_category

  @doc """
  Folds every enabled extension's submitted namespace into `data`.

  For each enabled extension `E` exporting the `kind`-appropriate cast
  callback: takes `params[E.key()]` (a map, or `%{}` when absent/nil),
  calls `E.cast_item/2` (or `cast_category/2`) with the extension's
  current value `data[E.key()] || %{}`, and merges the result under
  `data[E.key()]`. Stops at the first extension that returns an error.
  """
  @spec absorb(:item | :category, map(), map()) ::
          {:ok, map()} | {:error, {module(), [{atom(), String.t()}]}}
  def absorb(kind, params, data)
      when kind in [:item, :category] and is_map(params) and is_map(data) do
    cast_fun = cast_callback(kind)

    Enum.reduce_while(all(), {:ok, data}, fn ext, {:ok, acc} ->
      if function_exported?(ext, cast_fun, 2) do
        absorb_one(ext, cast_fun, params, acc)
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp absorb_one(ext, cast_fun, params, acc) do
    ext_params = as_map(Map.get(params, ext.key()))
    current = as_map(Map.get(acc, ext.key()))

    case apply(ext, cast_fun, [ext_params, current]) do
      {:ok, casted} -> {:cont, {:ok, Map.put(acc, ext.key(), casted)}}
      {:error, errors} -> {:halt, {:error, {ext, errors}}}
    end
  end

  defp as_map(map) when is_map(map), do: map
  defp as_map(_), do: %{}
end
