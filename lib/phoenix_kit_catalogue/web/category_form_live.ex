defmodule PhoenixKitCatalogue.Web.CategoryFormLive do
  @moduledoc "Create/edit form for categories within a catalogue."

  use Phoenix.LiveView

  alias PhoenixKit.Modules.Entities.Multilang
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Category

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
          cat = Catalogue.get_category!(params["uuid"])
          {cat, Catalogue.change_category(cat), cat.catalogue_uuid}
      end

    multilang_enabled = multilang_enabled?()
    primary_lang = if multilang_enabled, do: Multilang.primary_language(), else: nil

    {:ok,
     assign(socket,
       page_title: if(action == :new, do: "New Category", else: "Edit #{category.name}"),
       action: action,
       category: category,
       catalogue_uuid: catalogue_uuid,
       changeset: changeset,
       form: to_form(changeset),
       multilang_enabled: multilang_enabled,
       language_tabs: if(multilang_enabled, do: Multilang.build_language_tabs(), else: []),
       current_lang: primary_lang,
       lang_data: category.data || %{}
     )}
  end

  @impl true
  def handle_event("validate", %{"category" => params}, socket) do
    changeset =
      socket.assigns.category
      |> Catalogue.change_category(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
  end

  def handle_event("save", %{"category" => params}, socket) do
    params =
      params
      |> Map.put_new("catalogue_uuid", socket.assigns.catalogue_uuid)
      |> maybe_merge_multilang(socket.assigns)

    save_category(socket, socket.assigns.action, params)
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

  defp save_category(socket, :new, params) do
    case Catalogue.create_category(params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category created.")
         |> push_navigate(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end

  defp save_category(socket, :edit, params) do
    case Catalogue.update_category(socket.assigns.category, params) do
      {:ok, _category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category updated.")
         |> push_navigate(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))}

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
    name = Map.get(lang_data, "_name", socket.assigns.category.name || "")
    description = Map.get(lang_data, "_description", socket.assigns.category.description || "")

    socket.assigns.category
    |> Catalogue.change_category(%{"name" => name, "description" => description})
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
        <.link navigate={Paths.catalogue_detail(@catalogue_uuid)} class="btn btn-ghost btn-sm btn-square">
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
                name="category[name]"
                value={@form[:name].value}
                class={["input input-bordered", @form[:name].errors != [] && "input-error"]}
                placeholder="e.g., Cabinet Frames"
              />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Description</span></label>
              <textarea
                name="category[description]"
                class="textarea textarea-bordered"
                rows="3"
              >{@form[:description].value}</textarea>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Position</span></label>
              <input
                type="number"
                name="category[position]"
                value={@form[:position].value}
                class="input input-bordered w-24"
                min="0"
              />
              <label class="label">
                <span class="label-text-alt text-base-content/60">Lower numbers appear first</span>
              </label>
            </div>

            <div class="flex justify-end gap-2 mt-4">
              <.link navigate={Paths.catalogue_detail(@catalogue_uuid)} class="btn btn-ghost">Cancel</.link>
              <button type="submit" class="btn btn-primary">
                {if @action == :new, do: "Create Category", else: "Save Changes"}
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
