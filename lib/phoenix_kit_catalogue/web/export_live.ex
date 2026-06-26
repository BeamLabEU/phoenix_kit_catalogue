defmodule PhoenixKitCatalogue.Web.ExportLive do
  @moduledoc """
  Export tab LiveView.

  Lets the user select a source, catalogue, optional category, and format,
  then download the generated file in-memory via a stateless controller GET.
  """

  use Phoenix.LiveView

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Export
  alias PhoenixKitCatalogue.Paths

  @impl true
  def mount(_params, _session, socket) do
    sources = Export.sources()
    selected_source = List.first(sources)
    catalogues = Catalogue.list_catalogues()

    {:ok,
     socket
     |> assign(
       page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Export"),
       sources: sources,
       selected_source: selected_source,
       catalogues: catalogues,
       selected_catalogue: nil,
       catalogue_categories: [],
       selected_category_uuid: nil,
       selected_format: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_form", params, socket) do
    {:noreply, apply_form_params(socket, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-6">
          <h2 class="card-title">
            <.icon name="hero-arrow-down-tray" class="w-5 h-5" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Export Items")}
          </h2>

          <form id="export-form" phx-change="change_form" class="flex flex-col gap-4">
            <%!-- Source select --%>
            <div class="form-control w-full max-w-md">
              <span class="block mb-2 text-sm font-medium">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Source")}
              </span>
              <.select
                name="source"
                id="export-source"
                value={@selected_source && @selected_source.key() |> Atom.to_string()}
                options={Enum.map(@sources, &{&1.label(), Atom.to_string(&1.key())})}
              />
            </div>

            <%!-- Catalogue select --%>
            <div class="form-control w-full max-w-md">
              <span class="block mb-2 text-sm font-medium">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue")}
              </span>
              <.select
                name="catalogue_uuid"
                id="export-catalogue"
                value={@selected_catalogue && @selected_catalogue.uuid}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select a catalogue...")}
                options={Enum.map(@catalogues, &{&1.name, &1.uuid})}
              />
            </div>

            <%!-- Category select --%>
            <div class="form-control w-full max-w-md">
              <span class="block mb-2 text-sm font-medium">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category")}
              </span>
              <.select
                name="category_uuid"
                id="export-category"
                value={@selected_category_uuid}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "All categories")}
                options={Enum.map(@catalogue_categories, &{&1.name, &1.uuid})}
              />
            </div>

            <%!-- Format select --%>
            <div class="form-control w-full max-w-md">
              <span class="block mb-2 text-sm font-medium">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Format")}
              </span>
              <.select
                name="format"
                id="export-format"
                value={@selected_format}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select a format...")}
                options={
                  if @selected_source do
                    Enum.map(@selected_source.formats(), fn {k, label} ->
                      {label, Atom.to_string(k)}
                    end)
                  else
                    []
                  end
                }
              />
            </div>
          </form>

          <%!-- Export button — plain <a> so the browser triggers a file download --%>
          <%= if download_url(assigns) do %>
            <a href={download_url(assigns)} class="btn btn-primary w-fit">
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Export")}
            </a>
          <% else %>
            <button class="btn btn-primary w-fit btn-disabled" disabled>
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Export")}
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp download_url(%{
         selected_catalogue: %{uuid: cat_uuid},
         selected_source: source,
         selected_format: format,
         selected_category_uuid: category_uuid
       })
       when not is_nil(source) and not is_nil(format) do
    params =
      %{source: Atom.to_string(source.key()), format: format, catalogue_uuid: cat_uuid}
      |> maybe_put(:category_uuid, category_uuid)

    Paths.export_download(params)
  end

  defp download_url(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp apply_form_params(socket, params) do
    source_key = Map.get(params, "source")
    catalogue_uuid = presence(Map.get(params, "catalogue_uuid"))
    category_uuid = presence(Map.get(params, "category_uuid"))
    format_str = presence(Map.get(params, "format"))

    selected_source =
      if source_key do
        Enum.find(socket.assigns.sources, fn mod ->
          Atom.to_string(mod.key()) == source_key
        end)
      else
        socket.assigns.selected_source
      end

    selected_catalogue =
      if catalogue_uuid do
        Enum.find(socket.assigns.catalogues, fn c -> c.uuid == catalogue_uuid end)
      else
        nil
      end

    catalogue_categories =
      if selected_catalogue do
        Catalogue.list_categories_metadata_for_catalogue(selected_catalogue.uuid)
      else
        []
      end

    # Reset category selection if it no longer belongs to the new catalogue
    selected_category_uuid =
      if Enum.any?(catalogue_categories, fn c -> c.uuid == category_uuid end) do
        category_uuid
      else
        nil
      end

    # Reset format if the source changed and the format is no longer valid
    selected_format =
      if selected_source && format_str &&
           Enum.any?(selected_source.formats(), fn {k, _} -> Atom.to_string(k) == format_str end) do
        format_str
      else
        nil
      end

    assign(socket,
      selected_source: selected_source,
      selected_catalogue: selected_catalogue,
      catalogue_categories: catalogue_categories,
      selected_category_uuid: selected_category_uuid,
      selected_format: selected_format
    )
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(str) when is_binary(str), do: str
end
