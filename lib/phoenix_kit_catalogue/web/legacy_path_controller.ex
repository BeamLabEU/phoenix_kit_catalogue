defmodule PhoenixKitCatalogue.Web.LegacyPathController do
  @moduledoc """
  Sends the module's old admin address on to the current one.

  The pages lived under `/admin/catalogue` — singular, while the module is
  "Catalogues" everywhere a person reads it. They are under
  `/admin/catalogues` now, and this keeps what still points at the old
  address working: bookmarks, links in sent mail and in the activity log,
  and sibling modules released before the change.

  The settings page moved the same way, from `/admin/settings/catalogue` to
  `/admin/settings/catalogues`.

  The rest of the path, the locale and URL prefix in front of it, and the
  query string all carry over unchanged.
  """
  use PhoenixKitWeb, :controller

  @moves [
    {"/admin/settings/catalogue", "/admin/settings/catalogues"},
    {"/admin/catalogue", "/admin/catalogues"}
  ]

  def forward(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: target(conn.request_path, conn.query_string))
  end

  @doc """
  The current address for an old one. Only the module's own segment
  changes, and only where it is a whole segment — `/admin/catalogue-x` and
  an address already under `/admin/catalogues` come back as they are.
  """
  @spec target(String.t(), String.t()) :: String.t()
  def target(path, query \\ "") do
    moved =
      Enum.reduce(@moves, path, fn {old, new}, acc ->
        Regex.replace(~r{#{old}(?=/|$)}, acc, new, global: false)
      end)

    if query in [nil, ""], do: moved, else: moved <> "?" <> query
  end
end
