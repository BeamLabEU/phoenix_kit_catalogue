defmodule PhoenixKitCatalogue.Catalogue.PubSub do
  @moduledoc """
  Real-time fan-out for catalogue mutations.

  Every successful write in the Catalogue context broadcasts a small
  `{:catalogue_data_changed, kind, uuid, parent_catalogue_uuid}` event
  to a single shared topic. List/detail LiveViews `subscribe/0` once in
  `mount/3` (after `connected?(socket)`) and re-fetch the affected
  slice on any event, so two admins editing the same data converge
  without manual refresh.

  `parent_catalogue_uuid` lets a detail LV cheaply ignore broadcasts
  for unrelated catalogues — without it, *every* item edit anywhere in
  the system would force every open detail page to reload its slice.
  Global resources (manufacturers, suppliers, manufacturer↔supplier
  links) carry `nil` here; consumers that care about them subscribe
  to the `kind` regardless of parent.

  Payloads are intentionally minimal — UUID + kind + parent, no record
  data — to (a) avoid leaking field-level changes through PubSub, and
  (b) keep the consumer in charge of how much to re-load (single row
  vs full list).

  Subscriptions are cleaned up automatically when the LV process
  terminates; callers don't need to unsubscribe.
  """

  @topic "phoenix_kit_catalogue"

  @typedoc "Resource kind that mutated."
  @type kind ::
          :catalogue
          | :category
          | :item
          | :manufacturer
          | :supplier
          | :smart_rule
          | :links

  @typedoc "Event message format for `handle_info/2`."
  @type event ::
          {:catalogue_data_changed, kind(), Ecto.UUID.t() | nil, Ecto.UUID.t() | nil}

  @doc "Returns the canonical topic name. Useful for tests."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the current process to the catalogue PubSub topic.

  Call from `mount/3` guarded by `connected?(socket)` so the
  disconnected (initial render) pass doesn't subscribe and never
  unsubscribes. Do this **after** any subscription requirements but
  **before** the initial DB load to avoid a race where a write between
  the load and the subscribe leaves the UI stale.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      PhoenixKit.PubSubHelper.subscribe(@topic)
    else
      :ok
    end
  end

  @doc """
  Broadcasts a `{:catalogue_data_changed, kind, uuid, parent_catalogue_uuid}`
  event after a successful write.

  * `uuid` — UUID of the resource that mutated; `nil` when the change
    isn't tied to a specific record (e.g. a bulk link sync).
  * `parent_catalogue_uuid` — UUID of the catalogue that contains the
    mutated resource, or the UUID itself for `kind: :catalogue` events.
    Pass `nil` for resources that aren't scoped to a single catalogue
    (`:manufacturer`, `:supplier`, `:links`); detail LVs use this to
    filter out cross-catalogue noise.
  """
  @spec broadcast(kind(), Ecto.UUID.t() | nil, Ecto.UUID.t() | nil) :: :ok
  def broadcast(kind, uuid, parent_catalogue_uuid \\ nil) when is_atom(kind) do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      PhoenixKit.PubSubHelper.broadcast(
        @topic,
        {:catalogue_data_changed, kind, uuid, parent_catalogue_uuid}
      )
    end

    :ok
  end
end
