defmodule PhoenixKitCatalogue.Web.ManufacturerFormLive do
  @moduledoc "Create/edit form for manufacturers with supplier linking."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Manufacturer

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {manufacturer, changeset, linked_supplier_uuids} =
      case action do
        :new ->
          m = %Manufacturer{}
          {m, Catalogue.change_manufacturer(m), []}

        :edit ->
          case Catalogue.get_manufacturer(params["uuid"]) do
            nil ->
              Logger.warning("Manufacturer not found for edit: #{params["uuid"]}")
              {nil, nil, []}

            m ->
              linked = Catalogue.linked_supplier_uuids(m.uuid)
              {m, Catalogue.change_manufacturer(m), linked}
          end
      end

    if is_nil(manufacturer) and action == :edit do
      {:ok,
       socket
       |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Manufacturer not found."))
       |> push_navigate(to: Paths.manufacturers())}
    else
      all_suppliers = Catalogue.list_suppliers(status: "active")

      {:ok,
       assign(socket,
         page_title:
           if(action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "New Manufacturer"), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Edit %{name}", name: manufacturer.name)),
         action: action,
         manufacturer: manufacturer,
         changeset: changeset,
         all_suppliers: all_suppliers,
         linked_supplier_uuids: MapSet.new(linked_supplier_uuids)
       )}
    end
  end

  @impl true
  def handle_event("validate", %{"manufacturer" => params}, socket) do
    changeset =
      socket.assigns.manufacturer
      |> Catalogue.change_manufacturer(params)
      |> Map.put(:action, socket.assigns.changeset.action)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("toggle_supplier", %{"uuid" => uuid}, socket) do
    linked = socket.assigns.linked_supplier_uuids

    linked =
      if MapSet.member?(linked, uuid),
        do: MapSet.delete(linked, uuid),
        else: MapSet.put(linked, uuid)

    {:noreply, assign(socket, :linked_supplier_uuids, linked)}
  end

  def handle_event("save", %{"manufacturer" => params}, socket) do
    save_manufacturer(socket, socket.assigns.action, params)
  end

  defp save_manufacturer(socket, :new, params) do
    case Catalogue.create_manufacturer(params) do
      {:ok, manufacturer} ->
        case Catalogue.sync_manufacturer_suppliers(
               manufacturer.uuid,
               MapSet.to_list(socket.assigns.linked_supplier_uuids)
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Manufacturer created."))
             |> push_navigate(to: Paths.manufacturers())}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(:warning, Gettext.gettext(PhoenixKitWeb.Gettext, "Manufacturer created but failed to link some suppliers."))
             |> push_navigate(to: Paths.manufacturers())}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_manufacturer(socket, :edit, params) do
    case Catalogue.update_manufacturer(socket.assigns.manufacturer, params) do
      {:ok, manufacturer} ->
        case Catalogue.sync_manufacturer_suppliers(
               manufacturer.uuid,
               MapSet.to_list(socket.assigns.linked_supplier_uuids)
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Manufacturer updated."))
             |> push_navigate(to: Paths.manufacturers())}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(:warning, Gettext.gettext(PhoenixKitWeb.Gettext, "Manufacturer updated but failed to sync supplier links."))
             |> push_navigate(to: Paths.manufacturers())}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-2xl px-4 py-8 gap-6">
      <%!-- Header --%>
      <.admin_page_header
        back={Paths.manufacturers()}
        title={@page_title}
        subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Add a new manufacturer to your catalogue system."), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Update manufacturer details and supplier links.")}
      />

      <.form for={to_form(@changeset)} action="#" phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body flex flex-col gap-5">
            <div class="form-control">
              <span class="label-text font-semibold mb-2">Name *</span>
              <input
                type="text"
                name="manufacturer[name]"
                value={Ecto.Changeset.get_field(@changeset, :name) || ""}
                class="input input-bordered w-full transition-colors focus:input-primary"
                placeholder="e.g., Blum, Hettich"
              />
              <p :for={msg <- changeset_errors(@changeset, :name)} class="text-error text-sm mt-1">
                {msg}
              </p>
            </div>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">Description</span>
              <textarea
                name="manufacturer[description]"
                class="textarea textarea-bordered w-full transition-colors focus:textarea-primary"
                rows="3"
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Brief description of this manufacturer...")}
              >{Ecto.Changeset.get_field(@changeset, :description) || ""}</textarea>
            </div>

            <div class="divider my-0"></div>

            <%!-- Contact & web --%>
            <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
                />
              </svg>
              Contact & Web
            </h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-control">
                <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Website")}</span>
                <input
                  type="url"
                  name="manufacturer[website]"
                  value={Ecto.Changeset.get_field(@changeset, :website) || ""}
                  class="input input-bordered w-full transition-colors focus:input-primary"
                  placeholder="https://..."
                />
              </div>
              <div class="form-control">
                <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Contact Info")}</span>
                <input
                  type="text"
                  name="manufacturer[contact_info]"
                  value={Ecto.Changeset.get_field(@changeset, :contact_info) || ""}
                  class="input input-bordered w-full transition-colors focus:input-primary"
                  placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Email or phone")}
                />
              </div>
            </div>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Logo URL")}</span>
              <input
                type="url"
                name="manufacturer[logo_url]"
                value={Ecto.Changeset.get_field(@changeset, :logo_url) || ""}
                class="input input-bordered w-full transition-colors focus:input-primary"
                placeholder="https://..."
              />
            </div>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Notes")}</span>
              <textarea
                name="manufacturer[notes]"
                class="textarea textarea-bordered w-full min-h-[5rem] transition-colors focus:textarea-primary"
                rows="2"
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Internal notes about this manufacturer...")}
              >{Ecto.Changeset.get_field(@changeset, :notes) || ""}</textarea>
            </div>

            <div class="divider my-0"></div>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</span>
              <label class="select select-bordered w-full transition-colors focus-within:select-primary">
                <select name="manufacturer[status]">
                  <option
                    value="active"
                    selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}
                  >
                    Active
                  </option>
                  <option
                    value="inactive"
                    selected={Ecto.Changeset.get_field(@changeset, :status) == "inactive"}
                  >
                    Inactive
                  </option>
                </select>
              </label>
              <span class="label-text-alt text-base-content/50 mt-1">
                Inactive manufacturers won't appear in item dropdowns.
              </span>
            </div>

            <%!-- Supplier links --%>
            <div :if={@all_suppliers != []} class="flex flex-col gap-4">
              <div class="divider my-0"></div>

              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-4 w-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
                  />
                </svg>
                Linked Suppliers
              </h2>
              <p class="text-sm text-base-content/50 -mt-2">Click to toggle supplier associations.</p>

              <div class="flex flex-wrap gap-2">
                <label
                  :for={supplier <- @all_suppliers}
                  class={[
                    "badge badge-lg cursor-pointer gap-1.5 select-none transition-colors",
                    if(MapSet.member?(@linked_supplier_uuids, supplier.uuid),
                      do: "badge-primary",
                      else: "badge-ghost hover:badge-outline"
                    )
                  ]}
                  phx-click="toggle_supplier"
                  phx-value-uuid={supplier.uuid}
                >
                  <svg
                    :if={MapSet.member?(@linked_supplier_uuids, supplier.uuid)}
                    xmlns="http://www.w3.org/2000/svg"
                    class="h-3.5 w-3.5"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M5 13l4 4L19 7"
                    />
                  </svg>
                  {supplier.name}
                </label>
              </div>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.link navigate={Paths.manufacturers()} class="btn btn-ghost">{Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}</.link>
              <button type="submit" class="btn btn-primary phx-submit-loading:opacity-75">
                {if @action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Create Manufacturer"), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Save Changes")}
              </button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp changeset_errors(%Ecto.Changeset{action: action, errors: errors}, field)
       when not is_nil(action) do
    errors
    |> Keyword.get_values(field)
    |> Enum.map(&translate_error/1)
  end

  defp changeset_errors(_changeset, _field), do: []

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
