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
    * `min`       — qty_min
    * `max`       — qty_max
    * `view`      — starting view, "table" | "card" (nil = component default)
    * `cols`      — comma list of table columns, e.g. "thumb,name,qty"
                    (unknown names map to :invalid_column so the modal's
                    own validation raise can be exercised)
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
       min: params["min"] && String.to_integer(params["min"]),
       max: params["max"] && String.to_integer(params["max"]),
       view: params["view"],
       cols: parse_cols(params["cols"]),
       show_prices: params["hide_prices"] != "true",
       two: params["two"] == "true",
       browse: params["browse"] == "true",
       clicked: nil,
       picked: nil,
       closed: false
     )}
  end

  defp build_scope(params) do
    %{}
    |> maybe_put_catalogue(params["c"])
    |> maybe_put_category(params["cat_scope"])
    |> maybe_put_only(params["only"])
    |> maybe_put_statuses(params["statuses"])
  end

  defp maybe_put_catalogue(scope, nil), do: scope
  defp maybe_put_catalogue(scope, uuid), do: Map.put(scope, :catalogue_uuids, [uuid])

  defp maybe_put_category(scope, nil), do: scope
  defp maybe_put_category(scope, uuid), do: Map.put(scope, :category_uuids, [uuid])

  defp maybe_put_only(scope, "uncategorized"), do: Map.put(scope, :only, :uncategorized_only)
  defp maybe_put_only(scope, "categorized"), do: Map.put(scope, :only, :categorized_only)
  defp maybe_put_only(scope, _), do: scope

  @col_atoms Map.new(~w(thumb name sku manufacturer unit price qty), &{&1, String.to_atom(&1)})

  defp parse_cols(nil), do: nil

  defp parse_cols(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&(@col_atoms[&1] || :invalid_column))
  end

  defp maybe_put_statuses(scope, nil), do: scope

  defp maybe_put_statuses(scope, raw),
    do: Map.put(scope, :statuses, String.split(raw, ",", trim: true))

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
        qty_min={@min}
        qty_max={@max}
        view={@view}
        columns={@cols}
        show_prices={@show_prices}
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
