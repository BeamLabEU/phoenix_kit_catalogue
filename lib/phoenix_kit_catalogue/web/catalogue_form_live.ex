defmodule PhoenixKitCatalogue.Web.CatalogueFormLive do
  @moduledoc "Create/edit form for catalogues with multilang support."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema

  @translatable_fields ["name", "description"]
  @preserve_fields %{"status" => :status, "markup_percentage" => :markup_percentage}

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {catalogue, changeset} =
      case action do
        :new ->
          cat = %CatalogueSchema{}
          {cat, Catalogue.change_catalogue(cat)}

        :edit ->
          case Catalogue.get_catalogue(params["uuid"]) do
            nil ->
              Logger.warning("Catalogue not found for edit: #{params["uuid"]}")
              {nil, nil}

            cat ->
              {cat, Catalogue.change_catalogue(cat)}
          end
      end

    if is_nil(catalogue) and action == :edit do
      {:ok,
       socket
       |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue not found."))
       |> push_navigate(to: Paths.index())}
    else
      {:ok,
       socket
       |> assign(
         page_title:
           if(action == :new,
             do: Gettext.gettext(PhoenixKitWeb.Gettext, "New Catalogue"),
             else: Gettext.gettext(PhoenixKitWeb.Gettext, "Edit %{name}", name: catalogue.name)
           ),
         action: action,
         catalogue: catalogue,
         changeset: changeset,
         confirm_delete: false
       )
       |> mount_multilang()}
    end
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"catalogue" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.catalogue
      |> Catalogue.change_catalogue(params)
      |> Map.put(:action, socket.assigns.changeset.action)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"catalogue" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    save_catalogue(socket, socket.assigns.action, params)
  end

  def handle_event("show_delete_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, true)}
  end

  def handle_event("delete_catalogue", _params, socket) do
    case Catalogue.permanently_delete_catalogue(socket.assigns.catalogue) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           Gettext.gettext(
             PhoenixKitWeb.Gettext,
             "Catalogue and all its contents permanently deleted."
           )
         )
         |> push_navigate(to: Paths.index())}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:confirm_delete, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete catalogue.")
         )}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, false)}
  end

  defp save_catalogue(socket, :new, params) do
    case Catalogue.create_catalogue(params) do
      {:ok, catalogue} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue created."))
         |> push_navigate(to: Paths.catalogue_detail(catalogue.uuid))}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_catalogue(socket, :edit, params) do
    case Catalogue.update_catalogue(socket.assigns.catalogue, params) do
      {:ok, catalogue} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue updated."))
         |> push_navigate(to: Paths.catalogue_detail(catalogue.uuid))}

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
      <.admin_page_header back={Paths.index()} title={@page_title} subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Create a new product catalogue to organize categories and items."), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Update catalogue details and settings.")} />

      <.form for={to_form(@changeset)} action="#" phx-change="validate" phx-submit="save">
        <%!-- Main content card --%>
        <div class="card bg-base-100 shadow-lg">
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            class="card-body pb-0 pt-4"
          />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="card-body pt-0 flex flex-col gap-5"
          >
            <:skeleton>
              <%!-- Name --%>
              <div class="form-control">
                <div class="label">
                  <div class="skeleton h-4 w-14"></div>
                </div>
                <div class="skeleton h-12 w-full rounded-lg"></div>
              </div>
              <%!-- Description --%>
              <div class="form-control">
                <div class="label">
                  <div class="skeleton h-4 w-24"></div>
                </div>
                <div class="skeleton h-20 w-full rounded-lg"></div>
              </div>
            </:skeleton>
            <div class="card-body pt-0 flex flex-col gap-5">
              <.translatable_field
                field_name="name"
                form_prefix="catalogue"
                changeset={@changeset}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "e.g., Kitchen Furniture")}
                required
                class="w-full"
              />

              <.translatable_field
                field_name="description"
                form_prefix="catalogue"
                changeset={@changeset}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Description")}
                type="textarea"
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Brief description of what this catalogue contains...")}
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <div class="divider my-0"></div>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Markup Percentage")}</span>
              <input type="number" name="catalogue[markup_percentage]" value={Ecto.Changeset.get_field(@changeset, :markup_percentage)} class="input input-bordered w-full transition-colors focus:input-primary" step="0.01" min="0" placeholder="e.g., 15.0" />
              <span class="label-text-alt text-base-content/50 mt-1">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Applied to all item base prices to calculate sale prices. Leave blank for no markup.")}
              </span>
            </div>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</span>
              <label class="select select-bordered w-full transition-colors focus-within:select-primary">
                <select name="catalogue[status]">
                  <option
                    value="active"
                    selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}
                  >
                    Active
                  </option>
                  <option
                    value="archived"
                    selected={Ecto.Changeset.get_field(@changeset, :status) == "archived"}
                  >
                    Archived
                  </option>
                </select>
              </label>
              <span class="label-text-alt text-base-content/50 mt-1">
                Archived catalogues are hidden from active views.
              </span>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.link navigate={Paths.index()} class="btn btn-ghost">{Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}</.link>
              <button type="submit" class="btn btn-primary phx-submit-loading:opacity-75">
                {if @action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Create Catalogue"), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Save Changes")}
              </button>
            </div>
          </div>
        </div>
      </.form>

      <%!-- Danger zone — only in edit mode --%>
      <div :if={@action == :edit} class="card bg-base-100 shadow-lg border border-error/20">
        <div class="card-body flex flex-row items-center justify-between gap-4">
          <div>
            <span class="text-sm font-semibold text-error">{Gettext.gettext(PhoenixKitWeb.Gettext, "Permanently Delete Catalogue")}</span>
            <p class="text-xs text-base-content/50">
              This will permanently delete this catalogue, all its categories, and all items within them. This cannot be undone.
            </p>
          </div>
          <button phx-click="show_delete_confirm" class="btn btn-outline btn-error btn-sm shrink-0">
            Delete Forever
          </button>
        </div>
      </div>

      <.confirm_modal
        show={@confirm_delete}
        on_confirm="delete_catalogue"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Permanently Delete Catalogue")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitWeb.Gettext, "This will permanently delete this catalogue, all its categories, and all items within them.")}]}
        confirm_text={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}
        danger={true}
      />
    </div>
    """
  end
end
