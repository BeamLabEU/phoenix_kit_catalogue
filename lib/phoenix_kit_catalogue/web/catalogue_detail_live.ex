defmodule PhoenixKitCatalogue.Web.CatalogueDetailLive do
  @moduledoc "Detail view for a single catalogue with categories and items."

  use Phoenix.LiveView

  require Logger

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
        deleted_count: 0
      )

    if connected?(socket) do
      try do
        {:ok, load_catalogue_data(socket)}
      rescue
        Ecto.NoResultsError ->
          Logger.warning("Catalogue not found: #{uuid}")
          {:ok, socket |> put_flash(:error, "Catalogue not found.") |> push_navigate(to: Paths.index())}
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

  def handle_event("delete_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.trash_item(item) do
      {:noreply, socket |> put_flash(:info, "Item moved to deleted.") |> load_catalogue_data()}
    else
      nil -> {:noreply, socket |> put_flash(:error, "Item not found.") |> load_catalogue_data()}
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
      nil -> {:noreply, socket |> put_flash(:error, "Item not found.") |> load_catalogue_data()}
      {:error, reason} ->
        Logger.error("Failed to restore item #{uuid}: #{inspect(reason)}")
        {:noreply, socket |> put_flash(:error, "Failed to restore item.") |> load_catalogue_data()}
    end
  end

  def handle_event("permanently_delete_item", %{"uuid" => uuid}, socket) do
    if socket.assigns.confirm_delete == {:permanent, uuid} do
      with %{} = item <- Catalogue.get_item(uuid),
           {:ok, _} <- Catalogue.permanently_delete_item(item) do
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:info, "Item permanently deleted.")
         |> load_catalogue_data()}
      else
        nil ->
          {:noreply, socket |> assign(:confirm_delete, nil) |> put_flash(:error, "Item not found.") |> load_catalogue_data()}
        {:error, reason} ->
          Logger.error("Failed to permanently delete item #{uuid}: #{inspect(reason)}")
          {:noreply, socket |> assign(:confirm_delete, nil) |> put_flash(:error, "Failed to delete item.") |> load_catalogue_data()}
      end
    else
      {:noreply, assign(socket, :confirm_delete, {:permanent, uuid})}
    end
  end

  def handle_event("trash_category", %{"uuid" => uuid}, socket) do
    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.trash_category(category) do
      {:noreply, socket |> put_flash(:info, "Category moved to deleted.") |> load_catalogue_data()}
    else
      nil -> {:noreply, socket |> put_flash(:error, "Category not found.") |> load_catalogue_data()}
      {:error, reason} ->
        Logger.error("Failed to trash category #{uuid}: #{inspect(reason)}")
        {:noreply, socket |> put_flash(:error, "Failed to delete category.") |> load_catalogue_data()}
    end
  end

  def handle_event("restore_category", %{"uuid" => uuid}, socket) do
    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.restore_category(category) do
      {:noreply, socket |> put_flash(:info, "Category restored.") |> load_catalogue_data()}
    else
      nil -> {:noreply, socket |> put_flash(:error, "Category not found.") |> load_catalogue_data()}
      {:error, reason} ->
        Logger.error("Failed to restore category #{uuid}: #{inspect(reason)}")
        {:noreply, socket |> put_flash(:error, "Failed to restore category.") |> load_catalogue_data()}
    end
  end

  def handle_event("permanently_delete_category", %{"uuid" => uuid}, socket) do
    if socket.assigns.confirm_delete == {:permanent_cat, uuid} do
      with %{} = category <- Catalogue.get_category(uuid),
           {:ok, _} <- Catalogue.permanently_delete_category(category) do
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:info, "Category permanently deleted.")
         |> load_catalogue_data()}
      else
        nil ->
          {:noreply, socket |> assign(:confirm_delete, nil) |> put_flash(:error, "Category not found.") |> load_catalogue_data()}
        {:error, reason} ->
          Logger.error("Failed to permanently delete category #{uuid}: #{inspect(reason)}")
          {:noreply, socket |> assign(:confirm_delete, nil) |> put_flash(:error, "Failed to delete category.") |> load_catalogue_data()}
      end
    else
      {:noreply, assign(socket, :confirm_delete, {:permanent_cat, uuid})}
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
    uncategorized = Catalogue.list_uncategorized_items_for_catalogue(uuid, mode: mode)

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
      Catalogue.update_category(cat_a, %{position: cat_b.position})
      Catalogue.update_category(cat_b, %{position: cat_a.position})
      {:noreply, load_catalogue_data(socket)}
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
        <div class="flex items-start justify-between">
          <div>
            <div class="flex items-center gap-2">
              <.link navigate={Paths.index()} class="btn btn-ghost btn-sm btn-square">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
                </svg>
              </.link>
              <h1 class="text-2xl font-bold">{@catalogue.name}</h1>
              <span class={["badge badge-sm", status_badge(@catalogue.status)]}>
                {@catalogue.status}
              </span>
            </div>
            <p :if={@catalogue.description} class="text-base-content/60 mt-1 ml-10">
              {@catalogue.description}
            </p>
          </div>

          <div :if={@view_mode == "active"} class="flex gap-2">
            <.link navigate={Paths.category_new(@catalogue.uuid)} class="btn btn-outline btn-sm">
              Add Category
            </.link>
            <.link navigate={Paths.item_new(@catalogue.uuid)} class="btn btn-primary btn-sm">
              Add Item
            </.link>
            <.link navigate={Paths.catalogue_edit(@catalogue.uuid)} class="btn btn-ghost btn-sm">
              Edit
            </.link>
          </div>
        </div>

        <%!-- Status tabs --%>
        <div :if={@deleted_count > 0} class="flex items-center gap-0.5 border-b border-base-200">
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

        <%!-- Empty state --%>
        <div :if={@catalogue.categories == [] and @uncategorized_items == [] and @view_mode == "active"} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">No categories or items yet. Add a category or item to get started.</p>
          </div>
        </div>

        <div :if={@catalogue.categories == [] and @uncategorized_items == [] and @view_mode == "deleted"} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">No deleted items.</p>
          </div>
        </div>

        <%!-- Categories with items --%>
        <%= for category <- @catalogue.categories do %>
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
                      <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 15l7-7 7 7" />
                      </svg>
                    </button>
                    <button
                      phx-click="move_category_down"
                      phx-value-uuid={category.uuid}
                      class="btn btn-ghost btn-xs btn-square"
                      title="Move down"
                    >
                      <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
                      </svg>
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
                    :if={@confirm_delete != {:permanent_cat, category.uuid}}
                    phx-click="permanently_delete_category"
                    phx-value-uuid={category.uuid}
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Delete Forever
                  </button>
                  <span :if={@confirm_delete == {:permanent_cat, category.uuid}} class="inline-flex gap-1">
                    <button phx-click="permanently_delete_category" phx-value-uuid={category.uuid} class="btn btn-error btn-xs">
                      Confirm
                    </button>
                    <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">Cancel</button>
                  </span>
                </div>
              </div>

              <p :if={category.description && @view_mode == "active"} class="text-sm text-base-content/60">
                {category.description}
              </p>

              <%!-- Items table --%>
              <div :if={category.items != []} class="overflow-x-auto mt-2">
                <.items_table items={category.items} view_mode={@view_mode} confirm_delete={@confirm_delete} />
              </div>

              <p :if={category.items == [] and @view_mode == "active"} class="text-sm text-base-content/40 text-center py-4">
                No items in this category.
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Uncategorized items --%>
        <div :if={@uncategorized_items != []} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-center gap-2">
              <h3 class="card-title text-lg text-base-content/70">Uncategorized</h3>
              <span class="badge badge-ghost badge-sm">{length(@uncategorized_items)} items</span>
            </div>

            <div class="overflow-x-auto mt-2">
              <.items_table items={@uncategorized_items} view_mode={@view_mode} confirm_delete={@confirm_delete} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp items_table(assigns) do
    ~H"""
    <table class="table table-sm">
      <thead>
        <tr>
          <th>Name</th>
          <th>SKU</th>
          <th>Price</th>
          <th>Unit</th>
          <th>Status</th>
          <th class="text-right">Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={item <- @items}>
          <td class="font-medium">{item.name}</td>
          <td class="text-sm font-mono text-base-content/60">{item.sku || "—"}</td>
          <td class="text-sm">{format_price(item.price)}</td>
          <td class="text-sm">{format_unit(item.unit)}</td>
          <td>
            <span class={["badge badge-xs", item_status_badge(item.status)]}>
              {item.status}
            </span>
          </td>
          <%!-- Active mode actions --%>
          <td :if={@view_mode == "active"} class="text-right">
            <.link navigate={Paths.item_edit(item.uuid)} class="btn btn-ghost btn-xs">
              Edit
            </.link>
            <button
              phx-click="delete_item"
              phx-value-uuid={item.uuid}
              class="btn btn-ghost btn-xs text-error"
            >
              Delete
            </button>
          </td>
          <%!-- Deleted mode actions --%>
          <td :if={@view_mode == "deleted"} class="text-right">
            <button
              phx-click="restore_item"
              phx-value-uuid={item.uuid}
              class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-success/30 bg-success/10 hover:bg-success/20 text-success text-xs font-medium transition-colors cursor-pointer"
            >
              Restore
            </button>
            <button
              :if={@confirm_delete != {:permanent, item.uuid}}
              phx-click="permanently_delete_item"
              phx-value-uuid={item.uuid}
              class="btn btn-ghost btn-xs text-error"
            >
              Delete Forever
            </button>
            <span :if={@confirm_delete == {:permanent, item.uuid}} class="inline-flex gap-1">
              <button phx-click="permanently_delete_item" phx-value-uuid={item.uuid} class="btn btn-error btn-xs">
                Confirm
              </button>
              <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">Cancel</button>
            </span>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp status_badge("active"), do: "badge-success"
  defp status_badge("archived"), do: "badge-warning"
  defp status_badge(_), do: "badge-ghost"

  defp item_status_badge("active"), do: "badge-success"
  defp item_status_badge("inactive"), do: "badge-ghost"
  defp item_status_badge("discontinued"), do: "badge-warning"
  defp item_status_badge("deleted"), do: "badge-error"
  defp item_status_badge(_), do: "badge-ghost"

  defp format_price(nil), do: "—"
  defp format_price(price), do: Decimal.to_string(price, :normal)

  defp format_unit("piece"), do: "pc"
  defp format_unit("m2"), do: "m²"
  defp format_unit("running_meter"), do: "rm"
  defp format_unit(other), do: other
end
