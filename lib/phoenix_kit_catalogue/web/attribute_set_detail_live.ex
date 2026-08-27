defmodule PhoenixKitCatalogue.Web.AttributeSetDetailLive do
  @moduledoc """
  Single attribute-set page (`catalogue/attributes/:uuid`) — the rich
  counterpart to the sets listing's capped previews: every value as a
  chip strip, and the attached items as a real table/card listing with
  photo, price, category, status, and the item's SELECTED values of
  this set.

  Read-only like the listing (2026-08-27 direction): editing lives in
  the entities module; the header links there. The items listing keeps
  the scale rules — paginated (25/page), searched server-side, and
  the value chips capped with a "+N" into entities.
  """

  use Phoenix.LiveView

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitCatalogue.Web.Components, only: [view_mode_toggle: 1]

  alias PhoenixKit.Utils.Routes, as: KitRoutes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.Components.Browse

  @page_size 25
  @values_shown 30

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    if connected?(socket), do: CataloguePubSub.subscribe()

    # The SET row loads on BOTH passes: the not-found redirect must fire
    # on the dead render too, and the header needs the name. The heavy
    # parts (values, items page, counts) wait for the connected pass —
    # the dead render shows a skeleton, never an empty state.
    case Catalogue.attribute_sets_enabled?() &&
           Catalogue.get_attribute_set(uuid, lang: socket.assigns[:current_locale]) do
      %{} = set ->
        socket =
          assign(socket,
            set: set,
            page_title: set.display_name || set.name,
            loaded: false,
            values: [],
            value_count: 0,
            item_rows: [],
            items_total: 0,
            items_page: 1,
            items_max_page: 1,
            items_search: ""
          )

        {:ok, if(connected?(socket), do: load_data(socket), else: socket)}

      _ ->
        {:ok,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute set not found.")
         )
         |> push_navigate(to: Paths.attribute_groups())}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("items_search", %{"q" => q}, socket) do
    {:noreply,
     socket
     |> assign(items_search: String.slice(q, 0, 200), items_page: 1)
     |> load_data()}
  end

  def handle_event("items_page", %{"dir" => dir}, socket) do
    delta = if dir == "next", do: 1, else: -1

    {:noreply,
     socket
     |> assign(:items_page, socket.assigns.items_page + delta)
     |> load_data()}
  end

  # Any item or set mutation can change this page (attachments ride the
  # :item kind, value edits the :attribute_set kind) — reload the page's
  # own slice; it is cheap by construction.
  @impl true
  def handle_info({:catalogue_data_changed, kind, _uuid, _parent}, socket)
      when kind in [:item, :attribute_set] do
    {:noreply, load_data(socket)}
  end

  def handle_info({:catalogue_bulk_change, _cat, _kind, _uuids, _from}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_data(socket) do
    set = socket.assigns.set
    locale = socket.assigns[:current_locale]

    # The FULL value list in one query: the chip strip caps what it
    # shows, but item selections reference value slugs anywhere in the
    # set, so label resolution needs the whole slug → title map.
    values = Catalogue.list_attribute_set_values(set.uuid, lang: locale)
    label_map = Map.new(values, &{&1.slug, &1.title})

    search = socket.assigns.items_search
    total = Catalogue.count_attribute_set_attached_items(set.uuid, search: search)
    max_page = max(ceil(total / @page_size), 1)
    page = socket.assigns.items_page |> max(1) |> min(max_page)

    rows =
      Catalogue.list_attribute_set_attached_items(set.uuid,
        search: search,
        limit: @page_size,
        offset: (page - 1) * @page_size
      )

    entries = Browse.present_items(Enum.map(rows, & &1.item), locale)

    item_rows =
      Enum.zip_with(rows, entries, fn %{item: item, selected_slugs: slugs}, entry ->
        Map.merge(entry, %{
          status: item.status,
          catalogue_name: catalogue_name(item, locale),
          # Ghost rule: slugs whose value no longer exists are dropped,
          # exactly like every other selection reader.
          selected: slugs |> Enum.filter(&Map.has_key?(label_map, &1)) |> Enum.map(&label_map[&1])
        })
      end)

    assign(socket,
      loaded: true,
      values: values,
      value_count: length(values),
      item_rows: item_rows,
      items_total: total,
      items_page: page,
      items_max_page: max_page
    )
  end

  defp catalogue_name(%{catalogue: %{name: _} = catalogue}, locale) do
    (Catalogue.localize_one(catalogue, locale) || catalogue).name
  end

  defp catalogue_name(_item, _locale), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <%!-- Header: back into the listing, name, edit links into entities. --%>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <.link navigate={Paths.attribute_groups()} class="btn btn-ghost btn-xs btn-circle">
              <.icon name="hero-arrow-left" class="w-4 h-4" />
            </.link>
            <h1 class="text-xl font-semibold truncate">{@set.display_name || @set.name}</h1>
          </div>
          <p :if={@loaded} class="text-sm text-base-content/60 mt-1">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{values} values · %{items} items",
              values: @value_count,
              items: @items_total
            )}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.link
            navigate={KitRoutes.path("/admin/entities/#{@set.name}/data")}
            class="btn btn-sm btn-ghost"
          >
            <.icon name="hero-pencil-square" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit values")}
          </.link>
          <.link
            navigate={KitRoutes.path("/admin/entities/#{@set.uuid}/edit")}
            class="btn btn-sm btn-ghost"
          >
            <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Set settings")}
          </.link>
        </div>
      </div>

      <div :if={!@loaded} class="flex flex-col gap-3" aria-busy="true">
        <div class="skeleton h-8 w-64"></div>
        <div class="skeleton h-24 w-full"></div>
        <div class="skeleton h-24 w-full"></div>
      </div>

      <%!-- Values strip — capped chips, "+N" into entities. --%>
      <div :if={@loaded} class="flex flex-wrap items-center gap-1">
        <span
          :for={v <- Enum.take(@values, values_cap(@value_count))}
          class="badge badge-outline badge-sm"
        >
          {v.title}
        </span>
        <.link
          :if={@value_count > values_cap(@value_count)}
          navigate={KitRoutes.path("/admin/entities/#{@set.name}/data")}
          class="badge badge-ghost badge-sm link link-hover"
        >
          +{@value_count - values_cap(@value_count)}
        </.link>
        <span :if={@value_count == 0} class="text-sm text-base-content/50">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No values yet")}
        </span>
      </div>

      <%!-- Items listing: search + view toggle + table/card faces. --%>
      <div :if={@loaded} class="flex flex-wrap items-center gap-2">
        <%!-- phx-submit is load-bearing (Enter would native-submit). --%>
        <form
          id="attr-set-items-search"
          class="flex-1 min-w-48"
          phx-change="items_search"
          phx-submit="items_search"
        >
          <label class="input input-sm w-full flex items-center gap-2">
            <span class="hero-magnifying-glass w-4 h-4 opacity-60"></span>
            <input
              type="text"
              name="q"
              value={@items_search}
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search items…")}
              phx-debounce="250"
              autocomplete="off"
              spellcheck="false"
              class="grow"
            />
          </label>
        </form>
        <.view_mode_toggle storage_key="catalogue-attr-set-items" />
      </div>

      <p
        :if={@loaded and @items_total == 0 and String.trim(@items_search) != ""}
        class="text-sm text-base-content/60 py-4 text-center"
      >
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items match your search.")}
      </p>

      <p
        :if={@loaded and @items_total == 0 and String.trim(@items_search) == ""}
        class="text-sm text-base-content/60 py-4 text-center border border-dashed border-base-content/20 rounded-lg"
      >
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items attached.")}
      </p>

      <.table_default
        :if={@loaded and @item_rows != []}
        id="attr-set-items-table"
        size="sm"
        variant="zebra"
        toggleable={true}
        show_toggle={false}
        storage_key="catalogue-attr-set-items"
        items={@item_rows}
        wrapper_class="overflow-x-auto rounded-lg border border-base-content/10 shadow-none"
      >
        <.table_default_header>
          <tr>
            <th class="w-12"></th>
            <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}</th>
            <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Location")}</th>
            <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price")}</th>
            <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Selected values")}</th>
            <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}</th>
          </tr>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={row <- @item_rows} id={"attr-set-item-#{row.uuid}"}>
            <.table_default_cell class="align-top">
              <.item_thumb row={row} />
            </.table_default_cell>
            <.table_default_cell class="align-top">
              <.link navigate={Paths.item_edit(row.uuid)} class="font-medium link link-hover">
                {row.name}
              </.link>
            </.table_default_cell>
            <.table_default_cell class="align-top text-sm text-base-content/70">
              <.item_location row={row} />
            </.table_default_cell>
            <.table_default_cell class="align-top whitespace-nowrap">
              <.item_price row={row} />
            </.table_default_cell>
            <.table_default_cell class="align-top">
              <.selected_chips row={row} />
            </.table_default_cell>
            <.table_default_cell class="align-top">
              <.status_badge status={row.status} />
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>

        <:card_header :let={row}>
          <div class="flex items-center gap-3">
            <.item_thumb row={row} />
            <div class="min-w-0">
              <.link navigate={Paths.item_edit(row.uuid)} class="font-semibold link link-hover">
                {row.name}
              </.link>
              <div class="text-xs text-base-content/60">
                <.item_location row={row} />
              </div>
            </div>
          </div>
        </:card_header>
        <:card_body :let={row}>
          <div class="flex items-center justify-between gap-2">
            <.item_price row={row} />
            <.status_badge status={row.status} />
          </div>
          <div class="mt-2">
            <.selected_chips row={row} />
          </div>
        </:card_body>
        <:card_actions :let={_row}><span /></:card_actions>
      </.table_default>

      <div :if={@loaded and @items_max_page > 1} class="flex items-center justify-end gap-2">
        <span class="text-xs text-base-content/50">
          {@items_page} / {@items_max_page}
        </span>
        <div class="join">
          <button
            type="button"
            class="btn btn-xs join-item"
            disabled={@items_page <= 1}
            phx-click="items_page"
            phx-value-dir="prev"
          >
            «
          </button>
          <button
            type="button"
            class="btn btn-xs join-item"
            disabled={@items_page >= @items_max_page}
            phx-click="items_page"
            phx-value-dir="next"
          >
            »
          </button>
        </div>
      </div>
    </div>
    """
  end

  # The chip strip's cap — but never elide exactly one value: at
  # cap + 1 total, the extra chip costs less than a "+1".
  defp values_cap(count) when count <= @values_shown + 1, do: @values_shown + 1
  defp values_cap(_count), do: @values_shown

  attr(:row, :map, required: true)

  defp item_thumb(assigns) do
    ~H"""
    <img
      :if={@row.photo_url}
      src={@row.photo_url}
      alt=""
      class="w-10 h-10 rounded object-cover bg-base-200 shrink-0"
      loading="lazy"
    />
    <div
      :if={!@row.photo_url}
      class="w-10 h-10 rounded bg-base-200 flex items-center justify-center shrink-0"
    >
      <.icon name="hero-photo" class="w-5 h-5 text-base-content/30" />
    </div>
    """
  end

  attr(:row, :map, required: true)

  defp item_location(assigns) do
    ~H"""
    <span :if={@row.catalogue_name}>{@row.catalogue_name}</span><span :if={
      @row.catalogue_name && @row.category
    }> / </span><span :if={@row.category}>{@row.category}</span><span :if={
      !@row.catalogue_name && !@row.category
    }>—</span>
    """
  end

  attr(:row, :map, required: true)

  defp item_price(assigns) do
    ~H"""
    <span :if={@row.price} class="font-medium">
      {Browse.format_price(@row.price)}<span :if={@row.unit} class="text-base-content/50 font-normal">/{@row.unit}</span>
    </span>
    <span :if={!@row.price} class="text-base-content/40">—</span>
    """
  end

  attr(:row, :map, required: true)

  defp selected_chips(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1">
      <span :for={label <- @row.selected} class="badge badge-outline badge-sm">{label}</span>
      <span :if={@row.selected == []} class="text-sm text-base-content/40">—</span>
    </div>
    """
  end

  attr(:status, :string, required: true)

  defp status_badge(assigns) do
    ~H"""
    <span :if={@status == "active"} class="badge badge-success badge-sm badge-outline">
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active")}
    </span>
    <span :if={@status != "active"} class="badge badge-ghost badge-sm">{@status}</span>
    """
  end
end
