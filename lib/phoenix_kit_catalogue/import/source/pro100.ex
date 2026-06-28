defmodule PhoenixKitCatalogue.Import.Source.Pro100 do
  @moduledoc "PRO100 import source: fixed-layout # Parts / # Materials, update-by-id."
  @behaviour PhoenixKitCatalogue.Import.Source
  alias PhoenixKitCatalogue.Import.{Matcher, Pro100Parser, Pro100Plan}

  @impl true
  def key, do: :pro100
  @impl true
  def label, do: "PRO100"
  @impl true
  def formats, do: [{:furniture, "Фурнитура (Furniture)"}, {:materials, "Материалы (Materials)"}]
  @impl true
  def accept, do: ~w(.txt)
  @impl true
  def flow, do: :sync

  @doc "Parse + match + plan against the selected catalogue's items."
  @spec analyze(binary(), :furniture | :materials, [PhoenixKitCatalogue.Schemas.Item.t()]) ::
          {:ok, map()} | {:error, term()}
  def analyze(binary, format, catalogue_items) do
    with {:ok, rows} <- Pro100Parser.parse(binary, format) do
      index = Matcher.index(catalogue_items)
      {:ok, Pro100Plan.build(rows, index)}
    end
  end
end
