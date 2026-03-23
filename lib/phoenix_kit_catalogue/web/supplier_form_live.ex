defmodule PhoenixKitCatalogue.Web.SupplierFormLive do
  @moduledoc "Create/edit form for suppliers with multilang support and manufacturer linking."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Supplier

  @translatable_fields ["name", "description"]
  @preserve_fields %{
    "status" => :status,
    "website" => :website,
    "contact_info" => :contact_info,
    "notes" => :notes
  }

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {supplier, changeset, linked_manufacturer_uuids} =
      case action do
        :new ->
          s = %Supplier{}
          {s, Catalogue.change_supplier(s), []}

        :edit ->
          case Catalogue.get_supplier(params["uuid"]) do
            nil ->
              Logger.warning("Supplier not found for edit: #{params["uuid"]}")
              {nil, nil, []}

            s ->
              linked = Catalogue.linked_manufacturer_uuids(s.uuid)
              {s, Catalogue.change_supplier(s), linked}
          end
      end

    if is_nil(supplier) and action == :edit do
      {:ok, socket |> put_flash(:error, "Supplier not found.") |> push_navigate(to: Paths.suppliers())}
    else
      all_manufacturers = Catalogue.list_manufacturers(status: "active")

      {:ok,
       socket
       |> assign(
         page_title: if(action == :new, do: "New Supplier", else: "Edit #{supplier.name}"),
         action: action,
         supplier: supplier,
         changeset: changeset,
         all_manufacturers: all_manufacturers,
         linked_manufacturer_uuids: MapSet.new(linked_manufacturer_uuids)
       )
       |> mount_multilang()}
    end
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"supplier" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.supplier
      |> Catalogue.change_supplier(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("toggle_manufacturer", %{"uuid" => uuid}, socket) do
    linked = socket.assigns.linked_manufacturer_uuids

    linked =
      if MapSet.member?(linked, uuid),
        do: MapSet.delete(linked, uuid),
        else: MapSet.put(linked, uuid)

    {:noreply, assign(socket, :linked_manufacturer_uuids, linked)}
  end

  def handle_event("save", %{"supplier" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    save_supplier(socket, socket.assigns.action, params)
  end

  defp save_supplier(socket, :new, params) do
    case Catalogue.create_supplier(params) do
      {:ok, supplier} ->
        Catalogue.sync_supplier_manufacturers(
          supplier.uuid,
          MapSet.to_list(socket.assigns.linked_manufacturer_uuids)
        )

        {:noreply,
         socket |> put_flash(:info, "Supplier created.") |> push_navigate(to: Paths.suppliers())}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_supplier(socket, :edit, params) do
    case Catalogue.update_supplier(socket.assigns.supplier, params) do
      {:ok, supplier} ->
        Catalogue.sync_supplier_manufacturers(
          supplier.uuid,
          MapSet.to_list(socket.assigns.linked_manufacturer_uuids)
        )

        {:noreply,
         socket |> put_flash(:info, "Supplier updated.") |> push_navigate(to: Paths.suppliers())}

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
        <.link navigate={Paths.suppliers()} class="btn btn-ghost btn-sm btn-square">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </.link>
        <div>
          <h1 class="text-2xl font-bold">{@page_title}</h1>
          <p class="text-sm text-base-content/60 mt-0.5">
            {if @action == :new, do: "Add a new supplier to your catalogue system.", else: "Update supplier details and manufacturer links."}
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
                <div class="skeleton h-12 w-36"></div>
              </div>
            </:skeleton>
            <div class="card-body flex flex-col gap-5">
              <.translatable_field
                field_name="name" form_prefix="supplier" changeset={@changeset}
                schema_field={:name} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label="Name" placeholder="e.g., Regional Distributors Inc." required
                class="w-full"
              />

              <.translatable_field
                field_name="description" form_prefix="supplier" changeset={@changeset}
                schema_field={:description} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label="Description" type="textarea"
                placeholder="Brief description of this supplier..."
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
                  <input type="url" name="supplier[website]" value={Ecto.Changeset.get_field(@changeset, :website) || ""} class="input input-bordered w-full transition-colors focus:input-primary" placeholder="https://..." />
                </div>
                <div class="form-control">
                  <span class="label-text font-semibold mb-2">Contact Info</span>
                  <input type="text" name="supplier[contact_info]" value={Ecto.Changeset.get_field(@changeset, :contact_info) || ""} class="input input-bordered w-full transition-colors focus:input-primary" placeholder="Email or phone" />
                </div>
              </div>

              <div class="form-control">
                <span class="label-text font-semibold mb-2">Notes</span>
                <textarea name="supplier[notes]" class="textarea textarea-bordered w-full min-h-[5rem] transition-colors focus:textarea-primary" rows="2" placeholder="Internal notes about this supplier...">{Ecto.Changeset.get_field(@changeset, :notes) || ""}</textarea>
              </div>

              <div class="divider my-0"></div>

              <div class="form-control">
                <span class="label-text font-semibold mb-2">Status</span>
                <select name="supplier[status]" class="select select-bordered w-full transition-colors focus:select-primary">
                  <option value="active" selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}>Active</option>
                  <option value="inactive" selected={Ecto.Changeset.get_field(@changeset, :status) == "inactive"}>Inactive</option>
                </select>
                <span class="label-text-alt text-base-content/50 mt-1">Inactive suppliers won't appear in manufacturer linking.</span>
              </div>

              <%!-- Manufacturer links --%>
              <div :if={@all_manufacturers != []} class="flex flex-col gap-4">
                <div class="divider my-0"></div>

                <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1" />
                  </svg>
                  Linked Manufacturers
                </h2>
                <p class="text-sm text-base-content/50 -mt-2">Click to toggle manufacturer associations.</p>

                <div class="flex flex-wrap gap-2">
                  <label
                    :for={m <- @all_manufacturers}
                    class={[
                      "badge badge-lg cursor-pointer gap-1.5 select-none transition-colors",
                      if(MapSet.member?(@linked_manufacturer_uuids, m.uuid), do: "badge-primary", else: "badge-ghost hover:badge-outline")
                    ]}
                    phx-click="toggle_manufacturer"
                    phx-value-uuid={m.uuid}
                  >
                    <svg :if={MapSet.member?(@linked_manufacturer_uuids, m.uuid)} xmlns="http://www.w3.org/2000/svg" class="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                    </svg>
                    {m.name}
                  </label>
                </div>
              </div>

              <%!-- Actions --%>
              <div class="divider my-0"></div>

              <div class="flex justify-end gap-3">
                <.link navigate={Paths.suppliers()} class="btn btn-ghost">Cancel</.link>
                <button type="submit" class="btn btn-primary phx-submit-loading:opacity-75">{if @action == :new, do: "Create Supplier", else: "Save Changes"}</button>
              </div>
            </div>
          </.multilang_fields_wrapper>
        </div>
      </.form>
    </div>
    """
  end
end
