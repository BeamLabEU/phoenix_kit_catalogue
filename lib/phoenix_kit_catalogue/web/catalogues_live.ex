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
       deleted_catalogue_count: 0
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

  def handle_event("permanently_delete_catalogue", %{"uuid" => uuid}, socket) do
    if socket.assigns.confirm_delete == {:permanent, uuid} do
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
    else
      {:noreply, assign(socket, :confirm_delete, {:permanent, uuid})}
    end
  end

  def handle_event("delete_manufacturer", %{"uuid" => uuid}, socket) do
    if socket.assigns.confirm_delete == uuid do
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
    else
      {:noreply, assign(socket, :confirm_delete, uuid)}
    end
  end

  def handle_event("delete_supplier", %{"uuid" => uuid}, socket) do
    if socket.assigns.confirm_delete == uuid do
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
    else
      {:noreply, assign(socket, :confirm_delete, uuid)}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
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

      <%!-- Catalogue tab content --%>
      <div :if={@active_tab == :index} class="flex flex-col gap-4">
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

        <.catalogues_table catalogues={@catalogues} confirm_delete={@confirm_delete} view_mode={@catalogue_view_mode} />
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
        <p class="text-base-content/60">
          {if @view_mode == "deleted", do: "No deleted catalogues.", else: "No catalogues yet."}
        </p>
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
              <.link :if={@view_mode == "active"} navigate={Paths.catalogue_detail(catalogue.uuid)} class="link link-hover font-medium">
                {catalogue.name}
              </.link>
              <span :if={@view_mode == "deleted"} class="font-medium text-base-content/50">{catalogue.name}</span>
            </td>
            <td>
              <span class={["badge badge-sm", status_badge_class(catalogue.status)]}>
                {catalogue.status}
              </span>
            </td>
            <td class="text-sm text-base-content/60">
              {Calendar.strftime(catalogue.updated_at, "%Y-%m-%d %H:%M")}
            </td>
            <%!-- Active mode actions --%>
            <td :if={@view_mode == "active"} class="text-right">
              <.link navigate={Paths.catalogue_detail(catalogue.uuid)} class="btn btn-ghost btn-xs">
                View
              </.link>
              <.link navigate={Paths.catalogue_edit(catalogue.uuid)} class="btn btn-ghost btn-xs">
                Edit
              </.link>
              <button phx-click="trash_catalogue" phx-value-uuid={catalogue.uuid} class="btn btn-ghost btn-xs text-error">
                Delete
              </button>
            </td>
            <%!-- Deleted mode actions --%>
            <td :if={@view_mode == "deleted"} class="text-right">
              <button
                phx-click="restore_catalogue"
                phx-value-uuid={catalogue.uuid}
                class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-success/30 bg-success/10 hover:bg-success/20 text-success text-xs font-medium transition-colors cursor-pointer"
              >
                Restore
              </button>
              <button
                :if={@confirm_delete != {:permanent, catalogue.uuid}}
                phx-click="permanently_delete_catalogue"
                phx-value-uuid={catalogue.uuid}
                class="btn btn-ghost btn-xs text-error"
              >
                Delete Forever
              </button>
              <span :if={@confirm_delete == {:permanent, catalogue.uuid}} class="inline-flex gap-1">
                <button phx-click="permanently_delete_catalogue" phx-value-uuid={catalogue.uuid} class="btn btn-error btn-xs">
                  Confirm
                </button>
                <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">Cancel</button>
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
  defp status_badge_class("deleted"), do: "badge-error"
  defp status_badge_class(_), do: "badge-ghost"
end
