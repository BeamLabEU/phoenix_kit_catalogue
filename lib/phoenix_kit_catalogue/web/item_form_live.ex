defmodule PhoenixKitCatalogue.Web.ItemFormLive do
  @moduledoc "Create/edit form for catalogue items with multilang support."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Item

  @translatable_fields ["name", "description"]
  @preserve_fields %{
    "sku" => :sku,
    "base_price" => :base_price,
    "unit" => :unit,
    "status" => :status,
    "category_uuid" => :category_uuid,
    "manufacturer_uuid" => :manufacturer_uuid
  }

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    case load_item(action, params) do
      {nil, _, _} ->
        {:ok, socket |> put_flash(:error, "Item not found.") |> push_navigate(to: Paths.index())}

      {item, changeset, catalogue_uuid} ->
        {:ok, mount_form(socket, action, item, changeset, catalogue_uuid)}
    end
  end

  defp load_item(:new, params) do
    item = %Item{}
    {item, Catalogue.change_item(item), params["catalogue_uuid"]}
  end

  defp load_item(:edit, params) do
    case Catalogue.get_item(params["uuid"]) do
      nil ->
        Logger.warning("Item not found for edit: #{params["uuid"]}")
        {nil, nil, nil}

      item ->
        item = PhoenixKit.RepoHelper.repo().preload(item, [:category, :manufacturer])
        catalogue_uuid = if item.category, do: item.category.catalogue_uuid, else: nil
        {item, Catalogue.change_item(item), catalogue_uuid}
    end
  end

  defp mount_form(socket, action, item, changeset, catalogue_uuid) do
    categories =
      if catalogue_uuid,
        do: Catalogue.list_categories_for_catalogue(catalogue_uuid),
        else: Catalogue.list_all_categories()

    all_categories = if action == :edit, do: Catalogue.list_all_categories(), else: []

    socket
    |> assign(
      page_title: if(action == :new, do: "New Item", else: "Edit #{item.name}"),
      action: action,
      item: item,
      catalogue_uuid: catalogue_uuid,
      changeset: changeset,
      categories: categories,
      manufacturers: Catalogue.list_manufacturers(status: "active"),
      all_categories: all_categories,
      move_target: nil
    )
    |> mount_multilang()
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"item" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.item
      |> Catalogue.change_item(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"item" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    save_item(socket, socket.assigns.action, params)
  end

  def handle_event("select_move_target", %{"category_uuid" => uuid}, socket) do
    target = if uuid == "", do: nil, else: uuid
    {:noreply, assign(socket, :move_target, target)}
  end

  def handle_event("move_item", _params, socket) do
    target = socket.assigns.move_target

    if target do
      case Catalogue.move_item_to_category(socket.assigns.item, target) do
        {:ok, item} ->
          {:noreply,
           socket
           |> put_flash(:info, "Item moved.")
           |> push_navigate(to: redirect_target(socket, item))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to move item.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp save_item(socket, :new, params) do
    case Catalogue.create_item(params) do
      {:ok, item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Item created.")
         |> push_navigate(to: redirect_target(socket, item))}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_item(socket, :edit, params) do
    case Catalogue.update_item(socket.assigns.item, params) do
      {:ok, item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Item updated.")
         |> push_navigate(to: redirect_target(socket, item))}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp redirect_target(socket, item) do
    cond do
      # If the item has a category, resolve catalogue from it
      item.category_uuid ->
        case Catalogue.get_category(item.category_uuid) do
          %{catalogue_uuid: cat_uuid} -> Paths.catalogue_detail(cat_uuid)
          _ -> Paths.index()
        end

      # Fall back to the catalogue we came from
      socket.assigns.catalogue_uuid ->
        Paths.catalogue_detail(socket.assigns.catalogue_uuid)

      true ->
        Paths.index()
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
      <.admin_page_header
        back={if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index()}
        title={@page_title}
        subtitle={if @action == :new, do: "Add a new product or material to the catalogue.", else: "Update item details, pricing, and classification."}
      />

      <.form for={to_form(@changeset)} action="#" phx-change="validate" phx-submit="save">
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
              <%!-- Pricing header --%>
              <div class="skeleton h-5 w-44"></div>
              <%!-- SKU + Price + Unit grid --%>
              <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div class="space-y-2">
                  <div class="skeleton h-4 w-12"></div>
                  <div class="skeleton h-12 w-full"></div>
                </div>
                <div class="space-y-2">
                  <div class="skeleton h-4 w-14"></div>
                  <div class="skeleton h-12 w-full"></div>
                </div>
                <div class="space-y-2">
                  <div class="skeleton h-4 w-12"></div>
                  <div class="skeleton h-12 w-full"></div>
                </div>
              </div>
              <div class="divider my-0"></div>
              <%!-- Classification header --%>
              <div class="skeleton h-5 w-32"></div>
              <%!-- Category + Manufacturer grid --%>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="space-y-2">
                  <div class="skeleton h-4 w-20"></div>
                  <div class="skeleton h-12 w-full"></div>
                </div>
                <div class="space-y-2">
                  <div class="skeleton h-4 w-28"></div>
                  <div class="skeleton h-12 w-full"></div>
                </div>
              </div>
              <%!-- Status --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-16"></div>
                <div class="skeleton h-12 w-full"></div>
              </div>
              <div class="divider my-0"></div>
              <%!-- Buttons --%>
              <div class="flex justify-end gap-3">
                <div class="skeleton h-12 w-20"></div>
                <div class="skeleton h-12 w-32"></div>
              </div>
            </:skeleton>
            <div class="card-body flex flex-col gap-5">
              <.translatable_field
                field_name="name" form_prefix="item" changeset={@changeset}
                schema_field={:name} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label="Name" placeholder="e.g., Oak Panel 18mm" required
                class="w-full"
              />

              <.translatable_field
                field_name="description" form_prefix="item" changeset={@changeset}
                schema_field={:description} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label="Description" type="textarea"
                placeholder="Product specifications, dimensions, materials..."
                class="w-full"
              />

              <div class="divider my-0"></div>

              <%!-- Pricing & identification --%>
              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z" />
                </svg>
                Pricing & Identification
              </h2>

              <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div class="form-control">
                  <span class="label-text font-semibold mb-2">SKU</span>
                  <input type="text" name="item[sku]" value={Ecto.Changeset.get_field(@changeset, :sku) || ""} class="input input-bordered w-full font-mono transition-colors focus:input-primary" placeholder="e.g., KF-001" />
                </div>
                <div class="form-control">
                  <span class="label-text font-semibold mb-2">Base Price</span>
                  <input type="number" name="item[base_price]" value={Ecto.Changeset.get_field(@changeset, :base_price)} class="input input-bordered w-full transition-colors focus:input-primary" step="0.01" min="0" placeholder="0.00" />
                  <span class="label-text-alt text-base-content/50 mt-1">Cost/purchase price before catalogue markup.</span>
                </div>
                <div class="form-control">
                  <span class="label-text font-semibold mb-2">Unit</span>
                  <select name="item[unit]" class="select select-bordered w-full transition-colors focus:select-primary">
                    <option value="piece" selected={Ecto.Changeset.get_field(@changeset, :unit) == "piece"}>Piece</option>
                    <option value="m2" selected={Ecto.Changeset.get_field(@changeset, :unit) == "m2"}>m² (square meter)</option>
                    <option value="running_meter" selected={Ecto.Changeset.get_field(@changeset, :unit) == "running_meter"}>Running meter</option>
                  </select>
                </div>
              </div>

              <div class="divider my-0"></div>

              <%!-- Classification --%>
              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10" />
                </svg>
                Classification
              </h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <span class="label-text font-semibold mb-2">Category</span>
                  <select name="item[category_uuid]" class="select select-bordered w-full transition-colors focus:select-primary">
                    <option value="">-- No category --</option>
                    <option
                      :for={cat <- @categories}
                      value={cat.uuid}
                      selected={to_string(Ecto.Changeset.get_field(@changeset, :category_uuid)) == to_string(cat.uuid)}
                    >
                      {cat.name}
                    </option>
                  </select>
                </div>
                <div class="form-control">
                  <span class="label-text font-semibold mb-2">Manufacturer</span>
                  <select name="item[manufacturer_uuid]" class="select select-bordered w-full transition-colors focus:select-primary">
                    <option value="">-- No manufacturer --</option>
                    <option
                      :for={m <- @manufacturers}
                      value={m.uuid}
                      selected={to_string(Ecto.Changeset.get_field(@changeset, :manufacturer_uuid)) == to_string(m.uuid)}
                    >
                      {m.name}
                    </option>
                  </select>
                </div>
              </div>

              <div class="form-control">
                <span class="label-text font-semibold mb-2">Status</span>
                <select name="item[status]" class="select select-bordered w-full transition-colors focus:select-primary">
                  <option value="active" selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}>Active</option>
                  <option value="inactive" selected={Ecto.Changeset.get_field(@changeset, :status) == "inactive"}>Inactive</option>
                  <option value="discontinued" selected={Ecto.Changeset.get_field(@changeset, :status) == "discontinued"}>Discontinued</option>
                </select>
                <span class="label-text-alt text-base-content/50 mt-1">Discontinued items are kept for reference but hidden from active listings.</span>
              </div>

              <%!-- Actions --%>
              <div class="divider my-0"></div>

              <div class="flex justify-end gap-3">
                <.link navigate={if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index()} class="btn btn-ghost">Cancel</.link>
                <button type="submit" class="btn btn-primary phx-submit-loading:opacity-75">{if @action == :new, do: "Create Item", else: "Save Changes"}</button>
              </div>
            </div>
          </.multilang_fields_wrapper>
        </div>
      </.form>

      <%!-- Move to another category — only in edit mode --%>
      <div :if={@action == :edit && @all_categories != []} class="card bg-base-100 shadow-lg">
        <div class="card-body flex flex-col gap-3">
          <h3 class="text-sm font-semibold text-base-content/80">Move to Another Category</h3>
          <p class="text-xs text-base-content/50">Move this item to a category in any catalogue.</p>
          <div class="flex items-end gap-3">
            <div class="form-control flex-1">
              <select phx-change="select_move_target" name="category_uuid" class="select select-bordered w-full select-sm transition-colors focus:select-primary">
                <option value="">-- Select category --</option>
                <option :for={cat <- @all_categories} value={cat.uuid}>{cat.name}</option>
              </select>
            </div>
            <button
              type="button"
              phx-click="move_item"
              disabled={is_nil(@move_target)}
              class="btn btn-sm btn-outline"
            >
              Move
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
