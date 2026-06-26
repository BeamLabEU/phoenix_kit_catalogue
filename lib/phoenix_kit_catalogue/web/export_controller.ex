defmodule PhoenixKitCatalogue.Web.ExportController do
  @moduledoc """
  Stateless controller for the catalogue export download.

  Receives `source`, `format`, `catalogue_uuid`, and optionally
  `category_uuid` as query params, builds the export in memory via
  `PhoenixKitCatalogue.Export.build/1`, and streams the result as an
  attachment. Nothing is written to disk.
  """

  use PhoenixKitWeb, :controller

  plug(PhoenixKitWeb.Users.Auth, :phoenix_kit_require_admin)

  def download(conn, params) do
    source = Map.get(params, "source", "")
    format = Map.get(params, "format", "")
    catalogue_uuid = Map.get(params, "catalogue_uuid", "")
    category_uuid = presence(Map.get(params, "category_uuid"))

    {filename, content, _mime} =
      PhoenixKitCatalogue.Export.build(%{
        source: source,
        format: format,
        catalogue_uuid: catalogue_uuid,
        category_uuid: category_uuid
      })

    send_download(conn, {:binary, IO.iodata_to_binary(content)}, filename: filename)
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(str) when is_binary(str), do: str
end
