defmodule PhoenixKitCatalogue.Web.Components.CatalogueBrowse do
  @moduledoc """
  Embeddable catalogue browse surface: search, category chips, and the
  photo-forward item grid as one drop-in LiveComponent — the same
  `BrowseState` + `Browse.*` stack `ItemSelectorModal` runs on, minus the
  selection chrome. Put a catalogue (or a scoped slice of one) on any
  logged-in page:

      <.live_component
        module={PhoenixKitCatalogue.Web.Components.CatalogueBrowse}
        id="showroom"
        scope={%{catalogue_uuids: [@catalogue.uuid], statuses: ["active"]}}
      />

  ## Messages to the host

  One generic message, so a host writes a single clause and switches on
  the event:

      handle_info({:catalogue_browse, %{id: id, event: :item_clicked, item: item}}, socket)

  `item` is a presented map (`Browse.present_items/2`): uuid, translated
  name, sku, price, unit, photo_url. Cards are clickable only when the
  host opts in with `on_item_click: true` — a purely decorative embedding
  never receives (or needs to handle) anything.

  ## Scope

  Identical semantics to `ItemSelectorModal`: fixed at mount, every fetch
  re-derived from it, category narrowing only within it. See
  `PhoenixKitCatalogue.Catalogue.BrowseState`.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  import PhoenixKitCatalogue.Web.Components.Browse

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.BrowseState
  alias PhoenixKitCatalogue.Web.Components.Browse

  @impl true
  def mount(socket) do
    {:ok, assign(socket, initialized: false)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id]))

    if socket.assigns.initialized do
      {:ok, socket}
    else
      browse = BrowseState.init(scope: assigns[:scope] || %{}, per_page: assigns[:per_page] || 24)
      {browse, effect} = BrowseState.command(browse, :reset)
      locale = assigns[:locale] || Gettext.get_locale(PhoenixKitCatalogue.Gettext)

      socket =
        socket
        |> assign(
          initialized: true,
          locale: locale,
          on_item_click: assigns[:on_item_click] || false,
          show_prices: Map.get(assigns, :show_prices, true),
          show_sku: Map.get(assigns, :show_sku, true),
          show_search: Map.get(assigns, :show_search, true),
          categories: chip_categories(browse.scope),
          browse: browse
        )

      {:ok, run_fetch(socket, effect)}
    end
  end

  # Same synchronous fetch discipline as ItemSelectorModal — see the note
  # there. The duplication of this small executor between the two LCs is
  # known and deliberate for now: pulling it into a shared behaviour is
  # cheap the day a third surface appears.
  defp run_fetch(socket, :noop), do: socket

  defp run_fetch(socket, {:fetch, opts, gen}) do
    %{browse: browse, locale: locale} = socket.assigns

    items = Catalogue.search_items(browse.search, opts)
    total = Catalogue.count_search_items(browse.search, opts)
    presented = Browse.present_items(items, locale)

    assign(socket, browse: BrowseState.ingest(browse, gen, presented, total))
  end

  defp chip_categories(%{catalogue_uuids: [catalogue_uuid]} = scope) do
    categories = Catalogue.list_categories_metadata_for_catalogue(catalogue_uuid)

    case scope[:category_uuids] do
      nil ->
        categories

      [] ->
        categories

      allowed ->
        allowed = Enum.map(allowed, &to_string/1)
        Enum.filter(categories, fn category -> to_string(category.uuid) in allowed end)
    end
  rescue
    _ -> []
  end

  defp chip_categories(_scope), do: []

  @impl true
  def handle_event("browse_search", %{"search" => q}, socket) do
    {browse, effect} = BrowseState.command(socket.assigns.browse, {:search, q})
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  def handle_event("browse_category", %{"uuid" => uuid}, socket) do
    cmd = {:set_category, if(uuid == "", do: nil, else: uuid)}
    {browse, effect} = BrowseState.command(socket.assigns.browse, cmd)
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  def handle_event("load_more", _params, socket) do
    {browse, effect} = BrowseState.command(socket.assigns.browse, :load_more)
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  def handle_event("card_click", %{"uuid" => uuid}, socket) do
    # Same rule as the picker: only items this surface rendered exist.
    with true <- socket.assigns.on_item_click,
         %{} = item <- Enum.find(socket.assigns.browse.items, &(&1.uuid == uuid)) do
      send(
        self(),
        {:catalogue_browse, %{id: socket.assigns.id, event: :item_clicked, item: item}}
      )

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  # A crafted payload with missing keys must degrade to a no-op, not a
  # FunctionClauseError that takes the whole LiveView down.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-3">
      <form
        :if={@show_search}
        id={"#{@id}-search-form"}
        phx-change="browse_search"
        phx-target={@myself}
      >
        <label class="input flex items-center gap-2 w-full">
          <span class="hero-magnifying-glass w-4 h-4 opacity-60"></span>
          <input
            id={"#{@id}-search"}
            type="text"
            name="search"
            value={@browse.search}
            placeholder={gettext("Search items…")}
            phx-debounce="250"
            autocomplete="off"
            class="grow"
          />
        </label>
      </form>

      <.category_chips
        :if={@categories != []}
        id={"#{@id}-chips"}
        categories={@categories}
        active_uuid={@browse.category_uuid}
        target={@myself}
      />

      <.item_grid id={"#{@id}-grid"}>
        <%= if @browse.loading? and @browse.items == [] do %>
          <.grid_skeleton id={"#{@id}-skeleton"} count={8} />
        <% end %>
        <%= for item <- @browse.items do %>
          <.item_card
            id={"#{@id}-card-#{item.uuid}"}
            item={item}
            clickable={@on_item_click}
            show_price={@show_prices}
            show_sku={@show_sku}
            target={@myself}
          />
        <% end %>
      </.item_grid>

      <div :if={@browse.items == [] and not @browse.loading?} class="text-center py-12">
        <div class="text-4xl mb-3 opacity-40">🔍</div>
        <p class="text-base-content/60">{gettext("No items match your search.")}</p>
      </div>

      <div :if={not @browse.exhausted? and @browse.items != []} class="flex justify-center py-2">
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="load_more"
          phx-target={@myself}
          disabled={@browse.loading?}
        >
          <span :if={@browse.loading?} class="loading loading-spinner loading-xs"></span>
          {gettext("Load more")}
        </button>
      </div>
    </div>
    """
  end
end
