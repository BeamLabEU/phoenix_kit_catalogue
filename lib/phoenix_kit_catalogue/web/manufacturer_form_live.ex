defmodule PhoenixKitCatalogue.Web.ManufacturerFormLive do
  @moduledoc "Create/edit form for manufacturers with multilang support and supplier linking."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Manufacturer

  @translatable_fields ["name", "description"]
  @preserve_fields %{
    "status" => :status,
    "website" => :website,
    "contact_info" => :contact_info,
    "logo_url" => :logo_url,
    "notes" => :notes
  }

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
      {:ok, socket |> put_flash(:error, "Manufacturer not found.") |> push_navigate(to: Paths.manufacturers())}
    else
      all_suppliers = Catalogue.list_suppliers(status: "active")

      {:ok,
       socket
       |> assign(
         page_title: if(action == :new, do: "New Manufacturer", else: "Edit #{manufacturer.name}"),
         action: action,
         manufacturer: manufacturer,
         changeset: changeset,
       all_suppliers: all_suppliers,
       linked_supplier_uuids: MapSet.new(linked_supplier_uuids)
     )
     |> mount_multilang()}
    end
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"manufacturer" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.manufacturer
      |> Catalogue.change_manufacturer(params)
      |> Map.put(:action, :validate)

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
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    save_manufacturer(socket, socket.assigns.action, params)
  end

  defp save_manufacturer(socket, :new, params) do
    case Catalogue.create_manufacturer(params) do
      {:ok, manufacturer} ->
        Catalogue.sync_manufacturer_suppliers(
          manufacturer.uuid,
          MapSet.to_list(socket.assigns.linked_supplier_uuids)
        )

        {:noreply,
         socket
         |> put_flash(:info, "Manufacturer created.")
         |> push_navigate(to: Paths.manufacturers())}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_manufacturer(socket, :edit, params) do
    case Catalogue.update_manufacturer(socket.assigns.manufacturer, params) do
      {:ok, manufacturer} ->
        Catalogue.sync_manufacturer_suppliers(
          manufacturer.uuid,
          MapSet.to_list(socket.assigns.linked_supplier_uuids)
        )

        {:noreply,
         socket
         |> put_flash(:info, "Manufacturer updated.")
         |> push_navigate(to: Paths.manufacturers())}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :lang_data,
        get_lang_data(assigns.changeset, assigns.current_lang, assigns.multilang_enabled)
      )

    ~H"""
    <div class="flex flex-col mx-auto max-w-2xl px-4 py-8 gap-6">
      <%!-- Header --%>
      <div class="flex items-center gap-3">
        <.link navigate={Paths.manufacturers()} class="btn btn-ghost btn-sm btn-square">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </.link>
        <div>
          <h1 class="text-2xl font-bold">{@page_title}</h1>
          <p class="text-sm text-base-content/60 mt-0.5">
            {if @action == :new, do: "Add a new manufacturer to your catalogue system.", else: "Update manufacturer details and supplier links."}
          </p>
        </div>
      </div>

      <.form for={to_form(@changeset)} phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-lg">
          <.multilang_tabs multilang_enabled={@multilang_enabled} language_tabs={@language_tabs} current_lang={@current_lang} />

          <.multilang_fields_wrapper multilang_enabled={@multilang_enabled} current_lang={@current_lang} skeleton_class="card-body flex flex-col gap-5">
            <:skeleton>
              <%!-- Name --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-20"></div>
                <div class="skeleton h-12 w-full"></div>
              </div>
              <%!-- Description --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-28"></div>
                <div class="skeleton h-24 w-full"></div>
              </div>
              <div class="divider my-0"></div>
              <%!-- Contact & Web header --%>
              <div class="skeleton h-5 w-32"></div>
              <%!-- Website + Contact grid --%>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="space-y-2">
                  <div class="skeleton h-4 w-20"></div>
                  <div class="skeleton h-12 w-full"></div>
                </div>
                <div class="space-y-2">
                  <div class="skeleton h-4 w-24"></div>
                  <div class="skeleton h-12 w-full"></div>
                </div>
              </div>
              <%!-- Logo URL --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-20"></div>
                <div class="skeleton h-12 w-full"></div>
              </div>
              <%!-- Notes --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-16"></div>
                <div class="skeleton h-20 w-full"></div>
              </div>
              <div class="divider my-0"></div>
              <%!-- Status --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-16"></div>
                <div class="skeleton h-12 w-full"></div>
              </div>
              <div class="divider my-0"></div>
              <%!-- Buttons --%>
              <div class="flex justify-end gap-3">
                <div class="skeleton h-12 w-20"></div>
                <div class="skeleton h-12 w-40"></div>
              </div>
            </:skeleton>
            <div class="card-body flex flex-col gap-5">
              <.translatable_field
                field_name="name" form_prefix="manufacturer" changeset={@changeset}
                schema_field={:name} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label="Name" placeholder="e.g., Blum, Hettich" required
                class="w-full"
              />

              <.translatable_field
                field_name="description" form_prefix="manufacturer" changeset={@changeset}
                schema_field={:description} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label="Description" type="textarea"
                placeholder="Brief description of this manufacturer..."
                class="w-full"
              />

              <div class="divider my-0"></div>

              <%!-- Contact & web --%>
              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
                </svg>
                Contact & Web
              </h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <span class="label-text font-semibold mb-2">Website</span>
                  <input type="url" name="manufacturer[website]" value={Ecto.Changeset.get_field(@changeset, :website) || ""} class="input input-bordered w-full transition-colors focus:input-primary" placeholder="https://..." />
                </div>
                <div class="form-control">
                  <span class="label-text font-semibold mb-2">Contact Info</span>
                  <input type="text" name="manufacturer[contact_info]" value={Ecto.Changeset.get_field(@changeset, :contact_info) || ""} class="input input-bordered w-full transition-colors focus:input-primary" placeholder="Email or phone" />
                </div>
              </div>

              <div class="form-control">
                <span class="label-text font-semibold mb-2">Logo URL</span>
                <input type="url" name="manufacturer[logo_url]" value={Ecto.Changeset.get_field(@changeset, :logo_url) || ""} class="input input-bordered w-full transition-colors focus:input-primary" placeholder="https://..." />
              </div>

              <div class="form-control">
                <span class="label-text font-semibold mb-2">Notes</span>
                <textarea name="manufacturer[notes]" class="textarea textarea-bordered w-full min-h-[5rem] transition-colors focus:textarea-primary" rows="2" placeholder="Internal notes about this manufacturer...">{Ecto.Changeset.get_field(@changeset, :notes) || ""}</textarea>
              </div>

              <div class="divider my-0"></div>

              <div class="form-control">
                <span class="label-text font-semibold mb-2">Status</span>
                <select name="manufacturer[status]" class="select select-bordered w-full transition-colors focus:select-primary">
                  <option value="active" selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}>Active</option>
                  <option value="inactive" selected={Ecto.Changeset.get_field(@changeset, :status) == "inactive"}>Inactive</option>
                </select>
                <span class="label-text-alt text-base-content/50 mt-1">Inactive manufacturers won't appear in item dropdowns.</span>
              </div>

              <%!-- Supplier links --%>
              <div :if={@all_suppliers != []} class="flex flex-col gap-4">
                <div class="divider my-0"></div>

                <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1" />
                  </svg>
                  Linked Suppliers
                </h2>
                <p class="text-sm text-base-content/50 -mt-2">Click to toggle supplier associations.</p>

                <div class="flex flex-wrap gap-2">
                  <label
                    :for={supplier <- @all_suppliers}
                    class={[
                      "badge badge-lg cursor-pointer gap-1.5 select-none transition-colors",
                      if(MapSet.member?(@linked_supplier_uuids, supplier.uuid), do: "badge-primary", else: "badge-ghost hover:badge-outline")
                    ]}
                    phx-click="toggle_supplier"
                    phx-value-uuid={supplier.uuid}
                  >
                    <svg :if={MapSet.member?(@linked_supplier_uuids, supplier.uuid)} xmlns="http://www.w3.org/2000/svg" class="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                    </svg>
                    {supplier.name}
                  </label>
                </div>
              </div>

              <%!-- Actions --%>
              <div class="divider my-0"></div>

              <div class="flex justify-end gap-3">
                <.link navigate={Paths.manufacturers()} class="btn btn-ghost">Cancel</.link>
                <button type="submit" class="btn btn-primary phx-submit-loading:opacity-75">{if @action == :new, do: "Create Manufacturer", else: "Save Changes"}</button>
              </div>
            </div>
          </.multilang_fields_wrapper>
        </div>
      </.form>
    </div>
    """
  end
end
