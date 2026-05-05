defmodule PhoenixKitCatalogue.Web.PdfLibraryLive do
  @moduledoc """
  Admin index for the PDF library subtab.

  Shows the upload dropzone, list of uploaded PDFs filtered by
  lifecycle (active vs trashed), per-row extraction status badge,
  and trash/restore/permanent-delete actions. Subscribes to the
  catalogue PubSub topic so worker status changes refresh the list
  without a manual reload.
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.FileUpload, only: [file_upload: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.Helpers

  @max_file_size 200 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: CataloguePubSub.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "PDFs"),
       filter: "active",
       pdfs: Catalogue.list_pdfs(status: "active"),
       upload_error: nil
     )
     |> allow_upload(:pdf,
       accept: ~w(.pdf application/pdf),
       max_entries: 5,
       max_file_size: @max_file_size,
       chunk_size: 5_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :pdf, ref)}
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket)
      when filter in ["active", "trashed"] do
    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:pdfs, Catalogue.list_pdfs(status: filter))}
  end

  @impl true
  def handle_event("trash", %{"uuid" => uuid}, socket) do
    handle_pdf_action(socket, uuid, &Catalogue.trash_pdf/2,
      success: Gettext.gettext(PhoenixKitWeb.Gettext, "PDF moved to trash."),
      failure: Gettext.gettext(PhoenixKitWeb.Gettext, "Could not move the PDF to trash.")
    )
  end

  @impl true
  def handle_event("restore", %{"uuid" => uuid}, socket) do
    handle_pdf_action(socket, uuid, &Catalogue.restore_pdf/2,
      success: Gettext.gettext(PhoenixKitWeb.Gettext, "PDF restored."),
      failure: Gettext.gettext(PhoenixKitWeb.Gettext, "Could not restore the PDF.")
    )
  end

  @impl true
  def handle_event("permanently_delete", %{"uuid" => uuid}, socket) do
    handle_pdf_action(socket, uuid, &Catalogue.permanently_delete_pdf/2,
      success: Gettext.gettext(PhoenixKitWeb.Gettext, "PDF permanently deleted."),
      failure: Gettext.gettext(PhoenixKitWeb.Gettext, "Could not permanently delete the PDF.")
    )
  end

  defp handle_pdf_action(socket, uuid, action_fn, messages) do
    case Catalogue.get_pdf(uuid) do
      nil ->
        {:noreply, socket}

      pdf ->
        case action_fn.(pdf, Helpers.actor_opts(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, Keyword.fetch!(messages, :success))
             |> assign(:pdfs, Catalogue.list_pdfs(status: socket.assigns.filter))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, Keyword.fetch!(messages, :failure))}
        end
    end
  end

  @impl true
  def handle_info({:catalogue_data_changed, :pdf, _uuid, _parent}, socket) do
    {:noreply, assign(socket, :pdfs, Catalogue.list_pdfs(status: socket.assigns.filter))}
  end

  def handle_info({:catalogue_data_changed, _kind, _uuid, _parent}, socket),
    do: {:noreply, socket}

  def handle_info(msg, socket) do
    Logger.debug("PdfLibraryLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Upload progress handler ─────────────────────────────────────────

  defp handle_progress(:pdf, entry, socket) do
    if entry.done? do
      finalize_upload(socket, entry)
    else
      {:noreply, socket}
    end
  end

  defp finalize_upload(socket, entry) do
    consume_result =
      consume_uploaded_entry(socket, entry, fn %{path: tmp_path} ->
        {:ok,
         Catalogue.create_pdf_from_upload(
           tmp_path,
           entry.client_name,
           entry.client_size,
           Helpers.actor_opts(socket)
         )}
      end)

    case consume_result do
      {:ok, _pdf} ->
        {:noreply,
         socket
         |> assign(:upload_error, nil)
         |> assign(:pdfs, Catalogue.list_pdfs(status: socket.assigns.filter))}

      {:error, reason} ->
        Logger.warning("PDF upload failed: #{inspect(reason)}")
        {:noreply, assign(socket, :upload_error, format_upload_failure(reason))}
    end
  end

  defp format_upload_failure({:storage_failed, reason}),
    do: "Could not save uploaded file: #{inspect(reason)}"

  defp format_upload_failure(other), do: inspect(other)

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "PDF library")}
        </h2>
        <div class="flex items-center gap-3">
          <div class="join">
            <button
              type="button"
              phx-click="set_filter"
              phx-value-filter="active"
              class={"join-item btn btn-sm #{if @filter == "active", do: "btn-primary", else: "btn-ghost"}"}
            >
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Active")}
            </button>
            <button
              type="button"
              phx-click="set_filter"
              phx-value-filter="trashed"
              class={"join-item btn btn-sm #{if @filter == "trashed", do: "btn-primary", else: "btn-ghost"}"}
            >
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Trash")}
            </button>
          </div>
          <div class="text-sm text-base-content/60">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "%{count} PDFs", count: length(@pdfs))}
          </div>
        </div>
      </div>

      <%!-- Upload zone (hidden in trash view) --%>
      <%= if @filter == "active" do %>
        <div class="bg-base-100 rounded-lg p-4">
          <.file_upload
            upload={@uploads.pdf}
            label={Gettext.gettext(PhoenixKitWeb.Gettext, "Upload PDF")}
            icon="hero-document-arrow-up"
            accept_description={
              Gettext.gettext(
                PhoenixKitWeb.Gettext,
                "PDF files only. Identical content is deduplicated; same file uploaded again under a new name shares one underlying file + extraction."
              )
            }
            max_size_description="200MB"
          />

          <div class="text-xs text-base-content/60 mt-2 italic">
            {Gettext.gettext(
              PhoenixKitWeb.Gettext,
              "The progress bar shows the browser → server upload only. Don't refresh until it completes — interrupted uploads are not resumed."
            )}
          </div>

          <%= for entry <- @uploads.pdf.entries do %>
            <%= for err <- upload_errors(@uploads.pdf, entry) do %>
              <div class="text-error text-xs mt-1">{format_upload_error(err)}</div>
            <% end %>
          <% end %>

          <%= if @upload_error do %>
            <div class="text-error text-xs mt-2">{@upload_error}</div>
          <% end %>
        </div>
      <% end %>

      <%!-- List --%>
      <div class="bg-base-100 rounded-lg shadow-sm border border-base-200 overflow-hidden">
        <%= if @pdfs == [] do %>
          <div class="text-center py-12 text-base-content/60">
            <.icon name="hero-document-text" class="w-12 h-12 mx-auto mb-2 opacity-50" />
            <p>
              <%= if @filter == "trashed" do %>
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Trash is empty.")}
              <% else %>
                {Gettext.gettext(PhoenixKitWeb.Gettext, "No PDFs uploaded yet.")}
              <% end %>
            </p>
          </div>
        <% else %>
          <table class="table table-sm">
            <thead class="text-xs uppercase text-base-content/60">
              <tr>
                <th>{Gettext.gettext(PhoenixKitWeb.Gettext, "Filename")}</th>
                <th>{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</th>
                <th>{Gettext.gettext(PhoenixKitWeb.Gettext, "Pages")}</th>
                <th>{Gettext.gettext(PhoenixKitWeb.Gettext, "Size")}</th>
                <th>
                  <%= if @filter == "trashed" do %>
                    {Gettext.gettext(PhoenixKitWeb.Gettext, "Trashed")}
                  <% else %>
                    {Gettext.gettext(PhoenixKitWeb.Gettext, "Uploaded")}
                  <% end %>
                </th>
                <th class="text-right">
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}
                </th>
              </tr>
            </thead>
            <tbody>
              <%= for pdf <- @pdfs do %>
                <tr id={"pdf-row-#{pdf.uuid}"}>
                  <td class="font-medium">
                    <.link navigate={Paths.pdf_detail(pdf.uuid)} class="link link-hover">
                      {pdf.original_filename}
                    </.link>
                  </td>
                  <td>
                    {extraction_badge(pdf)}
                  </td>
                  <td>
                    {extraction_pages(pdf)}
                  </td>
                  <td class="text-base-content/60">{format_size(pdf.byte_size)}</td>
                  <td class="text-base-content/60 text-xs">
                    {format_time_ago(timestamp_for_filter(pdf, @filter))}
                  </td>
                  <td class="text-right">
                    <%= if @filter == "trashed" do %>
                      <button
                        type="button"
                        phx-click="restore"
                        phx-value-uuid={pdf.uuid}
                        class="btn btn-ghost btn-xs"
                      >
                        <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
                      </button>
                      <button
                        type="button"
                        phx-click="permanently_delete"
                        phx-value-uuid={pdf.uuid}
                        data-confirm={
                          Gettext.gettext(
                            PhoenixKitWeb.Gettext,
                            "Permanently delete this PDF? If no other library entry references the same file content, the underlying file will be queued for hard deletion."
                          )
                        }
                        class="btn btn-ghost btn-xs text-error"
                      >
                        <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                      </button>
                    <% else %>
                      <button
                        type="button"
                        phx-click="trash"
                        phx-value-uuid={pdf.uuid}
                        data-confirm={
                          Gettext.gettext(
                            PhoenixKitWeb.Gettext,
                            "Move this PDF to trash?"
                          )
                        }
                        class="btn btn-ghost btn-xs text-error"
                      >
                        <.icon name="hero-trash" class="w-3.5 h-3.5" />
                      </button>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp extraction_badge(pdf) do
    case extraction_status(pdf) do
      "extracted" ->
        Phoenix.HTML.raw(
          ~s|<span class="badge badge-sm badge-success">| <>
            Gettext.gettext(PhoenixKitWeb.Gettext, "Extracted") <> "</span>"
        )

      "scanned_no_text" ->
        Phoenix.HTML.raw(
          ~s|<span class="badge badge-sm badge-warning">| <>
            Gettext.gettext(PhoenixKitWeb.Gettext, "Scanned (no text)") <> "</span>"
        )

      "extracting" ->
        Phoenix.HTML.raw(
          ~s|<span class="badge badge-sm badge-info">| <>
            Gettext.gettext(PhoenixKitWeb.Gettext, "Extracting") <> "</span>"
        )

      "failed" ->
        msg = (pdf.extraction && pdf.extraction.error_message) || ""

        Phoenix.HTML.raw(
          ~s|<span class="badge badge-sm badge-error" title="#{escape_html(msg)}">| <>
            Gettext.gettext(PhoenixKitWeb.Gettext, "Failed") <> "</span>"
        )

      _ ->
        Phoenix.HTML.raw(
          ~s|<span class="badge badge-sm badge-ghost">| <>
            Gettext.gettext(PhoenixKitWeb.Gettext, "Pending") <> "</span>"
        )
    end
  end

  defp extraction_status(%{extraction: %{extraction_status: s}}) when is_binary(s), do: s
  defp extraction_status(_), do: "pending"

  defp extraction_pages(%{extraction: %{page_count: n}}) when is_integer(n), do: to_string(n)
  defp extraction_pages(_), do: "—"

  defp escape_html(s), do: s |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp timestamp_for_filter(pdf, "trashed"), do: pdf.trashed_at || pdf.inserted_at
  defp timestamp_for_filter(pdf, _), do: pdf.inserted_at

  defp format_size(nil), do: "—"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)} KB"
  defp format_size(bytes) when bytes < 1024 * 1024 * 1024, do: "#{div(bytes, 1024 * 1024)} MB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"

  defp format_time_ago(nil), do: "—"

  defp format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> Gettext.gettext(PhoenixKitWeb.Gettext, "just now")
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end

  defp format_upload_error(:too_large),
    do: Gettext.gettext(PhoenixKitWeb.Gettext, "File is too large.")

  defp format_upload_error(:not_accepted),
    do: Gettext.gettext(PhoenixKitWeb.Gettext, "Only PDF files are accepted.")

  defp format_upload_error(:too_many_files),
    do: Gettext.gettext(PhoenixKitWeb.Gettext, "Too many files at once.")

  defp format_upload_error(other), do: inspect(other)
end
