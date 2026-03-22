defmodule PhoenixKitCatalogue.Web.CatalogueFormLive do
  @moduledoc "Create/edit form for catalogues with multilang support."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema

  @translatable_fields ["name", "description"]
  @preserve_fields %{"status" => :status}

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
      {:ok, socket |> put_flash(:error, "Catalogue not found.") |> push_navigate(to: Paths.index())}
    else
      {:ok,
       socket
       |> assign(
         page_title: if(action == :new, do: "New Catalogue", else: "Edit #{catalogue.name}"),
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
      |> Map.put(:action, :validate)

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

  def handle_event("delete_catalogue", _params, socket) do
    if socket.assigns.confirm_delete do
      case Catalogue.permanently_delete_catalogue(socket.assigns.catalogue) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Catalogue and all its contents permanently deleted.")
           |> push_navigate(to: Paths.index())}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:confirm_delete, false)
           |> put_flash(:error, "Failed to delete catalogue.")}
      end
    else
      {:noreply, assign(socket, :confirm_delete, true)}
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
         |> put_flash(:info, "Catalogue created.")
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
         |> put_flash(:info, "Catalogue updated.")
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
      <div class="flex items-center gap-3">
        <.link navigate={Paths.index()} class="btn btn-ghost btn-sm btn-square">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </.link>
        <div>
          <h1 class="text-2xl font-bold">{@page_title}</h1>
          <p class="text-sm text-base-content/60 mt-0.5">
            {if @action == :new, do: "Create a new product catalogue to organize categories and items.", else: "Update catalogue details and settings."}
          </p>
        </div>
      </div>

      <.form for={to_form(@changeset)} phx-change="validate" phx-submit="save">
        <%!-- Main content card --%>
        <div class="card bg-base-100 shadow-lg">
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
          />

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
                field_name="name" form_prefix="catalogue" changeset={@changeset}
                schema_field={:name} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label="Name" placeholder="e.g., Kitchen Furniture"
                required class="w-full"
              />

              <.translatable_field
                field_name="description" form_prefix="catalogue" changeset={@changeset}
                schema_field={:description} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label="Description" type="textarea"
                placeholder="Brief description of what this catalogue contains..."
                class="w-full"
              />

              <div class="divider my-0"></div>

              <div class="form-control">
                <span class="label-text font-semibold mb-2">Status</span>
                <select name="catalogue[status]" class="select select-bordered w-full transition-colors focus:select-primary">
                  <option value="active" selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}>Active</option>
                  <option value="archived" selected={Ecto.Changeset.get_field(@changeset, :status) == "archived"}>Archived</option>
                </select>
                <span class="label-text-alt text-base-content/50 mt-1">Archived catalogues are hidden from active views.</span>
              </div>

              <%!-- Actions --%>
              <div class="divider my-0"></div>

              <div class="flex justify-end gap-3">
                <.link navigate={Paths.index()} class="btn btn-ghost">Cancel</.link>
                <button type="submit" class="btn btn-primary phx-submit-loading:opacity-75">
                  {if @action == :new, do: "Create Catalogue", else: "Save Changes"}
                </button>
              </div>
            </div>
          </.multilang_fields_wrapper>
        </div>
      </.form>

      <%!-- Danger zone — only in edit mode --%>
      <div :if={@action == :edit} class="card bg-base-100 shadow-lg border border-error/20">
        <div class="card-body flex flex-row items-center justify-between gap-4">
          <div>
            <span class="text-sm font-semibold text-error">Permanently Delete Catalogue</span>
            <p class="text-xs text-base-content/50">This will permanently delete this catalogue, all its categories, and all items within them. This cannot be undone.</p>
          </div>
          <button
            :if={!@confirm_delete}
            phx-click="delete_catalogue"
            class="btn btn-outline btn-error btn-sm shrink-0"
          >
            Delete Forever
          </button>
          <span :if={@confirm_delete} class="inline-flex gap-1 shrink-0">
            <button phx-click="delete_catalogue" class="btn btn-error btn-sm">Confirm</button>
            <button phx-click="cancel_delete" class="btn btn-ghost btn-sm">Cancel</button>
          </span>
        </div>
      </div>
    </div>
    """
  end
end
