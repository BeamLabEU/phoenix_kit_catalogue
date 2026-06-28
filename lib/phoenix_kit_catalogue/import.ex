defmodule PhoenixKitCatalogue.Import do
  @moduledoc "Import context: source registry (inbound mirror of Export)."
  @sources [
    PhoenixKitCatalogue.Import.Source.Universal,
    PhoenixKitCatalogue.Import.Source.Pro100
  ]

  @spec sources() :: [module()]
  def sources, do: @sources

  @spec source_by_key(atom() | String.t()) :: module() | nil
  def source_by_key(key) when is_atom(key), do: Enum.find(@sources, &(&1.key() == key))

  def source_by_key(key) when is_binary(key) do
    source_by_key(String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end
end
