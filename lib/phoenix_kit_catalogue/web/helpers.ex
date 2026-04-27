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
    * `log_operation_error/3` — engineer-visible `Logger.error` for a
      failed mutation **plus** an Activity row tagged
      `db_pending: true` so the user-visible audit feed records the
      attempted action even when it fails. See
      `PhoenixKitCatalogue.Catalogue.ActivityLog` for the
      success-vs-failure layering.
  """

  require Logger

  alias PhoenixKitCatalogue.Catalogue.ActivityLog

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

  @doc """
  Logs a failed LV mutation in two places at once:

  1. **Engineer log** — `Logger.error` with the operation, the
     LV-level entity context, and the changeset / atom reason. This
     is the rich-context line that production-incident triage reads.
  2. **User-visible audit row** — an Activity entry with the same
     action atom the success path would have written, plus
     `metadata.db_pending: true`. The audit feed therefore records
     **what the user attempted**, not just **what succeeded** — a
     deliberate change in the post-Apr 2026 pipeline (workspace
     `AGENTS.md` C12 agent #2 — "Activity logging coverage").

  The action atom is derived from `operation` via
  `derive_activity_action/2`. Validation cycles (form-validate
  events) never reach this helper — by construction it's only called
  from `{:error, _}` handle_event branches, where the failure is a
  real infrastructure / consistency error worth auditing.

  ## Expected `context` keys

    * `:entity_type` — `"item"` / `"category"` / `"catalogue"` /
      `"manufacturer"` / `"supplier"` (drives both the activity
      `resource_type` and the action-atom prefix).
    * `:entity_uuid` — primary-key UUID; lands as `resource_uuid`.
    * `:reason` — an `%Ecto.Changeset{}`, an atom, or any other
      `inspect`able shape. Logged engineer-side; on the audit row
      it's summarised into PII-safe `metadata.error_keys` (changeset
      field names only — never values, since user-typed strings can
      carry PII).

  Activity-log failures (missing table, ownership errors, sandbox
  exit) are swallowed by `ActivityLog.log/1`; they never bubble up
  to the LV.
  """
  @spec log_operation_error(Phoenix.LiveView.Socket.t(), String.t(), map()) :: :ok
  def log_operation_error(socket, operation, context) do
    actor = actor_uuid(socket)
    ctx = Map.put_new(context, :actor_uuid, actor)

    Logger.error(fn ->
      [
        catalogue_lv_label(socket),
        " ",
        operation,
        " failed: ",
        format_error_context(ctx)
      ]
    end)

    entity_type = Map.get(context, :entity_type)
    entity_uuid = Map.get(context, :entity_uuid)
    reason = Map.get(context, :reason)

    case derive_activity_action(operation, entity_type) do
      nil ->
        :ok

      action ->
        ActivityLog.log(%{
          action: action,
          mode: "manual",
          actor_uuid: actor,
          resource_type: entity_type,
          resource_uuid: entity_uuid,
          metadata: build_failure_metadata(reason)
        })
    end
  end

  @doc """
  Maps an LV operation string + entity_type to the canonical activity
  action atom the catalogue context already uses on the success path.

  Falls back to `nil` when the operation doesn't follow the
  `<verb>_<entity>` shape; the caller skips the audit-row write in
  that case (engineer log still fires).
  """
  @spec derive_activity_action(String.t(), String.t() | nil) :: String.t() | nil
  def derive_activity_action(operation, entity_type)
      when is_binary(operation) and is_binary(entity_type) do
    case verb_for(operation) do
      nil -> nil
      past -> "#{entity_type}.#{past}"
    end
  end

  def derive_activity_action(_, _), do: nil

  # Operation prefix → past-tense action verb. Order matters:
  # `permanently_delete_` must be checked before `delete_`.
  @verb_map [
    {"permanently_delete_", "permanently_deleted"},
    {"trash_", "trashed"},
    {"restore_", "restored"},
    {"delete_", "deleted"}
  ]

  defp verb_for(operation) do
    Enum.find_value(@verb_map, fn {prefix, past} ->
      if String.starts_with?(operation, prefix), do: past
    end)
  end

  # ── Private ──────────────────────────────────────────────────────

  defp catalogue_lv_label(%Phoenix.LiveView.Socket{view: view}) when is_atom(view) do
    view |> Module.split() |> List.last() |> to_string()
  end

  defp format_error_context(%{reason: reason} = ctx) do
    rest = Map.delete(ctx, :reason)

    [
      inspect(rest, limit: :infinity),
      " reason=",
      format_reason(reason)
    ]
  end

  defp format_reason(%Ecto.Changeset{} = cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)

    "changeset_errors=#{inspect(errors)}"
  end

  defp format_reason(other), do: inspect(other)

  # PII-safe metadata: only field names from a changeset, not values
  # (user-typed strings can carry PII). For non-changeset reasons,
  # store the atom or a `:other` marker.
  defp build_failure_metadata(%Ecto.Changeset{} = cs) do
    %{
      "db_pending" => true,
      "error_kind" => "changeset",
      "error_keys" => cs.errors |> Enum.map(fn {k, _} -> Atom.to_string(k) end) |> Enum.uniq()
    }
  end

  defp build_failure_metadata(reason) when is_atom(reason) do
    %{"db_pending" => true, "error_kind" => "atom", "reason" => Atom.to_string(reason)}
  end

  defp build_failure_metadata(_other) do
    %{"db_pending" => true, "error_kind" => "other"}
  end
end
