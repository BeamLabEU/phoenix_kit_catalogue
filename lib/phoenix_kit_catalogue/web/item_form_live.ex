defmodule PhoenixKitCatalogue.Web.ItemFormLive do
  @moduledoc "Create/edit form for catalogue items with multilang support."

  use Phoenix.LiveView

  alias PhoenixKit.Modules.Entities.Multilang
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Item

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {item, changeset, catalogue_uuid} =
      case action do
        :new ->
          catalogue_uuid = params["catalogue_uuid"]
          item = %Item{}
          {item, Catalogue.change_item(item), catalogue_uuid}

        :edit ->
          item = Catalogue.get_item!(params["uuid"])
          catalogue_uuid = if item.category, do: item.category.catalogue_uuid, else: nil
          {item, Catalogue.change_item(item), catalogue_uuid}
      end

    categories =
      if catalogue_uuid,
        do: Catalogue.list_categories_for_catalogue(catalogue_uuid),
        else: []

    manufacturers = Catalogue.list_manufacturers(status: "active")
    multilang_enabled = multilang_enabled?()
    primary_lang = if multilang_enabled, do: Multilang.primary_language(), else: nil

    {:ok,
     assign(socket,
       page_title: if(action == :new, do: "New Item", else: "Edit #{item.name}"),
       action: action,
       item: item,
       catalogue_uuid: catalogue_uuid,
       changeset: changeset,
       form: to_form(changeset),
       categories: categories,
       manufacturers: manufacturers,
       multilang_enabled: multilang_enabled,
       language_tabs: if(multilang_enabled, do: Multilang.build_language_tabs(), else: []),
       current_lang: primary_lang,
       lang_data: item.data || %{}
     )}
  end

  @impl true
  def handle_event("validate", %{"item" => params}, socket) do
    changeset =
      socket.assigns.item
      |> Catalogue.change_item(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
  end

  def handle_event("save", %{"item" => params}, socket) do
    params = maybe_merge_multilang(params, socket.assigns)
    save_item(socket, socket.assigns.action, params)
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

  defp save_item(socket, :new, params) do
    case Catalogue.create_item(params) do
      {:ok, _item} ->
        target =
          if socket.assigns.catalogue_uuid,
            do: Paths.catalogue_detail(socket.assigns.catalogue_uuid),
            else: Paths.index()

        {:noreply,
         socket
         |> put_flash(:info, "Item created.")
         |> push_navigate(to: target)}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end

  defp save_item(socket, :edit, params) do
    case Catalogue.update_item(socket.assigns.item, params) do
      {:ok, _item} ->
        target =
          if socket.assigns.catalogue_uuid,
            do: Paths.catalogue_detail(socket.assigns.catalogue_uuid),
            else: Paths.index()

        {:noreply,
         socket
         |> put_flash(:info, "Item updated.")
         |> push_navigate(to: target)}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
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
    name = Map.get(lang_data, "_name", socket.assigns.item.name || "")
    description = Map.get(lang_data, "_description", socket.assigns.item.description || "")

    socket.assigns.item
    |> Catalogue.change_item(%{"name" => name, "description" => description})
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
        <.link
          navigate={if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index()}
          class="btn btn-ghost btn-sm btn-square"
        >
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
                name="item[name]"
                value={@form[:name].value}
                class={["input input-bordered", @form[:name].errors != [] && "input-error"]}
              />
              <.form_errors field={@form[:name]} />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Description</span></label>
              <textarea name="item[description]" class="textarea textarea-bordered" rows="3">{@form[:description].value}</textarea>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div class="form-control">
                <label class="label"><span class="label-text">SKU</span></label>
                <input
                  type="text"
                  name="item[sku]"
                  value={@form[:sku].value}
                  class={["input input-bordered font-mono", @form[:sku].errors != [] && "input-error"]}
                  placeholder="e.g., KF-001"
                />
                <.form_errors field={@form[:sku]} />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Price</span></label>
                <input
                  type="number"
                  name="item[price]"
                  value={@form[:price].value}
                  class="input input-bordered"
                  step="0.01"
                  min="0"
                />
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Unit</span></label>
                <select name="item[unit]" class="select select-bordered">
                  <option value="piece" selected={@form[:unit].value == "piece"}>Piece</option>
                  <option value="m2" selected={@form[:unit].value == "m2"}>m² (square meter)</option>
                  <option value="running_meter" selected={@form[:unit].value == "running_meter"}>Running meter</option>
                </select>
              </div>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-control">
                <label class="label"><span class="label-text">Category</span></label>
                <select name="item[category_uuid]" class="select select-bordered">
                  <option value="">— No category —</option>
                  <option
                    :for={cat <- @categories}
                    value={cat.uuid}
                    selected={to_string(@form[:category_uuid].value) == to_string(cat.uuid)}
                  >
                    {cat.name}
                  </option>
                </select>
              </div>

              <div class="form-control">
                <label class="label"><span class="label-text">Manufacturer</span></label>
                <select name="item[manufacturer_uuid]" class="select select-bordered">
                  <option value="">— No manufacturer —</option>
                  <option
                    :for={m <- @manufacturers}
                    value={m.uuid}
                    selected={to_string(@form[:manufacturer_uuid].value) == to_string(m.uuid)}
                  >
                    {m.name}
                  </option>
                </select>
              </div>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Status</span></label>
              <select name="item[status]" class="select select-bordered">
                <option value="active" selected={@form[:status].value == "active"}>Active</option>
                <option value="inactive" selected={@form[:status].value == "inactive"}>Inactive</option>
                <option value="discontinued" selected={@form[:status].value == "discontinued"}>Discontinued</option>
              </select>
            </div>

            <div class="flex justify-end gap-2 mt-4">
              <.link
                navigate={if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index()}
                class="btn btn-ghost"
              >
                Cancel
              </.link>
              <button type="submit" class="btn btn-primary">
                {if @action == :new, do: "Create Item", else: "Save Changes"}
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp form_errors(assigns) do
    ~H"""
    <div :for={msg <- Enum.map(@field.errors, &translate_error/1)} class="label">
      <span class="label-text-alt text-error">{msg}</span>
    </div>
    """
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
