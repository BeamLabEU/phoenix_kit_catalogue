defmodule PhoenixKitCatalogue.Web.CataloguesLive do
  @moduledoc """
  Landing page for the Catalogue module.

  Handles three actions via tabs:
  - `:index` — list of catalogues
  - `:manufacturers` — list of manufacturers
  - `:suppliers` — list of suppliers
  """

  use Phoenix.LiveView

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
       confirm_delete: nil
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
    if connected?(socket),
      do: assign(socket, :catalogues, Catalogue.list_catalogues()),
      else: socket
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

  @impl true
  def handle_event("delete_catalogue", %{"uuid" => uuid}, socket) do
    if socket.assigns.confirm_delete == uuid do
      catalogue = Catalogue.get_catalogue(uuid)

      if catalogue do
        {:ok, _} = Catalogue.delete_catalogue(catalogue)
        {:noreply, assign(socket, catalogues: Catalogue.list_catalogues(), confirm_delete: nil)}
      else
        {:noreply, assign(socket, :confirm_delete, nil)}
      end
    else
      {:noreply, assign(socket, :confirm_delete, uuid)}
    end
  end

  def handle_event("delete_manufacturer", %{"uuid" => uuid}, socket) do
    if socket.assigns.confirm_delete == uuid do
      manufacturer = Catalogue.get_manufacturer(uuid)

      if manufacturer do
        {:ok, _} = Catalogue.delete_manufacturer(manufacturer)

        {:noreply,
         assign(socket,
           manufacturers: Catalogue.list_manufacturers(),
           confirm_delete: nil
         )}
      else
        {:noreply, assign(socket, :confirm_delete, nil)}
      end
    else
      {:noreply, assign(socket, :confirm_delete, uuid)}
    end
  end

  def handle_event("delete_supplier", %{"uuid" => uuid}, socket) do
    if socket.assigns.confirm_delete == uuid do
      supplier = Catalogue.get_supplier(uuid)

      if supplier do
        {:ok, _} = Catalogue.delete_supplier(supplier)
        {:noreply, assign(socket, suppliers: Catalogue.list_suppliers(), confirm_delete: nil)}
      else
        {:noreply, assign(socket, :confirm_delete, nil)}
      end
    else
      {:noreply, assign(socket, :confirm_delete, uuid)}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

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
          <.link :if={@active_tab == :index} navigate={Paths.catalogue_new()} class="btn btn-primary btn-sm">
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

      <%!-- Tab content --%>
      <div :if={@active_tab == :index}>
        <.catalogues_table catalogues={@catalogues} confirm_delete={@confirm_delete} />
      </div>

      <div :if={@active_tab == :manufacturers}>
        <.manufacturers_table manufacturers={@manufacturers} confirm_delete={@confirm_delete} />
      </div>

      <div :if={@active_tab == :suppliers}>
        <.suppliers_table suppliers={@suppliers} confirm_delete={@confirm_delete} />
      </div>
    </div>
    """
  end

  defp catalogues_table(assigns) do
    ~H"""
    <div :if={@catalogues == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">No catalogues yet.</p>
      </div>
    </div>

    <div :if={@catalogues != []} class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Name</th>
            <th>Status</th>
            <th>Updated</th>
            <th class="text-right">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={catalogue <- @catalogues}>
            <td>
              <.link navigate={Paths.catalogue_detail(catalogue.uuid)} class="link link-hover font-medium">
                {catalogue.name}
              </.link>
            </td>
            <td>
              <span class={["badge badge-sm", status_badge_class(catalogue.status)]}>
                {catalogue.status}
              </span>
            </td>
            <td class="text-sm text-base-content/60">
              {Calendar.strftime(catalogue.updated_at, "%Y-%m-%d %H:%M")}
            </td>
            <td class="text-right">
              <.link navigate={Paths.catalogue_edit(catalogue.uuid)} class="btn btn-ghost btn-xs">
                Edit
              </.link>
              <button
                :if={@confirm_delete != catalogue.uuid}
                phx-click="delete_catalogue"
                phx-value-uuid={catalogue.uuid}
                class="btn btn-ghost btn-xs text-error"
              >
                Delete
              </button>
              <span :if={@confirm_delete == catalogue.uuid} class="inline-flex gap-1">
                <button phx-click="delete_catalogue" phx-value-uuid={catalogue.uuid} class="btn btn-error btn-xs">
                  Confirm
                </button>
                <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">
                  Cancel
                </button>
              </span>
            </td>
          </tr>
        </tbody>
      </table>
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

    <div :if={@manufacturers != []} class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Name</th>
            <th>Website</th>
            <th>Status</th>
            <th class="text-right">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={m <- @manufacturers}>
            <td class="font-medium">{m.name}</td>
            <td class="text-sm text-base-content/60">{m.website}</td>
            <td>
              <span class={["badge badge-sm", status_badge_class(m.status)]}>
                {m.status}
              </span>
            </td>
            <td class="text-right">
              <.link navigate={Paths.manufacturer_edit(m.uuid)} class="btn btn-ghost btn-xs">
                Edit
              </.link>
              <button
                :if={@confirm_delete != m.uuid}
                phx-click="delete_manufacturer"
                phx-value-uuid={m.uuid}
                class="btn btn-ghost btn-xs text-error"
              >
                Delete
              </button>
              <span :if={@confirm_delete == m.uuid} class="inline-flex gap-1">
                <button phx-click="delete_manufacturer" phx-value-uuid={m.uuid} class="btn btn-error btn-xs">
                  Confirm
                </button>
                <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">
                  Cancel
                </button>
              </span>
            </td>
          </tr>
        </tbody>
      </table>
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

    <div :if={@suppliers != []} class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Name</th>
            <th>Website</th>
            <th>Status</th>
            <th class="text-right">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={s <- @suppliers}>
            <td class="font-medium">{s.name}</td>
            <td class="text-sm text-base-content/60">{s.website}</td>
            <td>
              <span class={["badge badge-sm", status_badge_class(s.status)]}>
                {s.status}
              </span>
            </td>
            <td class="text-right">
              <.link navigate={Paths.supplier_edit(s.uuid)} class="btn btn-ghost btn-xs">
                Edit
              </.link>
              <button
                :if={@confirm_delete != s.uuid}
                phx-click="delete_supplier"
                phx-value-uuid={s.uuid}
                class="btn btn-ghost btn-xs text-error"
              >
                Delete
              </button>
              <span :if={@confirm_delete == s.uuid} class="inline-flex gap-1">
                <button phx-click="delete_supplier" phx-value-uuid={s.uuid} class="btn btn-error btn-xs">
                  Confirm
                </button>
                <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">
                  Cancel
                </button>
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp status_badge_class("active"), do: "badge-success"
  defp status_badge_class("archived"), do: "badge-warning"
  defp status_badge_class("inactive"), do: "badge-ghost"
  defp status_badge_class(_), do: "badge-ghost"
end
