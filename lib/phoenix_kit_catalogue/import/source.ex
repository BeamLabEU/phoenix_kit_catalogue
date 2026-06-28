defmodule PhoenixKitCatalogue.Import.Source do
  @moduledoc "Behaviour for import sources — the inbound mirror of Export.Destination."
  @callback key() :: atom()
  @callback label() :: String.t()
  @callback formats() :: [{atom(), String.t()}]
  @callback accept() :: [String.t()]
  @callback flow() :: :mapping | :sync
end
