defmodule PhoenixKitCatalogue.Web.ManufacturerFormLive do
  @moduledoc "Create/edit form for manufacturers with multilang support and supplier linking."

  use Phoenix.LiveView

  alias PhoenixKit.Modules.Entities.Multilang
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
          m = Catalogue.get_manufacturer!(params["uuid"])
          linked = Catalogue.linked_supplier_uuids(m.uuid)
          {m, Catalogue.change_manufacturer(m), linked}
      end

    all_suppliers = Catalogue.list_suppliers(status: "active")
    multilang_enabled = multilang_enabled?()
    primary_lang = if multilang_enabled, do: Multilang.primary_language(), else: nil

    {:ok,
     assign(socket,
       page_title: if(action == :new, do: "New Manufacturer", else: "Edit #{manufacturer.name}"),
       action: action,
       manufacturer: manufacturer,
       changeset: changeset,
       form: to_form(changeset),
       all_suppliers: all_suppliers,
       linked_supplier_uuids: MapSet.new(linked_supplier_uuids),
       multilang_enabled: multilang_enabled,
       language_tabs: if(multilang_enabled, do: Multilang.build_language_tabs(), else: []),
       current_lang: primary_lang,
       lang_data: manufacturer.data || %{}
     )}
  end

  @impl true
  def handle_event("validate", %{"manufacturer" => params}, socket) do
    changeset =
      socket.assigns.manufacturer
      |> Catalogue.change_manufacturer(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
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
    params = maybe_merge_multilang(params, socket.assigns)
    save_manufacturer(socket, socket.assigns.action, params)
  end

  def handle_event("switch_lang", %{"lang" => lang_code}, socket) do
    socket = save_current_lang_to_data(socket)
    lang_data = Multilang.get_language_data(socket.assigns.lang_data, lang_code)

    {:noreply,
     assign(socket,
       current_lang: lang_code,
       form: to_form(apply_lang_to_changeset(socket, lang_data))
     )}
  end

  defp save_manufacturer(socket, :new, params) do
    case Catalogue.create_manufacturer(params) do
      {:ok, manufacturer} ->
        sync_suppliers(manufacturer.uuid, socket.assigns.linked_supplier_uuids)

        {:noreply,
         socket
         |> put_flash(:info, "Manufacturer created.")
         |> push_navigate(to: Paths.manufacturers())}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end

  defp save_manufacturer(socket, :edit, params) do
    case Catalogue.update_manufacturer(socket.assigns.manufacturer, params) do
      {:ok, manufacturer} ->
        sync_suppliers(manufacturer.uuid, socket.assigns.linked_supplier_uuids)

        {:noreply,
         socket
         |> put_flash(:info, "Manufacturer updated.")
         |> push_navigate(to: Paths.manufacturers())}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end

  defp sync_suppliers(manufacturer_uuid, linked_set) do
    Catalogue.sync_manufacturer_suppliers(manufacturer_uuid, MapSet.to_list(linked_set))
  end

  defp maybe_merge_multilang(params, %{multilang_enabled: false}), do: params

  defp maybe_merge_multilang(params, %{
         multilang_enabled: true,
         current_lang: lang,
         lang_data: data
       }) do
    lang_fields = %{
      "_name" => params["name"] || "",
      "_description" => params["description"] || ""
    }

    new_data = Multilang.put_language_data(data, lang, lang_fields)
    Map.put(params, "data", new_data)
  end

  defp save_current_lang_to_data(socket) do
    if socket.assigns.multilang_enabled do
      form_params = socket.assigns.form.params || %{}

      lang_fields = %{
        "_name" => form_params["name"] || "",
        "_description" => form_params["description"] || ""
      }

      new_data =
        Multilang.put_language_data(
          socket.assigns.lang_data,
          socket.assigns.current_lang,
          lang_fields
        )

      assign(socket, :lang_data, new_data)
    else
      socket
    end
  end

  defp apply_lang_to_changeset(socket, lang_data) do
    name = Map.get(lang_data, "_name", socket.assigns.manufacturer.name || "")

    description =
      Map.get(lang_data, "_description", socket.assigns.manufacturer.description || "")

    socket.assigns.manufacturer
    |> Catalogue.change_manufacturer(%{"name" => name, "description" => description})
  end

  defp multilang_enabled? do
    Code.ensure_loaded?(Multilang) and Multilang.enabled?()
  rescue
    _ -> false
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-2xl px-4 py-6 gap-6">
      <div class="flex items-center gap-2">
        <.link navigate={Paths.manufacturers()} class="btn btn-ghost btn-sm btn-square">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </.link>
        <h1 class="text-2xl font-bold">{@page_title}</h1>
      </div>

      <%!-- Language tabs --%>
      <div :if={@multilang_enabled} role="tablist" class="tabs tabs-bordered">
        <button
          :for={tab <- @language_tabs}
          phx-click="switch_lang"
          phx-value-lang={tab.code}
          class={["tab", @current_lang == tab.code && "tab-active"]}
        >
          {tab.name}
          <span :if={tab.is_primary} class="badge badge-xs badge-primary ml-1">primary</span>
        </button>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <.form for={@form} phx-change="validate" phx-submit="save" class="flex flex-col gap-4">
            <div class="form-control">
              <label class="label"><span class="label-text">Name</span></label>
              <input
                type="text"
                name="manufacturer[name]"
                value={@form[:name].value}
                class={["input input-bordered", @form[:name].errors != [] && "input-error"]}
              />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Description</span></label>
              <textarea name="manufacturer[description]" class="textarea textarea-bordered" rows="3">{@form[:description].value}</textarea>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-control">
                <label class="label"><span class="label-text">Website</span></label>
                <input type="text" name="manufacturer[website]" value={@form[:website].value} class="input input-bordered" />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Contact Info</span></label>
                <input type="text" name="manufacturer[contact_info]" value={@form[:contact_info].value} class="input input-bordered" />
              </div>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Logo URL</span></label>
              <input type="text" name="manufacturer[logo_url]" value={@form[:logo_url].value} class="input input-bordered" />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Notes</span></label>
              <textarea name="manufacturer[notes]" class="textarea textarea-bordered" rows="2">{@form[:notes].value}</textarea>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Status</span></label>
              <select name="manufacturer[status]" class="select select-bordered">
                <option value="active" selected={@form[:status].value == "active"}>Active</option>
                <option value="inactive" selected={@form[:status].value == "inactive"}>Inactive</option>
              </select>
            </div>

            <%!-- Supplier links --%>
            <div :if={@all_suppliers != []} class="form-control">
              <label class="label"><span class="label-text">Suppliers</span></label>
              <div class="flex flex-wrap gap-2">
                <label
                  :for={supplier <- @all_suppliers}
                  class={[
                    "badge badge-lg cursor-pointer gap-1 select-none",
                    if(MapSet.member?(@linked_supplier_uuids, supplier.uuid), do: "badge-primary", else: "badge-ghost")
                  ]}
                  phx-click="toggle_supplier"
                  phx-value-uuid={supplier.uuid}
                >
                  {supplier.name}
                </label>
              </div>
            </div>

            <div class="flex justify-end gap-2 mt-4">
              <.link navigate={Paths.manufacturers()} class="btn btn-ghost">Cancel</.link>
              <button type="submit" class="btn btn-primary">
                {if @action == :new, do: "Create Manufacturer", else: "Save Changes"}
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
