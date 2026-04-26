defmodule PhoenixKitCatalogue.Web.Helpers do
  @moduledoc """
  Tiny utilities shared by every catalogue LiveView. Imported into LVs
  via the standard `import PhoenixKitCatalogue.Web.Helpers` line.

  Currently exports:

    * `actor_opts/1` — extract the current user's UUID from socket
      assigns, return `[actor_uuid: uuid]` for the `opts \\\\ []` keyword
      list every mutating context function accepts. Returns `[]` when
      no user is signed in (e.g. inside a test that mounts the LV with
      a bare conn). The atom is suitable to thread through
      `Catalogue.create_*` / `update_*` / `trash_*` / `restore_*` /
      `permanently_delete_*` etc.
    * `actor_uuid/1` — the raw UUID (or `nil`). Use when you need the
      value directly rather than a keyword list, e.g. when building
      activity-log metadata in a LiveView.
  """

  @typedoc "Convenience alias for the keyword list shape mutating ctx fns accept."
  @type actor_opts :: [actor_uuid: Ecto.UUID.t()] | []

  @doc """
  Extracts `[actor_uuid: uuid]` from `socket.assigns.phoenix_kit_current_user`.

  Returns `[]` when no user is signed in. Pass the result straight into
  any `PhoenixKitCatalogue.Catalogue` mutating function as its trailing
  `opts` argument.
  """
  @spec actor_opts(Phoenix.LiveView.Socket.t()) :: actor_opts()
  def actor_opts(socket) do
    case actor_uuid(socket) do
      nil -> []
      uuid -> [actor_uuid: uuid]
    end
  end

  @doc """
  Returns the current user's UUID from socket assigns, or `nil`.
  """
  @spec actor_uuid(Phoenix.LiveView.Socket.t()) :: Ecto.UUID.t() | nil
  def actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  @doc """
  Translates a catalogue/category/item/manufacturer/supplier `status`
  field value to a localised label via gettext.

  Handles every status string that any catalogue schema can emit
  (`active` / `inactive` / `archived` / `deleted` / `discontinued`)
  with explicit literal `gettext(...)` clauses so `mix gettext.extract`
  picks them up. Unknown status values pass through unchanged — never
  use `String.capitalize/1` on translated text because the result
  would pin English casing on a value the extractor can't see.
  """
  @spec status_label(String.t() | nil) :: String.t()
  def status_label("active"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Active")
  def status_label("inactive"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Inactive")
  def status_label("archived"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Archived")
  def status_label("deleted"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Deleted")
  def status_label("discontinued"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Discontinued")
  def status_label(other) when is_binary(other), do: other
  def status_label(_), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Unknown")
end
