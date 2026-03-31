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

  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  import PhoenixKitCatalogue.Web.Components

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue"),
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
      |> assign(:search_query, "")
      |> assign(:search_results, nil)
      |> load_data(action)

    {:noreply, socket}
  end

  defp tab_title(:index), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogues")
  defp tab_title(:manufacturers), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Manufacturers")
  defp tab_title(:suppliers), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Suppliers")

  defp confirm_delete!(socket) do
    case socket.assigns.confirm_delete do
      {_type, _uuid} = value -> value
      _ -> raise "confirm_delete not set"
    end
  end

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
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue moved to deleted."))
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue not found."))
         |> load_data(:index)}

      {:error, reason} ->
        Logger.error("Failed to trash catalogue #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete catalogue.")
         )
         |> load_data(:index)}
    end
  end

  def handle_event("restore_catalogue", %{"uuid" => uuid}, socket) do
    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.restore_catalogue(catalogue) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue restored."))
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue not found."))
         |> load_data(:index)}

      {:error, reason} ->
        Logger.error("Failed to restore catalogue #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to restore catalogue.")
         )
         |> load_data(:index)}
    end
  end

  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
  end

  def handle_event("permanently_delete_catalogue", _params, socket) do
    {"catalogue", uuid} = confirm_delete!(socket)

    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.permanently_delete_catalogue(catalogue) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue permanently deleted.")
       )
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue not found."))
         |> load_data(:index)}

      {:error, reason} ->
        Logger.error("Failed to permanently delete catalogue #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete catalogue.")
         )
         |> load_data(:index)}
    end
  end

  def handle_event("delete_manufacturer", _params, socket) do
    {"manufacturer", uuid} = confirm_delete!(socket)

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
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete manufacturer.")
         )
         |> assign(:confirm_delete, nil)}
    end
  end

  def handle_event("delete_supplier", _params, socket) do
    {"supplier", uuid} = confirm_delete!(socket)

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
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete supplier.")
         )
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
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div role="tablist" class="tabs tabs-bordered">
          <.link
            patch={Paths.index()}
            class={["tab", @active_tab == :index && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogues")}
          </.link>
          <.link
            patch={Paths.manufacturers()}
            class={["tab", @active_tab == :manufacturers && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Manufacturers")}
          </.link>
          <.link
            patch={Paths.suppliers()}
            class={["tab", @active_tab == :suppliers && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Suppliers")}
          </.link>
        </div>

        <div class="self-end sm:self-auto">
          <.link :if={@active_tab == :index && @catalogue_view_mode == "active"} navigate={Paths.catalogue_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "New Catalogue")}
          </.link>
          <.link :if={@active_tab == :manufacturers} navigate={Paths.manufacturer_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "New Manufacturer")}
          </.link>
          <.link :if={@active_tab == :suppliers} navigate={Paths.supplier_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "New Supplier")}
          </.link>
        </div>
      </div>

      <%!-- Global search (only on catalogues tab) --%>
      <.search_input :if={@active_tab == :index} query={@search_query} placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Search items across all catalogues...")} />

      <%!-- Search results --%>
      <div :if={@search_results != nil} class="flex flex-col gap-4">
        <.search_results_summary count={length(@search_results)} query={@search_query} />

        <.empty_state :if={@search_results == []} message={Gettext.gettext(PhoenixKitWeb.Gettext, "No items match your search.")} />

        <.item_table
          :if={@search_results != []}
          items={@search_results}
          columns={[:name, :sku, :base_price, :catalogue, :category, :manufacturer, :status]}
          variant="zebra"
          edit_path={&Paths.item_edit/1}
          catalogue_path={&Paths.catalogue_detail/1}
          cards={true}
          id="global-search-items"
        />
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
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Permanently Delete Catalogue")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitWeb.Gettext, "This will permanently delete this catalogue, all its categories, and all items. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"manufacturer", _}, @confirm_delete)}
        on_confirm="delete_manufacturer"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Manufacturer")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitWeb.Gettext, "This will permanently delete this manufacturer. Items referencing it will lose the association.")}]}
        confirm_text={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"supplier", _}, @confirm_delete)}
        on_confirm="delete_supplier"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Supplier")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitWeb.Gettext, "This will permanently delete this supplier. Manufacturer links will be removed.")}]}
        confirm_text={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
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
          {if @view_mode == "deleted", do: Gettext.gettext(PhoenixKitWeb.Gettext, "No deleted catalogues."), else: Gettext.gettext(PhoenixKitWeb.Gettext, "No catalogues yet.")}
        </p>
      </div>
    </div>

    <div :if={@catalogues != []}>
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id={"catalogues-#{@view_mode}"} items={@catalogues}
        card_fields={fn c -> [
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Status"), value: String.capitalize(c.status)},
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Updated"), value: Calendar.strftime(c.updated_at, "%Y-%m-%d %H:%M")}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Updated")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</.table_default_header_cell>
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
            <.table_default_cell><PhoenixKitWeb.Components.Core.Badge.status_badge status={catalogue.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">
              {Calendar.strftime(catalogue.updated_at, "%Y-%m-%d %H:%M")}
            </.table_default_cell>
            <%!-- Active mode actions --%>
            <.table_default_cell :if={@view_mode == "active"} class="text-right whitespace-nowrap">
              <.table_row_menu mode="auto" id={"cat-menu-#{catalogue.uuid}"}>
                <.table_row_menu_link navigate={Paths.catalogue_detail(catalogue.uuid)} icon="hero-eye" label="View" />
                <.table_row_menu_link navigate={Paths.catalogue_edit(catalogue.uuid)} icon="hero-pencil" label="Edit" variant="secondary" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="trash_catalogue" phx-value-uuid={catalogue.uuid} icon="hero-trash" label="Delete" variant="error" />
              </.table_row_menu>
            </.table_default_cell>
            <%!-- Deleted mode actions --%>
            <.table_default_cell :if={@view_mode == "deleted"} class="text-right whitespace-nowrap">
              <.table_row_menu mode="auto" id={"cat-del-menu-#{catalogue.uuid}"}>
                <.table_row_menu_button phx-click="restore_catalogue" phx-value-uuid={catalogue.uuid} icon="hero-arrow-path" label="Restore" variant="success" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={catalogue.uuid} phx-value-type="catalogue" icon="hero-trash" label="Delete Forever" variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={catalogue}>
          <.link :if={@view_mode == "active"} navigate={Paths.catalogue_detail(catalogue.uuid)} class="font-medium text-sm link link-hover">{catalogue.name}</.link>
          <span :if={@view_mode == "deleted"} class="font-medium text-sm text-base-content/50">{catalogue.name}</span>
        </:card_header>
        <:card_actions :let={catalogue} :if={@view_mode == "active"}>
          <.link navigate={Paths.catalogue_detail(catalogue.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitWeb.Gettext, "View")}</.link>
          <.link navigate={Paths.catalogue_edit(catalogue.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}</.link>
          <button phx-click="trash_catalogue" phx-value-uuid={catalogue.uuid} class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}</button>
        </:card_actions>
        <:card_actions :let={catalogue} :if={@view_mode == "deleted"}>
          <button phx-click="restore_catalogue" phx-value-uuid={catalogue.uuid} class="btn btn-ghost btn-xs text-success">{Gettext.gettext(PhoenixKitWeb.Gettext, "Restore")}</button>
          <button phx-click="show_delete_confirm" phx-value-uuid={catalogue.uuid} phx-value-type="catalogue" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}</button>
        </:card_actions>
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
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id="manufacturers-list" items={@manufacturers}
        card_fields={fn m -> [
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Website"), value: m.website || "—"},
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Status"), value: String.capitalize(m.status)}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Website")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={m <- @manufacturers}>
            <.table_default_cell class="font-medium">{m.name}</.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{m.website}</.table_default_cell>
            <.table_default_cell><PhoenixKitWeb.Components.Core.Badge.status_badge status={m.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="auto" id={"mfg-menu-#{m.uuid}"}>
                <.table_row_menu_link navigate={Paths.manufacturer_edit(m.uuid)} icon="hero-pencil" label="Edit" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={m.uuid} phx-value-type="manufacturer" icon="hero-trash" label="Delete" variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={m}>
          <.link navigate={Paths.manufacturer_edit(m.uuid)} class="font-medium text-sm link link-hover">{m.name}</.link>
        </:card_header>
        <:card_actions :let={m}>
          <.link navigate={Paths.manufacturer_edit(m.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}</.link>
          <button phx-click="show_delete_confirm" phx-value-uuid={m.uuid} phx-value-type="manufacturer" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}</button>
        </:card_actions>
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
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id="suppliers-list" items={@suppliers}
        card_fields={fn s -> [
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Website"), value: s.website || "—"},
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Status"), value: String.capitalize(s.status)}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Website")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={s <- @suppliers}>
            <.table_default_cell class="font-medium">{s.name}</.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{s.website}</.table_default_cell>
            <.table_default_cell><PhoenixKitWeb.Components.Core.Badge.status_badge status={s.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="auto" id={"supplier-menu-#{s.uuid}"}>
                <.table_row_menu_link navigate={Paths.supplier_edit(s.uuid)} icon="hero-pencil" label="Edit" variant="secondary" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={s.uuid} phx-value-type="supplier" icon="hero-trash" label="Delete" variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={s}>
          <.link navigate={Paths.supplier_edit(s.uuid)} class="font-medium text-sm link link-hover">{s.name}</.link>
        </:card_header>
        <:card_actions :let={s}>
          <.link navigate={Paths.supplier_edit(s.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}</.link>
          <button phx-click="show_delete_confirm" phx-value-uuid={s.uuid} phx-value-type="supplier" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}</button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end
end
