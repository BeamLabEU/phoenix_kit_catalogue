defmodule PhoenixKitCatalogue.Pro100.Id do
  @moduledoc """
  PRO100 numeric id: the SKU reduced to digits only (`"76.0026.12"` ->
  `"76002612"`). Shared by the PRO100 export (id column) and import (match key)
  so the two never drift. `nil`/no-digit -> `""`.
  """
  @spec digits_only(String.t() | nil) :: String.t()
  def digits_only(nil), do: ""
  def digits_only(sku) when is_binary(sku), do: String.replace(sku, ~r/\D/, "")
end
