defmodule PhoenixKitCatalogue.Web.CatalogueFormLive do
  @moduledoc "Create/edit form for catalogues with multilang support."

  use Phoenix.LiveView

  alias PhoenixKit.Modules.Entities.Multilang
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {catalogue, changeset} =
      case action do
        :new ->
          cat = %CatalogueSchema{}
          {cat, Catalogue.change_catalogue(cat)}

        :edit ->
          cat = Catalogue.get_catalogue!(params["uuid"])
          {cat, Catalogue.change_catalogue(cat)}
      end

    multilang_enabled = multilang_enabled?()
    primary_lang = if multilang_enabled, do: Multilang.primary_language(), else: nil

    {:ok,
     assign(socket,
       page_title: if(action == :new, do: "New Catalogue", else: "Edit #{catalogue.name}"),
       action: action,
       catalogue: catalogue,
       changeset: changeset,
       form: to_form(changeset),
       multilang_enabled: multilang_enabled,
       language_tabs: if(multilang_enabled, do: Multilang.build_language_tabs(), else: []),
       current_lang: primary_lang,
       lang_data: catalogue.data || %{}
     )}
  end

  @impl true
  def handle_event("validate", %{"catalogue" => params}, socket) do
    changeset =
      socket.assigns.catalogue
      |> Catalogue.change_catalogue(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
  end

  def handle_event("save", %{"catalogue" => params}, socket) do
    params = maybe_merge_multilang(params, socket.assigns)
    save_catalogue(socket, socket.assigns.action, params)
  end

  def handle_event("switch_lang", %{"lang" => lang_code}, socket) do
    # Save current language data before switching
    socket = save_current_lang_to_data(socket)
    lang_data = Multilang.get_language_data(socket.assigns.lang_data, lang_code)

    {:noreply,
     assign(socket,
       current_lang: lang_code,
       form: to_form(apply_lang_to_changeset(socket, lang_data))
     )}
  end

  defp save_catalogue(socket, :new, params) do
    case Catalogue.create_catalogue(params) do
      {:ok, catalogue} ->
        {:noreply,
         socket
         |> put_flash(:info, "Catalogue created.")
         |> push_navigate(to: Paths.catalogue_detail(catalogue.uuid))}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
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
    name = Map.get(lang_data, "_name", socket.assigns.catalogue.name || "")
    description = Map.get(lang_data, "_description", socket.assigns.catalogue.description || "")

    socket.assigns.catalogue
    |> Catalogue.change_catalogue(%{"name" => name, "description" => description})
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
        <.link navigate={Paths.index()} class="btn btn-ghost btn-sm btn-square">
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
                name="catalogue[name]"
                value={@form[:name].value}
                class={["input input-bordered", @form[:name].errors != [] && "input-error"]}
                placeholder="e.g., Kitchen Furniture"
              />
              <.form_errors field={@form[:name]} />
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Description</span></label>
              <textarea
                name="catalogue[description]"
                class="textarea textarea-bordered"
                rows="3"
                placeholder="Optional description"
              >{@form[:description].value}</textarea>
            </div>

            <div class="form-control">
              <label class="label"><span class="label-text">Status</span></label>
              <select name="catalogue[status]" class="select select-bordered">
                <option value="active" selected={@form[:status].value == "active"}>Active</option>
                <option value="archived" selected={@form[:status].value == "archived"}>Archived</option>
              </select>
            </div>

            <div class="flex justify-end gap-2 mt-4">
              <.link navigate={Paths.index()} class="btn btn-ghost">Cancel</.link>
              <button type="submit" class="btn btn-primary">
                {if @action == :new, do: "Create Catalogue", else: "Save Changes"}
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
