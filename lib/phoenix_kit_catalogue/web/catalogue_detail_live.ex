defmodule PhoenixKitCatalogue.Web.CatalogueDetailLive do
  @moduledoc "Detail view for a single catalogue with categories and items."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.Badge, only: [status_badge: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    socket =
      assign(socket,
        page_title: "Loading...",
        catalogue_uuid: uuid,
        catalogue: nil,
        uncategorized_items: [],
        confirm_delete: nil,
        view_mode: "active",
        deleted_count: 0,
        search_query: "",
        search_results: nil
      )

    if connected?(socket) do
      try do
        {:ok, load_catalogue_data(socket)}
      rescue
        Ecto.NoResultsError ->
          Logger.warning("Catalogue not found: #{uuid}")

          {:ok,
           socket |> put_flash(:error, "Catalogue not found.") |> push_navigate(to: Paths.index())}
      end
    else
      {:ok, socket}
    end
  end

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket) when mode in ~w(active deleted) do
    {:noreply,
     socket
     |> assign(:view_mode, mode)
     |> assign(:confirm_delete, nil)
     |> load_catalogue_data()}
  end

  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, search_query: "", search_results: nil)}
    else
      results =
        Catalogue.search_items_in_catalogue(socket.assigns.catalogue_uuid, query)

      {:noreply, assign(socket, search_query: query, search_results: results)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, search_query: "", search_results: nil)}
  end

  def handle_event("delete_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.trash_item(item) do
      {:noreply, socket |> put_flash(:info, "Item moved to deleted.") |> load_catalogue_data()}
    else
      nil ->
        {:noreply, socket |> put_flash(:error, "Item not found.") |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to trash item #{uuid}: #{inspect(reason)}")
        {:noreply, socket |> put_flash(:error, "Failed to delete item.") |> load_catalogue_data()}
    end
  end

  def handle_event("restore_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.restore_item(item) do
      {:noreply, socket |> put_flash(:info, "Item restored.") |> load_catalogue_data()}
    else
      nil ->
        {:noreply, socket |> put_flash(:error, "Item not found.") |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to restore item #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket |> put_flash(:error, "Failed to restore item.") |> load_catalogue_data()}
    end
  end

  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
  end

  def handle_event("permanently_delete_item", _params, socket) do
    {"item", uuid} = socket.assigns.confirm_delete

    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.permanently_delete_item(item) do
      {:noreply,
       socket
       |> assign(:confirm_delete, nil)
       |> put_flash(:info, "Item permanently deleted.")
       |> load_catalogue_data()}
    else
      nil ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, "Item not found.")
         |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to permanently delete item #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, "Failed to delete item.")
         |> load_catalogue_data()}
    end
  end

  def handle_event("trash_category", %{"uuid" => uuid}, socket) do
    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.trash_category(category) do
      {:noreply,
       socket |> put_flash(:info, "Category moved to deleted.") |> load_catalogue_data()}
    else
      nil ->
        {:noreply, socket |> put_flash(:error, "Category not found.") |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to trash category #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket |> put_flash(:error, "Failed to delete category.") |> load_catalogue_data()}
    end
  end

  def handle_event("restore_category", %{"uuid" => uuid}, socket) do
    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.restore_category(category) do
      {:noreply, socket |> put_flash(:info, "Category restored.") |> load_catalogue_data()}
    else
      nil ->
        {:noreply, socket |> put_flash(:error, "Category not found.") |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to restore category #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket |> put_flash(:error, "Failed to restore category.") |> load_catalogue_data()}
    end
  end

  def handle_event("permanently_delete_category", _params, socket) do
    {"category", uuid} = socket.assigns.confirm_delete

    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.permanently_delete_category(category) do
      {:noreply,
       socket
       |> assign(:confirm_delete, nil)
       |> put_flash(:info, "Category permanently deleted.")
       |> load_catalogue_data()}
    else
      nil ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, "Category not found.")
         |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to permanently delete category #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, "Failed to delete category.")
         |> load_catalogue_data()}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event("move_category_up", %{"uuid" => uuid}, socket) do
    reorder_category(socket, uuid, :up)
  end

  def handle_event("move_category_down", %{"uuid" => uuid}, socket) do
    reorder_category(socket, uuid, :down)
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp load_catalogue_data(socket) do
    uuid = socket.assigns.catalogue_uuid
    deleted_count = Catalogue.deleted_count_for_catalogue(uuid)

    # Auto-switch to active if no deleted items remain
    view_mode =
      if deleted_count == 0 and socket.assigns.view_mode == "deleted",
        do: "active",
        else: socket.assigns.view_mode

    mode = view_mode_to_atom(view_mode)
    catalogue = Catalogue.get_catalogue!(uuid, mode: mode)
    uncategorized = Catalogue.list_uncategorized_items(mode: mode)

    assign(socket,
      page_title: catalogue.name,
      catalogue: catalogue,
      uncategorized_items: uncategorized,
      deleted_count: deleted_count,
      view_mode: view_mode
    )
  end

  defp view_mode_to_atom("active"), do: :active
  defp view_mode_to_atom("deleted"), do: :deleted

  defp reorder_category(socket, uuid, direction) do
    categories = socket.assigns.catalogue.categories
    index = Enum.find_index(categories, &(&1.uuid == uuid))

    swap_index =
      case direction do
        :up -> max(index - 1, 0)
        :down -> min(index + 1, length(categories) - 1)
      end

    if index != swap_index do
      cat_a = Enum.at(categories, index)
      cat_b = Enum.at(categories, swap_index)

      case Catalogue.swap_category_positions(cat_a, cat_b) do
        {:ok, _} -> {:noreply, load_catalogue_data(socket)}
        {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to reorder categories.")}
      end
    else
      {:noreply, socket}
    end
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Loading state --%>
      <div :if={is_nil(@catalogue)} class="flex justify-center py-12">
        <span class="loading loading-spinner loading-lg"></span>
      </div>

      <div :if={@catalogue} class="flex flex-col gap-6">
        <%!-- Header --%>
        <.admin_page_header back={Paths.index()} title={@catalogue.name}>
          <:actions :if={@view_mode == "active"}>
            <.link navigate={Paths.category_new(@catalogue.uuid)} class="btn btn-outline btn-sm">
              <.icon name="hero-folder-plus" class="w-4 h-4" /> Add Category
            </.link>
            <.link navigate={Paths.item_new(@catalogue.uuid)} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> Add Item
            </.link>
            <.link navigate={Paths.catalogue_edit(@catalogue.uuid)} class="btn btn-ghost btn-sm">
              Edit
            </.link>
          </:actions>
        </.admin_page_header>

        <div :if={@catalogue.description || Decimal.gt?(@catalogue.markup_percentage, Decimal.new("0"))} class="-mt-4">
          <p :if={@catalogue.description} class="text-base-content/60">
            {@catalogue.description}
          </p>
          <p :if={Decimal.gt?(@catalogue.markup_percentage, Decimal.new("0"))} class="text-sm text-base-content/50 mt-0.5">
            Markup: {Decimal.to_string(@catalogue.markup_percentage, :normal)}%
          </p>
        </div>

        <%!-- Search --%>
        <div :if={@view_mode == "active"} class="flex gap-2">
          <form phx-change="search" phx-submit="search" class="flex-1 relative">
            <input
              type="text"
              name="query"
              value={@search_query}
              placeholder="Search items by name, description, or SKU..."
              class="input input-bordered input-sm w-full pr-8"
              phx-debounce="300"
              autocomplete="off"
            />
            <button
              :if={@search_query != ""}
              type="button"
              phx-click="clear_search"
              class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-base-content cursor-pointer"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </form>
        </div>

        <%!-- Search results --%>
        <div :if={@search_results != nil} class="flex flex-col gap-4">
          <div class="flex items-center justify-between">
            <span class="text-sm text-base-content/60">
              {length(@search_results)} result{if length(@search_results) != 1, do: "s"} for "{@search_query}"
            </span>
          </div>

          <div :if={@search_results == []} class="card bg-base-100 shadow">
            <div class="card-body items-center text-center py-8">
              <p class="text-base-content/60">No items match your search.</p>
            </div>
          </div>

          <div :if={@search_results != []} class="card bg-base-100 shadow">
            <div class="card-body">
              <.items_table items={@search_results} view_mode="active" markup_percentage={@catalogue.markup_percentage} wrapper_class="overflow-x-auto shadow-none rounded-none" />
            </div>
          </div>
        </div>

        <%!-- Status tabs --%>
        <div :if={@deleted_count > 0 and is_nil(@search_results)} class="flex items-center gap-0.5 border-b border-base-200">
          <button
            type="button"
            phx-click="switch_view"
            phx-value-mode="active"
            class={[
              "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer",
              if(@view_mode == "active",
                do: "border-primary text-primary",
                else: "border-transparent text-base-content/50 hover:text-base-content"
              )
            ]}
          >
            Active
          </button>
          <button
            type="button"
            phx-click="switch_view"
            phx-value-mode="deleted"
            class={[
              "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer",
              if(@view_mode == "deleted",
                do: "border-error text-error",
                else: "border-transparent text-base-content/50 hover:text-base-content"
              )
            ]}
          >
            Deleted ({@deleted_count})
          </button>
        </div>

        <%!-- Normal view (hidden during search) --%>
        <%!-- Empty state --%>
        <div :if={is_nil(@search_results) and @catalogue.categories == [] and @uncategorized_items == [] and @view_mode == "active"} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">No categories or items yet. Add a category or item to get started.</p>
          </div>
        </div>

        <div :if={is_nil(@search_results) and @catalogue.categories == [] and @uncategorized_items == [] and @view_mode == "deleted"} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">No deleted items.</p>
          </div>
        </div>

        <%!-- Categories with items --%>
        <%= for category <- @catalogue.categories, is_nil(@search_results) do %>
          <%!-- In deleted mode, hide active categories with no deleted items --%>
          <div :if={@view_mode == "active" or category.status == "deleted" or category.items != []} class="card bg-base-100 shadow">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <div :if={length(@catalogue.categories) > 1 && @view_mode == "active"} class="flex flex-col">
                    <button
                      phx-click="move_category_up"
                      phx-value-uuid={category.uuid}
                      class="btn btn-ghost btn-xs btn-square"
                      title="Move up"
                    >
                      <.icon name="hero-chevron-up" class="w-3 h-3" />
                    </button>
                    <button
                      phx-click="move_category_down"
                      phx-value-uuid={category.uuid}
                      class="btn btn-ghost btn-xs btn-square"
                      title="Move down"
                    >
                      <.icon name="hero-chevron-down" class="w-3 h-3" />
                    </button>
                  </div>
                  <h3 class={["card-title text-lg", category.status == "deleted" && "text-error/70"]}>{category.name}</h3>
                  <span :if={category.status == "deleted"} class="badge badge-error badge-xs">deleted</span>
                  <span class="badge badge-ghost badge-sm">{length(category.items)} items</span>

                </div>

                <%!-- Active mode: Edit + Delete --%>
                <div :if={@view_mode == "active"} class="flex gap-1">
                  <.link navigate={Paths.category_edit(category.uuid)} class="btn btn-ghost btn-xs">
                    Edit
                  </.link>
                  <button phx-click="trash_category" phx-value-uuid={category.uuid} class="btn btn-ghost btn-xs text-error">
                    Delete
                  </button>
                </div>

                <%!-- Deleted mode: Restore + Permanent Delete (for deleted categories) --%>
                <div :if={@view_mode == "deleted" && category.status == "deleted"} class="flex gap-1">
                  <button
                    phx-click="restore_category"
                    phx-value-uuid={category.uuid}
                    class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-success/30 bg-success/10 hover:bg-success/20 text-success text-xs font-medium transition-colors cursor-pointer"
                  >
                    Restore
                  </button>
                  <button
                    phx-click="show_delete_confirm"
                    phx-value-uuid={category.uuid}
                    phx-value-type="category"
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Delete Forever
                  </button>
                </div>
              </div>

              <p :if={category.description && @view_mode == "active"} class="text-sm text-base-content/60">
                {category.description}
              </p>

              <%!-- Items table --%>
              <div :if={category.items != []} class="mt-2">
                <.items_table items={category.items} view_mode={@view_mode} markup_percentage={@catalogue.markup_percentage} wrapper_class="overflow-x-auto shadow-none rounded-none" />
              </div>

              <p :if={category.items == [] and @view_mode == "active"} class="text-sm text-base-content/40 text-center py-4">
                No items in this category.
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Uncategorized items --%>
        <div :if={is_nil(@search_results) and @uncategorized_items != []} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-center gap-2">
              <h3 class="card-title text-lg text-base-content/70">Uncategorized</h3>
              <span class="badge badge-ghost badge-sm">{length(@uncategorized_items)} items</span>
            </div>

            <div class="overflow-x-auto mt-2">
              <.items_table items={@uncategorized_items} view_mode={@view_mode} markup_percentage={@catalogue.markup_percentage} />
            </div>
          </div>
        </div>
      </div>

      <.confirm_modal
        show={match?({"item", _}, @confirm_delete)}
        on_confirm="permanently_delete_item"
        on_cancel="cancel_delete"
        title="Permanently Delete Item"
        title_icon="hero-trash"
        messages={[{:warning, "This item will be permanently deleted. This cannot be undone."}]}
        confirm_text="Delete Forever"
        danger={true}
      />

      <.confirm_modal
        show={match?({"category", _}, @confirm_delete)}
        on_confirm="permanently_delete_category"
        on_cancel="cancel_delete"
        title="Permanently Delete Category"
        title_icon="hero-trash"
        messages={[{:warning, "This category and all its items will be permanently deleted. This cannot be undone."}]}
        confirm_text="Delete Forever"
        danger={true}
      />
    </div>
    """
  end

  defp items_table(assigns) do
    ~H"""
    <.table_default size="sm" wrapper_class={assigns[:wrapper_class]}>
      <.table_default_header>
        <.table_default_row>
          <.table_default_header_cell>Name</.table_default_header_cell>
          <.table_default_header_cell>SKU</.table_default_header_cell>
          <.table_default_header_cell>Base Price</.table_default_header_cell>
          <.table_default_header_cell>Price</.table_default_header_cell>
          <.table_default_header_cell>Unit</.table_default_header_cell>
          <.table_default_header_cell>Status</.table_default_header_cell>
          <.table_default_header_cell class="text-right">Actions</.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.table_default_body>
        <.table_default_row :for={item <- @items}>
          <.table_default_cell class="font-medium">{item.name}</.table_default_cell>
          <.table_default_cell class="text-sm font-mono text-base-content/60">{item.sku || "—"}</.table_default_cell>
          <.table_default_cell class="text-sm">{format_price(item.base_price)}</.table_default_cell>
          <.table_default_cell class="text-sm font-semibold">{format_price(PhoenixKitCatalogue.Schemas.Item.sale_price(item, @markup_percentage))}</.table_default_cell>
          <.table_default_cell class="text-sm">{format_unit(item.unit)}</.table_default_cell>
          <.table_default_cell><.status_badge status={item.status} size={:xs} /></.table_default_cell>
          <%!-- Active mode actions --%>
          <.table_default_cell :if={@view_mode == "active"} class="text-right">
            <.table_row_menu id={"item-menu-#{item.uuid}"}>
              <.table_row_menu_link navigate={Paths.item_edit(item.uuid)} icon="hero-pencil" label="Edit" />
              <.table_row_menu_divider />
              <.table_row_menu_button phx-click="delete_item" phx-value-uuid={item.uuid} icon="hero-trash" label="Delete" variant="error" />
            </.table_row_menu>
          </.table_default_cell>
          <%!-- Deleted mode actions --%>
          <.table_default_cell :if={@view_mode == "deleted"} class="text-right">
            <.table_row_menu id={"item-del-menu-#{item.uuid}"}>
              <.table_row_menu_button phx-click="restore_item" phx-value-uuid={item.uuid} icon="hero-arrow-path" label="Restore" variant="success" />
              <.table_row_menu_divider />
              <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={item.uuid} phx-value-type="item" icon="hero-trash" label="Delete Forever" variant="error" />
            </.table_row_menu>
          </.table_default_cell>
        </.table_default_row>
      </.table_default_body>
    </.table_default>
    """
  end

  defp format_price(nil), do: "—"
  defp format_price(price), do: Decimal.to_string(price, :normal)

  defp format_unit("piece"), do: "pc"
  defp format_unit("m2"), do: "m²"
  defp format_unit("running_meter"), do: "rm"
  defp format_unit(other), do: other
end
