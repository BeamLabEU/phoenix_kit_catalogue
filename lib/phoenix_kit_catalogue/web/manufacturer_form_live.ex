defmodule PhoenixKitCatalogue.Web.ManufacturerFormLive do
  @moduledoc "Create/edit form for manufacturers with supplier linking."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.Textarea, only: [textarea: 1]

  import PhoenixKitCatalogue.Web.Components.CrmLinkPanel, only: [crm_link_panel: 1]
  import PhoenixKitCatalogue.Web.Helpers, only: [actor_opts: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Manufacturer

  # PhoenixKit auto-applies its admin chrome layout to external module admin
  # views via socket.private[:live_layout]. Opt out here so this view can
  # self-wrap with LayoutWrapper.app_layout and push its title/subtitle into
  # the global admin header (same pattern as /admin/media and orders/index).
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

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
       |> put_flash(
         :error,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer not found.")
       )
       |> push_navigate(to: Paths.manufacturers())}
    else
      all_suppliers = Catalogue.list_suppliers(status: "active")

      {:ok,
       socket
       |> assign(
         page_title:
           if(action == :new,
             do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Manufacturer"),
             else:
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}",
                 name: manufacturer.name
               )
           ),
         action: action,
         manufacturer: manufacturer,
         all_suppliers: all_suppliers,
         linked_supplier_uuids: MapSet.new(linked_supplier_uuids)
       )
       |> assign_crm(manufacturer)
       |> assign_changeset(changeset)}
    end
  end

  # See the twin in SupplierFormLive: the party is resolved live, never
  # cached, so a rename in CRM is visible here at once.
  defp assign_crm(socket, manufacturer) do
    available = Catalogue.crm_link_available?()

    party =
      with true <- available,
           %{crm_company_uuid: uuid} when is_binary(uuid) <- manufacturer,
           {:ok, party} <- Catalogue.resolve_manufacturer(uuid) do
        party
      else
        _ -> nil
      end

    assign(socket,
      crm_available: available,
      crm_candidates: if(available, do: Catalogue.crm_link_candidates(), else: []),
      crm_party: party
    )
  end

  defp assign_changeset(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("validate", %{"manufacturer" => params}, socket) do
    changeset =
      socket.assigns.manufacturer
      |> Catalogue.change_manufacturer(params)
      |> Map.put(:action, socket.assigns.changeset.action)

    {:noreply, assign_changeset(socket, changeset)}
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

  def handle_event("crm_link", %{"company_uuid" => ""}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       Gettext.gettext(PhoenixKitCatalogue.Gettext, "Choose a CRM company first.")
     )}
  end

  def handle_event("crm_link", %{"company_uuid" => company_uuid}, socket) do
    socket.assigns.manufacturer
    |> Catalogue.link_manufacturer_to_crm(company_uuid, actor_opts(socket))
    |> handle_crm_result(socket, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Linked to CRM."))
  end

  def handle_event("crm_unlink", _params, socket) do
    socket.assigns.manufacturer
    |> Catalogue.unlink_manufacturer_from_crm(actor_opts(socket))
    |> handle_crm_result(
      socket,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unlinked from CRM.")
    )
  end

  def handle_event("crm_refresh", _params, socket) do
    socket.assigns.manufacturer
    |> Catalogue.refresh_manufacturer_from_crm(actor_opts(socket))
    |> handle_crm_result(
      socket,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Refreshed from CRM.")
    )
  end

  defp handle_crm_result({:ok, manufacturer}, socket, message) do
    {:noreply,
     socket
     |> assign(:manufacturer, manufacturer)
     |> assign_crm(manufacturer)
     |> assign_changeset(Catalogue.change_manufacturer(manufacturer))
     |> put_flash(:info, message)}
  end

  defp handle_crm_result({:error, reason}, socket, _message) do
    {:noreply, put_flash(socket, :error, crm_error_message(reason))}
  end

  defp crm_error_message(:crm_unavailable),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "The CRM module is not available.")

  defp crm_error_message(reason) when reason in [:company_not_found, :party_not_found],
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "That CRM company no longer exists.")

  defp crm_error_message(:not_linked),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "This record is not linked to CRM.")

  defp crm_error_message(%Ecto.Changeset{} = changeset) do
    if Enum.any?(changeset.errors, fn {field, _} -> field == :crm_company_uuid end) do
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "That CRM company is already linked to another record."
      )
    else
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not save the change.")
    end
  end

  defp crm_error_message(_other),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not save the change.")

  # actor_opts/1 imported from PhoenixKitCatalogue.Web.Helpers

  defp save_manufacturer(socket, :new, params) do
    opts = actor_opts(socket)

    case Catalogue.create_manufacturer(params, opts) do
      {:ok, manufacturer} ->
        case Catalogue.sync_manufacturer_suppliers(
               manufacturer.uuid,
               MapSet.to_list(socket.assigns.linked_supplier_uuids),
               opts
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer created.")
             )
             |> push_navigate(to: Paths.manufacturers())}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(
               :warning,
               Gettext.gettext(
                 PhoenixKitCatalogue.Gettext,
                 "Manufacturer created but failed to link some suppliers."
               )
             )
             |> push_navigate(to: Paths.manufacturers())}
        end

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  defp save_manufacturer(socket, :edit, params) do
    opts = actor_opts(socket)

    case Catalogue.update_manufacturer(socket.assigns.manufacturer, params, opts) do
      {:ok, manufacturer} ->
        case Catalogue.sync_manufacturer_suppliers(
               manufacturer.uuid,
               MapSet.to_list(socket.assigns.linked_supplier_uuids),
               opts
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer updated.")
             )
             |> push_navigate(to: Paths.manufacturers())}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(
               :warning,
               Gettext.gettext(
                 PhoenixKitCatalogue.Gettext,
                 "Manufacturer updated but failed to sync supplier links."
               )
             )
             |> push_navigate(to: Paths.manufacturers())}
        end

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add a new manufacturer to your catalogue system."), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Update manufacturer details and supplier links.")}
      current_path={assigns[:url_path] || Paths.manufacturers()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col mx-auto max-w-2xl px-4 py-8 gap-6">

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body flex flex-col gap-5">
            <.input
              field={@form[:name]}
              type="text"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name *")}
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Blum, Hettich")}
              readonly={crm_linked?(@manufacturer)}
              required
            />

            <.textarea
              field={@form[:description]}
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
              rows="3"
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Brief description of this manufacturer...")}
            />

            <div class="divider my-0"></div>

            <%!-- Contact & web --%>
            <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
              <.icon name="hero-envelope" class="h-4 w-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Contact & Web")}
            </h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input
                field={@form[:website]}
                type="url"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website")}
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "https://...")}
                readonly={crm_linked?(@manufacturer)}
              />
              <.input
                field={@form[:contact_info]}
                type="text"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Contact Info")}
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Email or phone")}
                readonly={crm_linked?(@manufacturer)}
              />
            </div>

            <.input
              field={@form[:logo_url]}
              type="url"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Logo URL")}
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "https://...")}
            />

            <.textarea
              field={@form[:notes]}
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Notes")}
              rows="2"
              class="min-h-[5rem]"
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Internal notes about this manufacturer...")}
            />

            <div class="divider my-0"></div>

            <div class="fieldset">
              <.select
                field={@form[:status]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                class="transition-colors focus-within:select-primary"
                options={[
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active"), "active"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive"), "inactive"}
                ]}
              />
              <span class="fieldset-label text-base-content/50 mt-1">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive manufacturers won't appear in item dropdowns.")}
              </span>
            </div>

            <%!-- Supplier links --%>
            <div :if={@all_suppliers != []} class="flex flex-col gap-4">
              <div class="divider my-0"></div>

              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <.icon name="hero-link" class="h-4 w-4" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Linked Suppliers")}
              </h2>
              <p class="text-sm text-base-content/50 -mt-2">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Click to toggle supplier associations.")}
              </p>

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
                  <.icon
                    :if={MapSet.member?(@linked_supplier_uuids, supplier.uuid)}
                    name="hero-check"
                    class="h-3.5 w-3.5"
                  />
                  {supplier.name}
                </label>
              </div>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.button navigate={Paths.manufacturers()} variant="ghost">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
              </.button>
              <.button
                type="submit"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
              >
                {if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create Manufacturer"), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save Changes")}
              </.button>
            </div>
          </div>
        </div>
      </.form>

      <%!-- Outside the form above on purpose: the picker is itself a form,
            and nesting one form inside another is invalid HTML. --%>
      <div :if={@crm_available and @action == :edit} class="card bg-base-100 shadow-lg">
        <div class="card-body">
          <.crm_link_panel
            record={@manufacturer}
            kind={:manufacturer}
            available={@crm_available}
            candidates={@crm_candidates}
            party={@crm_party}
          />
        </div>
      </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp crm_linked?(%{crm_company_uuid: uuid}) when is_binary(uuid), do: true
  defp crm_linked?(_), do: false
end
