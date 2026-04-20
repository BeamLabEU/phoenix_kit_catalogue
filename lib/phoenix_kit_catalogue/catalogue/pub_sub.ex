defmodule PhoenixKitCatalogue.Catalogue.PubSub do
  @moduledoc """
  Real-time fan-out for catalogue mutations.

  Every successful write in the Catalogue context broadcasts a small
  `{:catalogue_data_changed, kind, uuid}` event to a single shared
  topic. List/detail LiveViews `subscribe/0` once in `mount/3` (after
  `connected?(socket)`) and re-fetch the affected slice on any event,
  so two admins editing the same data converge without manual refresh.

  Payloads are intentionally minimal — UUID + kind, no record data —
  to (a) avoid leaking field-level changes through PubSub, and (b)
  keep the consumer in charge of how much to re-load (single row vs
  full list).

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
  @type event :: {:catalogue_data_changed, kind(), Ecto.UUID.t() | nil}

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
  Broadcasts a `{:catalogue_data_changed, kind, uuid}` event after a
  successful write. Pass `nil` for `uuid` when the change isn't tied
  to a specific record (e.g. a bulk link sync).
  """
  @spec broadcast(kind(), Ecto.UUID.t() | nil) :: :ok
  def broadcast(kind, uuid) when is_atom(kind) do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      PhoenixKit.PubSubHelper.broadcast(@topic, {:catalogue_data_changed, kind, uuid})
    end

    :ok
  end
end
