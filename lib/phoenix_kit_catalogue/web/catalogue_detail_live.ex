defmodule PhoenixKitCatalogue.Web.CatalogueDetailLive do
  @moduledoc "Detail view for a single catalogue with categories and items."

  use Phoenix.LiveView

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    if connected?(socket) do
      catalogue = Catalogue.get_catalogue!(uuid)

      {:ok,
       assign(socket,
         page_title: catalogue.name,
         catalogue: catalogue,
         confirm_delete: nil
       )}
    else
      {:ok,
       assign(socket,
         page_title: "Loading...",
         catalogue: nil,
         confirm_delete: nil
       )}
    end
  end

  @impl true
  def handle_event("delete_category", %{"uuid" => uuid}, socket) do
    if socket.assigns.confirm_delete == {:category, uuid} do
      category = Catalogue.get_category(uuid)

      if category do
        {:ok, _} = Catalogue.delete_category(category)
        catalogue = Catalogue.get_catalogue!(socket.assigns.catalogue.uuid)
        {:noreply, assign(socket, catalogue: catalogue, confirm_delete: nil)}
      else
        {:noreply, assign(socket, :confirm_delete, nil)}
      end
    else
      {:noreply, assign(socket, :confirm_delete, {:category, uuid})}
    end
  end

  def handle_event("delete_item", %{"uuid" => uuid}, socket) do
    if socket.assigns.confirm_delete == {:item, uuid} do
      item = Catalogue.get_item(uuid)

      if item do
        {:ok, _} = Catalogue.delete_item(item)
        catalogue = Catalogue.get_catalogue!(socket.assigns.catalogue.uuid)
        {:noreply, assign(socket, catalogue: catalogue, confirm_delete: nil)}
      else
        {:noreply, assign(socket, :confirm_delete, nil)}
      end
    else
      {:noreply, assign(socket, :confirm_delete, {:item, uuid})}
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
      catalogue = Catalogue.get_catalogue!(socket.assigns.catalogue.uuid)
      {:noreply, assign(socket, :catalogue, catalogue)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Loading state --%>
      <div :if={is_nil(@catalogue)} class="flex justify-center py-12">
        <span class="loading loading-spinner loading-lg"></span>
      </div>

      <div :if={@catalogue}>
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

          <div class="flex gap-2">
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

        <%!-- Empty state --%>
        <div :if={@catalogue.categories == []} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">No categories yet. Add a category to get started.</p>
          </div>
        </div>

        <%!-- Categories with items --%>
        <div :for={category <- @catalogue.categories} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <div class="flex flex-col">
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
                <h3 class="card-title text-lg">{category.name}</h3>
                <span class="badge badge-ghost badge-sm">{length(category.items)} items</span>
              </div>

              <div class="flex gap-1">
                <.link navigate={Paths.category_edit(category.uuid)} class="btn btn-ghost btn-xs">
                  Edit
                </.link>
                <button
                  :if={@confirm_delete != {:category, category.uuid}}
                  phx-click="delete_category"
                  phx-value-uuid={category.uuid}
                  class="btn btn-ghost btn-xs text-error"
                >
                  Delete
                </button>
                <span :if={@confirm_delete == {:category, category.uuid}} class="inline-flex gap-1">
                  <button phx-click="delete_category" phx-value-uuid={category.uuid} class="btn btn-error btn-xs">
                    Confirm
                  </button>
                  <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">Cancel</button>
                </span>
              </div>
            </div>

            <p :if={category.description} class="text-sm text-base-content/60">
              {category.description}
            </p>

            <%!-- Items table --%>
            <div :if={category.items != []} class="overflow-x-auto mt-2">
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
                  <tr :for={item <- category.items}>
                    <td class="font-medium">{item.name}</td>
                    <td class="text-sm font-mono text-base-content/60">{item.sku || "—"}</td>
                    <td class="text-sm">{format_price(item.price)}</td>
                    <td class="text-sm">{format_unit(item.unit)}</td>
                    <td>
                      <span class={["badge badge-xs", item_status_badge(item.status)]}>
                        {item.status}
                      </span>
                    </td>
                    <td class="text-right">
                      <.link navigate={Paths.item_edit(item.uuid)} class="btn btn-ghost btn-xs">
                        Edit
                      </.link>
                      <button
                        :if={@confirm_delete != {:item, item.uuid}}
                        phx-click="delete_item"
                        phx-value-uuid={item.uuid}
                        class="btn btn-ghost btn-xs text-error"
                      >
                        Delete
                      </button>
                      <span :if={@confirm_delete == {:item, item.uuid}} class="inline-flex gap-1">
                        <button phx-click="delete_item" phx-value-uuid={item.uuid} class="btn btn-error btn-xs">
                          Confirm
                        </button>
                        <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">Cancel</button>
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p :if={category.items == []} class="text-sm text-base-content/40 text-center py-4">
              No items in this category.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp status_badge("active"), do: "badge-success"
  defp status_badge("archived"), do: "badge-warning"
  defp status_badge(_), do: "badge-ghost"

  defp item_status_badge("active"), do: "badge-success"
  defp item_status_badge("inactive"), do: "badge-ghost"
  defp item_status_badge("discontinued"), do: "badge-error"
  defp item_status_badge(_), do: "badge-ghost"

  defp format_price(nil), do: "—"
  defp format_price(price), do: Decimal.to_string(price, :normal)

  defp format_unit("piece"), do: "pc"
  defp format_unit("m2"), do: "m²"
  defp format_unit("running_meter"), do: "rm"
  defp format_unit(other), do: other
end
