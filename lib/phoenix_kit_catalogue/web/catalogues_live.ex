defmodule PhoenixKitCatalogue.Web.CataloguesLive do
  @moduledoc """
  Landing page for the Catalogue module.

  Handles three actions via tabs:
  - `:index` — list of catalogues
  - `:manufacturers` — list of manufacturers
  - `:suppliers` — list of suppliers
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.Badge, only: [status_badge: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Catalogue",
       catalogues: [],
       manufacturers: [],
       suppliers: [],
       confirm_delete: nil,
       catalogue_view_mode: "active",
       deleted_catalogue_count: 0,
       search_query: "",
       search_results: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    action = socket.assigns.live_action || :index

    socket =
      socket
      |> assign(:active_tab, action)
      |> assign(:page_title, tab_title(action))
      |> load_data(action)

    {:noreply, socket}
  end

  defp tab_title(:index), do: "Catalogues"
  defp tab_title(:manufacturers), do: "Manufacturers"
  defp tab_title(:suppliers), do: "Suppliers"

  defp load_data(socket, :index) do
    if connected?(socket) do
      mode = socket.assigns.catalogue_view_mode

      catalogues =
        if mode == "deleted",
          do: Catalogue.list_catalogues(status: "deleted"),
          else: Catalogue.list_catalogues()

      deleted_count = Catalogue.deleted_catalogue_count()

      # Auto-switch to active if no deleted catalogues
      mode = if deleted_count == 0 && mode == "deleted", do: "active", else: mode

      catalogues =
        if mode != socket.assigns.catalogue_view_mode,
          do: Catalogue.list_catalogues(),
          else: catalogues

      assign(socket,
        catalogues: catalogues,
        deleted_catalogue_count: deleted_count,
        catalogue_view_mode: mode
      )
    else
      socket
    end
  end

  defp load_data(socket, :manufacturers) do
    if connected?(socket),
      do: assign(socket, :manufacturers, Catalogue.list_manufacturers()),
      else: socket
  end

  defp load_data(socket, :suppliers) do
    if connected?(socket),
      do: assign(socket, :suppliers, Catalogue.list_suppliers()),
      else: socket
  end

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("switch_catalogue_view", %{"mode" => mode}, socket)
      when mode in ~w(active deleted) do
    {:noreply,
     socket
     |> assign(:catalogue_view_mode, mode)
     |> assign(:confirm_delete, nil)
     |> load_data(:index)}
  end

  def handle_event("trash_catalogue", %{"uuid" => uuid}, socket) do
    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.trash_catalogue(catalogue) do
      {:noreply,
       socket
       |> put_flash(:info, "Catalogue moved to deleted.")
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply, socket |> put_flash(:error, "Catalogue not found.") |> load_data(:index)}

      {:error, reason} ->
        Logger.error("Failed to trash catalogue #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket |> put_flash(:error, "Failed to delete catalogue.") |> load_data(:index)}
    end
  end

  def handle_event("restore_catalogue", %{"uuid" => uuid}, socket) do
    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.restore_catalogue(catalogue) do
      {:noreply,
       socket
       |> put_flash(:info, "Catalogue restored.")
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply, socket |> put_flash(:error, "Catalogue not found.") |> load_data(:index)}

      {:error, reason} ->
        Logger.error("Failed to restore catalogue #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket |> put_flash(:error, "Failed to restore catalogue.") |> load_data(:index)}
    end
  end

  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
  end

  def handle_event("permanently_delete_catalogue", _params, socket) do
    {"catalogue", uuid} = socket.assigns.confirm_delete

    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.permanently_delete_catalogue(catalogue) do
      {:noreply,
       socket
       |> put_flash(:info, "Catalogue permanently deleted.")
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, "Catalogue not found.")
         |> load_data(:index)}

      {:error, reason} ->
        Logger.error("Failed to permanently delete catalogue #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, "Failed to delete catalogue.")
         |> load_data(:index)}
    end
  end

  def handle_event("delete_manufacturer", _params, socket) do
    {"manufacturer", uuid} = socket.assigns.confirm_delete

    with %{} = manufacturer <- Catalogue.get_manufacturer(uuid),
         {:ok, _} <- Catalogue.delete_manufacturer(manufacturer) do
      {:noreply,
       assign(socket, manufacturers: Catalogue.list_manufacturers(), confirm_delete: nil)}
    else
      nil ->
        {:noreply, assign(socket, :confirm_delete, nil)}

      {:error, reason} ->
        Logger.error("Failed to delete manufacturer #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete manufacturer.")
         |> assign(:confirm_delete, nil)}
    end
  end

  def handle_event("delete_supplier", _params, socket) do
    {"supplier", uuid} = socket.assigns.confirm_delete

    with %{} = supplier <- Catalogue.get_supplier(uuid),
         {:ok, _} <- Catalogue.delete_supplier(supplier) do
      {:noreply, assign(socket, suppliers: Catalogue.list_suppliers(), confirm_delete: nil)}
    else
      nil ->
        {:noreply, assign(socket, :confirm_delete, nil)}

      {:error, reason} ->
        Logger.error("Failed to delete supplier #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete supplier.")
         |> assign(:confirm_delete, nil)}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, search_query: "", search_results: nil)}
    else
      results = Catalogue.search_items(query)
      {:noreply, assign(socket, search_query: query, search_results: results)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, search_query: "", search_results: nil)}
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Tab navigation --%>
      <div class="flex items-center justify-between">
        <div role="tablist" class="tabs tabs-bordered">
          <.link
            patch={Paths.index()}
            class={["tab", @active_tab == :index && "tab-active"]}
          >
            Catalogues
          </.link>
          <.link
            patch={Paths.manufacturers()}
            class={["tab", @active_tab == :manufacturers && "tab-active"]}
          >
            Manufacturers
          </.link>
          <.link
            patch={Paths.suppliers()}
            class={["tab", @active_tab == :suppliers && "tab-active"]}
          >
            Suppliers
          </.link>
        </div>

        <div>
          <.link :if={@active_tab == :index && @catalogue_view_mode == "active"} navigate={Paths.catalogue_new()} class="btn btn-primary btn-sm">
            New Catalogue
          </.link>
          <.link :if={@active_tab == :manufacturers} navigate={Paths.manufacturer_new()} class="btn btn-primary btn-sm">
            New Manufacturer
          </.link>
          <.link :if={@active_tab == :suppliers} navigate={Paths.supplier_new()} class="btn btn-primary btn-sm">
            New Supplier
          </.link>
        </div>
      </div>

      <%!-- Global search --%>
      <div class="flex gap-2">
        <form phx-change="search" phx-submit="search" class="flex-1 relative">
          <input
            type="text"
            name="query"
            value={@search_query}
            placeholder="Search items across all catalogues..."
            class="input input-bordered input-sm w-full pr-8"
            phx-debounce="300"
            autocomplete="off"
          />
          <button
            :if={@search_query != ""}
            type="button"
            phx-click="clear_search"
            class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-base-content cursor-pointer"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </form>
      </div>

      <%!-- Search results --%>
      <div :if={@search_results != nil} class="flex flex-col gap-4">
        <div class="flex items-center justify-between">
          <span class="text-sm text-base-content/60">
            {length(@search_results)} result{if length(@search_results) != 1, do: "s"} for "{@search_query}"
          </span>
        </div>

        <div :if={@search_results == []} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-8">
            <p class="text-base-content/60">No items match your search.</p>
          </div>
        </div>

        <div :if={@search_results != []}>
          <.table_default variant="zebra" size="sm">
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell>Name</.table_default_header_cell>
                <.table_default_header_cell>SKU</.table_default_header_cell>
                <.table_default_header_cell>Base Price</.table_default_header_cell>
                <.table_default_header_cell>Catalogue</.table_default_header_cell>
                <.table_default_header_cell>Category</.table_default_header_cell>
                <.table_default_header_cell>Manufacturer</.table_default_header_cell>
                <.table_default_header_cell>Status</.table_default_header_cell>
                <.table_default_header_cell class="text-right">Actions</.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <.table_default_row :for={item <- @search_results}>
                <.table_default_cell class="font-medium">{item.name}</.table_default_cell>
                <.table_default_cell class="font-mono text-base-content/60 text-sm">{item.sku || "—"}</.table_default_cell>
                <.table_default_cell class="text-sm">{format_price(item.base_price)}</.table_default_cell>
                <.table_default_cell class="text-sm">
                  <.link :if={item.category} navigate={Paths.catalogue_detail(item.category.catalogue.uuid)} class="link link-hover">
                    {item.category.catalogue.name}
                  </.link>
                </.table_default_cell>
                <.table_default_cell class="text-sm text-base-content/60">{if item.category, do: item.category.name, else: "—"}</.table_default_cell>
                <.table_default_cell class="text-sm text-base-content/60">{if item.manufacturer, do: item.manufacturer.name, else: "—"}</.table_default_cell>
                <.table_default_cell><.status_badge status={item.status} size={:xs} /></.table_default_cell>
                <.table_default_cell class="text-right">
                  <.table_row_menu id={"search-menu-#{item.uuid}"}>
                    <.table_row_menu_link navigate={Paths.item_edit(item.uuid)} icon="hero-pencil" label="Edit" />
                  </.table_row_menu>
                </.table_default_cell>
              </.table_default_row>
            </.table_default_body>
          </.table_default>
        </div>
      </div>

      <%!-- Catalogue tab content --%>
      <div :if={@active_tab == :index and is_nil(@search_results)} class="flex flex-col gap-4">
        <%!-- Status sub-tabs for catalogues --%>
        <div :if={@deleted_catalogue_count > 0} class="flex items-center gap-0.5 border-b border-base-200">
          <button
            type="button"
            phx-click="switch_catalogue_view"
            phx-value-mode="active"
            class={[
              "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer",
              if(@catalogue_view_mode == "active",
                do: "border-primary text-primary",
                else: "border-transparent text-base-content/50 hover:text-base-content"
              )
            ]}
          >
            Active
          </button>
          <button
            type="button"
            phx-click="switch_catalogue_view"
            phx-value-mode="deleted"
            class={[
              "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer",
              if(@catalogue_view_mode == "deleted",
                do: "border-error text-error",
                else: "border-transparent text-base-content/50 hover:text-base-content"
              )
            ]}
          >
            Deleted ({@deleted_catalogue_count})
          </button>
        </div>

        <.catalogues_table catalogues={@catalogues} view_mode={@catalogue_view_mode} />
      </div>

      <div :if={@active_tab == :manufacturers and is_nil(@search_results)}>
        <.manufacturers_table manufacturers={@manufacturers} />
      </div>

      <div :if={@active_tab == :suppliers and is_nil(@search_results)}>
        <.suppliers_table suppliers={@suppliers} />
      </div>

      <.confirm_modal
        show={match?({"catalogue", _}, @confirm_delete)}
        on_confirm="permanently_delete_catalogue"
        on_cancel="cancel_delete"
        title="Permanently Delete Catalogue"
        title_icon="hero-trash"
        messages={[{:warning, "This will permanently delete this catalogue, all its categories, and all items. This cannot be undone."}]}
        confirm_text="Delete Forever"
        danger={true}
      />

      <.confirm_modal
        show={match?({"manufacturer", _}, @confirm_delete)}
        on_confirm="delete_manufacturer"
        on_cancel="cancel_delete"
        title="Delete Manufacturer"
        title_icon="hero-trash"
        messages={[{:warning, "This will permanently delete this manufacturer. Items referencing it will lose the association."}]}
        confirm_text="Delete"
        danger={true}
      />

      <.confirm_modal
        show={match?({"supplier", _}, @confirm_delete)}
        on_confirm="delete_supplier"
        on_cancel="cancel_delete"
        title="Delete Supplier"
        title_icon="hero-trash"
        messages={[{:warning, "This will permanently delete this supplier. Manufacturer links will be removed."}]}
        confirm_text="Delete"
        danger={true}
      />
    </div>
    """
  end

  defp catalogues_table(assigns) do
    ~H"""
    <div :if={@catalogues == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">
          {if @view_mode == "deleted", do: "No deleted catalogues.", else: "No catalogues yet."}
        </p>
      </div>
    </div>

    <div :if={@catalogues != []}>
      <.table_default variant="zebra" size="sm">
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>Name</.table_default_header_cell>
            <.table_default_header_cell>Status</.table_default_header_cell>
            <.table_default_header_cell>Updated</.table_default_header_cell>
            <.table_default_header_cell class="text-right">Actions</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={catalogue <- @catalogues}>
            <.table_default_cell>
              <.link :if={@view_mode == "active"} navigate={Paths.catalogue_detail(catalogue.uuid)} class="link link-hover font-medium">
                {catalogue.name}
              </.link>
              <span :if={@view_mode == "deleted"} class="font-medium text-base-content/50">{catalogue.name}</span>
            </.table_default_cell>
            <.table_default_cell><.status_badge status={catalogue.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">
              {Calendar.strftime(catalogue.updated_at, "%Y-%m-%d %H:%M")}
            </.table_default_cell>
            <%!-- Active mode actions --%>
            <.table_default_cell :if={@view_mode == "active"} class="text-right">
              <.table_row_menu id={"cat-menu-#{catalogue.uuid}"}>
                <.table_row_menu_link navigate={Paths.catalogue_detail(catalogue.uuid)} icon="hero-eye" label="View" />
                <.table_row_menu_link navigate={Paths.catalogue_edit(catalogue.uuid)} icon="hero-pencil" label="Edit" variant="secondary" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="trash_catalogue" phx-value-uuid={catalogue.uuid} icon="hero-trash" label="Delete" variant="error" />
              </.table_row_menu>
            </.table_default_cell>
            <%!-- Deleted mode actions --%>
            <.table_default_cell :if={@view_mode == "deleted"} class="text-right">
              <.table_row_menu id={"cat-del-menu-#{catalogue.uuid}"}>
                <.table_row_menu_button phx-click="restore_catalogue" phx-value-uuid={catalogue.uuid} icon="hero-arrow-path" label="Restore" variant="success" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={catalogue.uuid} phx-value-type="catalogue" icon="hero-trash" label="Delete Forever" variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>
    </div>
    """
  end

  defp manufacturers_table(assigns) do
    ~H"""
    <div :if={@manufacturers == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">No manufacturers yet.</p>
      </div>
    </div>

    <div :if={@manufacturers != []}>
      <.table_default variant="zebra" size="sm">
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>Name</.table_default_header_cell>
            <.table_default_header_cell>Website</.table_default_header_cell>
            <.table_default_header_cell>Status</.table_default_header_cell>
            <.table_default_header_cell class="text-right">Actions</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={m <- @manufacturers}>
            <.table_default_cell class="font-medium">{m.name}</.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{m.website}</.table_default_cell>
            <.table_default_cell><.status_badge status={m.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-right">
              <.table_row_menu id={"mfg-menu-#{m.uuid}"}>
                <.table_row_menu_link navigate={Paths.manufacturer_edit(m.uuid)} icon="hero-pencil" label="Edit" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={m.uuid} phx-value-type="manufacturer" icon="hero-trash" label="Delete" variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>
    </div>
    """
  end

  defp suppliers_table(assigns) do
    ~H"""
    <div :if={@suppliers == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">No suppliers yet.</p>
      </div>
    </div>

    <div :if={@suppliers != []}>
      <.table_default variant="zebra" size="sm">
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>Name</.table_default_header_cell>
            <.table_default_header_cell>Website</.table_default_header_cell>
            <.table_default_header_cell>Status</.table_default_header_cell>
            <.table_default_header_cell class="text-right">Actions</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={s <- @suppliers}>
            <.table_default_cell class="font-medium">{s.name}</.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{s.website}</.table_default_cell>
            <.table_default_cell><.status_badge status={s.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-right">
              <.table_row_menu id={"supplier-menu-#{s.uuid}"}>
                <.table_row_menu_link navigate={Paths.supplier_edit(s.uuid)} icon="hero-pencil" label="Edit" variant="secondary" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={s.uuid} phx-value-type="supplier" icon="hero-trash" label="Delete" variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>
    </div>
    """
  end

  defp format_price(nil), do: "—"
  defp format_price(price), do: Decimal.to_string(price, :normal)
end
