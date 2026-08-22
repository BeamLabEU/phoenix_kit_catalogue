defmodule PhoenixKitCatalogue.Test.SelectorHostLive do
  @moduledoc """
  Test-only host for `ItemSelectorModal`: mounts the LiveComponent with a
  scope built from query params and renders every message the component
  sends back into inspectable DOM, so tests assert the REAL contract — the
  process messages a production host would receive — rather than component
  internals.

  Query params:

    * `c`         — catalogue uuid for `scope.catalogue_uuids`
    * `pre`       — preselection, `uuid:qty[,uuid:qty…]`
    * `mode`      — "single" for `mode: :single`
    * `immediate` — "true" with single mode
    * `precision` — qty_precision (default 0)
    * `max`       — qty_max
    * `two`       — "true" mounts a SECOND picker (id-uniqueness tests)
  """

  use Phoenix.LiveView

  alias PhoenixKitCatalogue.Web.Components.CatalogueBrowse
  alias PhoenixKitCatalogue.Web.Components.ItemSelectorModal

  @impl true
  def mount(params, _session, socket) do
    scope = build_scope(params)

    selected =
      (params["pre"] || "")
      |> String.split(",", trim: true)
      |> Map.new(fn pair ->
        [uuid, qty] = String.split(pair, ":")
        {uuid, Decimal.new(qty)}
      end)

    {:ok,
     assign(socket,
       show: true,
       scope: scope,
       selected: selected,
       mode: if(params["mode"] == "single", do: :single, else: :multiple),
       immediate: params["immediate"] == "true",
       precision: String.to_integer(params["precision"] || "0"),
       max: params["max"] && String.to_integer(params["max"]),
       two: params["two"] == "true",
       browse: params["browse"] == "true",
       clicked: nil,
       picked: nil,
       closed: false
     )}
  end

  defp build_scope(params) do
    scope =
      case params["c"] do
        nil -> %{}
        uuid -> %{catalogue_uuids: [uuid]}
      end

    scope =
      case params["cat_scope"] do
        nil -> scope
        uuid -> Map.put(scope, :category_uuids, [uuid])
      end

    if params["only"] == "uncategorized",
      do: Map.put(scope, :only, :uncategorized_only),
      else: scope
  end

  @impl true
  def handle_info({:items_selected, payload}, socket),
    do: {:noreply, assign(socket, picked: payload)}

  def handle_info({:catalogue_browse, %{event: :item_clicked, item: item}}, socket),
    do: {:noreply, assign(socket, clicked: item)}

  def handle_info({:item_selector_closed, %{id: _}}, socket),
    do: {:noreply, assign(socket, closed: true)}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.live_component
        :if={@browse}
        module={CatalogueBrowse}
        id="surface"
        scope={@scope}
        on_item_click={true}
      />
      <.live_component
        :if={@show and not @browse}
        module={ItemSelectorModal}
        id="picker"
        scope={@scope}
        selected={@selected}
        mode={@mode}
        immediate={@immediate}
        qty_precision={@precision}
        qty_max={@max}
      />
      <.live_component
        :if={@show and @two}
        module={ItemSelectorModal}
        id="picker2"
        scope={@scope}
        selected={%{}}
      />

      <%!-- The contract, made assertable. --%>
      <div :if={@clicked} id="clicked">{@clicked.name}|{@clicked.sku}</div>
      <div :if={@picked} id="picked">
        <span id="picked-count">{length(@picked.picks)}</span>
        <div :for={pick <- @picked.picks} id={"pick-#{pick.uuid}"}>
          {pick.name}|{pick.sku}|qty={Decimal.to_string(pick.qty, :normal)}|decimal={inspect(match?(%Decimal{}, pick.qty))}|line={pick.line_total && Decimal.to_string(pick.line_total, :normal)}
        </div>
      </div>
      <div :if={@closed} id="closed">closed</div>
    </div>
    """
  end
end
