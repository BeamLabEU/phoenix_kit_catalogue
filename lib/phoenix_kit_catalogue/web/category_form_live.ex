defmodule PhoenixKitCatalogue.Web.CategoryFormLive do
  @moduledoc "Create/edit form for categories within a catalogue."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Category

  @translatable_fields ["name", "description"]

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {category, changeset, catalogue_uuid} =
      case action do
        :new ->
          catalogue_uuid = params["catalogue_uuid"]
          next_pos = Catalogue.next_category_position(catalogue_uuid)
          cat = %Category{catalogue_uuid: catalogue_uuid, position: next_pos}
          {cat, Catalogue.change_category(cat), catalogue_uuid}

        :edit ->
          case Catalogue.get_category(params["uuid"]) do
            nil ->
              Logger.warning("Category not found for edit: #{params["uuid"]}")
              {nil, nil, nil}

            cat ->
              {cat, Catalogue.change_category(cat), cat.catalogue_uuid}
          end
      end

    if is_nil(category) and action == :edit do
      {:ok, socket |> put_flash(:error, "Category not found.") |> push_navigate(to: Paths.index())}
    else
      mount_category_form(socket, action, category, changeset, catalogue_uuid)
    end
  end

  defp mount_category_form(socket, action, category, changeset, catalogue_uuid) do
    other_catalogues =
      if action == :edit do
        Catalogue.list_catalogues()
        |> Enum.reject(&(&1.uuid == catalogue_uuid))
      else
        []
      end

    {:ok,
     socket
     |> assign(
       page_title: if(action == :new, do: "New Category", else: "Edit #{category.name}"),
       action: action,
       category: category,
       catalogue_uuid: catalogue_uuid,
       changeset: changeset,
       confirm_delete_all: false,
       other_catalogues: other_catalogues,
       move_target: nil
     )
     |> mount_multilang()}
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"category" => params}, socket) do
    params =
      params
      |> Map.put_new("catalogue_uuid", socket.assigns.catalogue_uuid)
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset
      )

    changeset =
      socket.assigns.category
      |> Catalogue.change_category(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"category" => params}, socket) do
    params =
      params
      |> Map.put_new("catalogue_uuid", socket.assigns.catalogue_uuid)
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset
      )

    save_category(socket, socket.assigns.action, params)
  end

  def handle_event("delete_category", _params, socket) do
    if socket.assigns.confirm_delete_all do
      case Catalogue.permanently_delete_category(socket.assigns.category) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Category and all its items permanently deleted.")
           |> push_navigate(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:confirm_delete_all, false)
           |> put_flash(:error, "Failed to delete category.")}
      end
    else
      {:noreply, assign(socket, :confirm_delete_all, true)}
    end
  end

  def handle_event("select_move_target", %{"catalogue_uuid" => uuid}, socket) do
    target = if uuid == "", do: nil, else: uuid
    {:noreply, assign(socket, :move_target, target)}
  end

  def handle_event("move_category", _params, socket) do
    target = socket.assigns.move_target

    if target do
      case Catalogue.move_category_to_catalogue(socket.assigns.category, target) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Category moved to another catalogue.")
           |> push_navigate(to: Paths.catalogue_detail(target))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to move category.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_all, false)}
  end

  defp save_category(socket, :new, params) do
    case Catalogue.create_category(params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category created.")
         |> push_navigate(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_category(socket, :edit, params) do
    case Catalogue.update_category(socket.assigns.category, params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category updated.")
         |> push_navigate(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))}

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
        <.link navigate={Paths.catalogue_detail(@catalogue_uuid)} class="btn btn-ghost btn-sm btn-square">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </.link>
        <div>
          <h1 class="text-2xl font-bold">{@page_title}</h1>
          <p class="text-sm text-base-content/60 mt-0.5">
            {if @action == :new, do: "Add a new category to organize items within this catalogue.", else: "Update category details and ordering."}
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
              <%!-- Position --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-20"></div>
                <div class="skeleton h-12 w-28"></div>
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
                field_name="name" form_prefix="category" changeset={@changeset}
                schema_field={:name} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label="Name" placeholder="e.g., Cabinet Frames"
                required class="w-full"
              />

              <.translatable_field
                field_name="description" form_prefix="category" changeset={@changeset}
                schema_field={:description} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label="Description" type="textarea"
                placeholder="What kinds of items belong in this category..."
                class="w-full"
              />

              <div class="divider my-0"></div>

              <div class="form-control">
                <span class="label-text font-semibold mb-2">Position</span>
                <input type="number" name="category[position]" value={Ecto.Changeset.get_field(@changeset, :position)} class="input input-bordered w-28 transition-colors focus:input-primary" min="0" />
                <span class="label-text-alt text-base-content/50 mt-1">Lower numbers appear first. You can also reorder from the catalogue detail page.</span>
              </div>

              <%!-- Actions --%>
              <div class="divider my-0"></div>

              <div class="flex justify-end gap-3">
                <.link navigate={Paths.catalogue_detail(@catalogue_uuid)} class="btn btn-ghost">Cancel</.link>
                <button type="submit" class="btn btn-primary phx-submit-loading:opacity-75">{if @action == :new, do: "Create Category", else: "Save Changes"}</button>
              </div>
            </div>
          </.multilang_fields_wrapper>
        </div>
      </.form>

      <%!-- Move to another catalogue — only in edit mode with other catalogues available --%>
      <div :if={@action == :edit && @other_catalogues != []} class="card bg-base-100 shadow-lg">
        <div class="card-body flex flex-col gap-3">
          <h3 class="text-sm font-semibold text-base-content/80">Move to Another Catalogue</h3>
          <p class="text-xs text-base-content/50">Move this category and all its items to a different catalogue.</p>
          <div class="flex items-end gap-3">
            <div class="form-control flex-1">
              <select phx-change="select_move_target" name="catalogue_uuid" class="select select-bordered w-full select-sm transition-colors focus:select-primary">
                <option value="">-- Select catalogue --</option>
                <option :for={cat <- @other_catalogues} value={cat.uuid}>{cat.name}</option>
              </select>
            </div>
            <button
              type="button"
              phx-click="move_category"
              disabled={is_nil(@move_target)}
              class="btn btn-sm btn-outline"
            >
              Move
            </button>
          </div>
        </div>
      </div>

      <%!-- Danger zone — only in edit mode --%>
      <div :if={@action == :edit} class="card bg-base-100 shadow-lg border border-error/20">
        <div class="card-body flex flex-row items-center justify-between gap-4">
          <div>
            <span class="text-sm font-semibold text-error">Permanently Delete Category</span>
            <p class="text-xs text-base-content/50">This will permanently delete this category and all its items. This cannot be undone.</p>
          </div>
          <button
            :if={!@confirm_delete_all}
            phx-click="delete_category"
            class="btn btn-outline btn-error btn-sm shrink-0"
          >
            Delete Forever
          </button>
          <span :if={@confirm_delete_all} class="inline-flex gap-1 shrink-0">
            <button phx-click="delete_category" class="btn btn-error btn-sm">Confirm</button>
            <button phx-click="cancel_delete" class="btn btn-ghost btn-sm">Cancel</button>
          </span>
        </div>
      </div>
    </div>
    """
  end
end
