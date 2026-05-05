defmodule PhoenixKitCatalogue.Web.PdfDetailLive do
  @moduledoc """
  Single-PDF detail page. Shows metadata + extraction status, embeds
  the vendored PDF.js viewer in an iframe pre-bound to the file and
  the optional `?page=N` URL param.

  When a search hit from the per-item PDF search button navigates
  here with `?page=N`, the iframe URL embeds `#page=N` and PDF.js
  scrolls the viewer to that page on load.
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.Helpers

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    case load_pdf(uuid) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "PDF not found."))
         |> push_navigate(to: Paths.pdfs())}

      pdf ->
        if connected?(socket), do: CataloguePubSub.subscribe()

        {:ok,
         assign(socket,
           pdf: pdf,
           page_title: pdf.original_filename,
           page: nil
         )}
    end
  end

  defp load_pdf(uuid) do
    case Catalogue.get_pdf(uuid) do
      nil -> nil
      pdf -> PhoenixKit.RepoHelper.repo().preload(pdf, :extraction)
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page_param(Map.get(params, "page"))
    {:noreply, assign(socket, :page, page)}
  end

  @impl true
  def handle_event("trash", _params, socket) do
    case Catalogue.trash_pdf(socket.assigns.pdf, Helpers.actor_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "PDF moved to trash."))
         |> push_navigate(to: Paths.pdfs())}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Could not move the PDF to trash.")
         )}
    end
  end

  @impl true
  def handle_event("restore", _params, socket) do
    case Catalogue.restore_pdf(socket.assigns.pdf, Helpers.actor_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "PDF restored."))
         |> assign(:pdf, load_pdf(socket.assigns.pdf.uuid))}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Could not restore the PDF.")
         )}
    end
  end

  @impl true
  def handle_event("permanently_delete", _params, socket) do
    case Catalogue.permanently_delete_pdf(socket.assigns.pdf, Helpers.actor_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "PDF permanently deleted."))
         |> push_navigate(to: Paths.pdfs())}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Could not permanently delete the PDF.")
         )}
    end
  end

  @impl true
  def handle_info({:catalogue_data_changed, :pdf, uuid, _parent}, socket) do
    if uuid == socket.assigns.pdf.uuid do
      case load_pdf(uuid) do
        nil -> {:noreply, push_navigate(socket, to: Paths.pdfs())}
        refreshed -> {:noreply, assign(socket, :pdf, refreshed)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:catalogue_data_changed, _kind, _uuid, _parent}, socket),
    do: {:noreply, socket}

  def handle_info(msg, socket) do
    Logger.debug("PdfDetailLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp parse_page_param(nil), do: nil

  defp parse_page_param(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 1 -> n
      _ -> nil
    end
  end

  defp parse_page_param(_), do: nil

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-4">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <.link
              navigate={Paths.pdfs()}
              class="btn btn-ghost btn-xs"
              title={Gettext.gettext(PhoenixKitWeb.Gettext, "Back to library")}
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" />
            </.link>
            <h2 class="text-lg font-semibold truncate" title={@pdf.original_filename}>
              {@pdf.original_filename}
            </h2>
            <%= if @pdf.status == "trashed" do %>
              <span class="badge badge-sm badge-warning">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Trashed")}
              </span>
            <% end %>
          </div>

          <div class="flex items-center gap-3 mt-2 text-xs text-base-content/60">
            <span class={"badge badge-sm #{extraction_badge_class(@pdf)}"}>
              {extraction_status_label(@pdf)}
            </span>
            <%= if page_count(@pdf) do %>
              <span>
                {Gettext.gettext(PhoenixKitWeb.Gettext, "%{count} pages",
                  count: page_count(@pdf)
                )}
              </span>
            <% end %>
            <%= if @pdf.byte_size do %>
              <span>{format_size(@pdf.byte_size)}</span>
            <% end %>
            <%= if extracted_at(@pdf) do %>
              <span>
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Extracted")}: {Calendar.strftime(
                  extracted_at(@pdf),
                  "%b %d, %Y %H:%M"
                )}
              </span>
            <% end %>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <%= if @pdf.status == "trashed" do %>
            <button
              type="button"
              phx-click="restore"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Restore")}
            </button>
            <button
              type="button"
              phx-click="permanently_delete"
              data-confirm={
                Gettext.gettext(
                  PhoenixKitWeb.Gettext,
                  "Permanently delete this PDF? If no other library entry references the same file content, the underlying file will be queued for hard deletion."
                )
              }
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Delete forever")}
            </button>
          <% else %>
            <button
              type="button"
              phx-click="trash"
              data-confirm={
                Gettext.gettext(PhoenixKitWeb.Gettext, "Move this PDF to trash?")
              }
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Trash")}
            </button>
          <% end %>
        </div>
      </div>

      <%= if extraction_status(@pdf) == "failed" and error_message(@pdf) do %>
        <div class="alert alert-error">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
          <div>
            <div class="font-semibold">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Extraction failed")}
            </div>
            <div class="text-xs opacity-80">{error_message(@pdf)}</div>
          </div>
        </div>
      <% end %>

      <%= if extraction_status(@pdf) == "scanned_no_text" do %>
        <div class="alert alert-warning">
          <.icon name="hero-photo" class="w-4 h-4" />
          <div>
            <div class="font-semibold">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "No extractable text")}
            </div>
            <div class="text-xs opacity-80">
              {Gettext.gettext(
                PhoenixKitWeb.Gettext,
                "This PDF appears to be scanned. OCR support is planned for a future iteration."
              )}
            </div>
          </div>
        </div>
      <% end %>

      <%= if extraction_status(@pdf) in ["pending", "extracting"] do %>
        <div class="alert alert-info">
          <span class="loading loading-spinner loading-sm"></span>
          <div>
            {Gettext.gettext(
              PhoenixKitWeb.Gettext,
              "Text extraction in progress. This page will refresh automatically when it completes."
            )}
          </div>
        </div>
      <% end %>

      <%!-- PDF.js embedded viewer --%>
      <div class="rounded-lg border border-base-300 overflow-hidden bg-base-200" style="height: 80vh">
        <iframe
          src={viewer_url(@pdf, @page)}
          class="w-full h-full border-0"
          title={@pdf.original_filename}
        >
        </iframe>
      </div>
    </div>
    """
  end

  defp viewer_url(pdf, nil), do: Paths.pdf_viewer(pdf)
  defp viewer_url(pdf, page) when is_integer(page), do: Paths.pdf_viewer(pdf, page)

  # ── Extraction accessor helpers ─────────────────────────────────────

  defp extraction_status(%{extraction: %{extraction_status: s}}) when is_binary(s), do: s
  defp extraction_status(_), do: "pending"

  defp page_count(%{extraction: %{page_count: n}}) when is_integer(n), do: n
  defp page_count(_), do: nil

  defp extracted_at(%{extraction: %{extracted_at: dt}}), do: dt
  defp extracted_at(_), do: nil

  defp error_message(%{extraction: %{error_message: m}}) when is_binary(m), do: m
  defp error_message(_), do: nil

  defp extraction_badge_class(pdf) do
    case extraction_status(pdf) do
      "pending" -> "badge-ghost"
      "extracting" -> "badge-info"
      "extracted" -> "badge-success"
      "scanned_no_text" -> "badge-warning"
      "failed" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp extraction_status_label(pdf) do
    case extraction_status(pdf) do
      "pending" -> Gettext.gettext(PhoenixKitWeb.Gettext, "Pending")
      "extracting" -> Gettext.gettext(PhoenixKitWeb.Gettext, "Extracting")
      "extracted" -> Gettext.gettext(PhoenixKitWeb.Gettext, "Extracted")
      "scanned_no_text" -> Gettext.gettext(PhoenixKitWeb.Gettext, "Scanned (no text)")
      "failed" -> Gettext.gettext(PhoenixKitWeb.Gettext, "Failed")
      other -> other
    end
  end

  defp format_size(nil), do: "—"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)} KB"
  defp format_size(bytes) when bytes < 1024 * 1024 * 1024, do: "#{div(bytes, 1024 * 1024)} MB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
end
