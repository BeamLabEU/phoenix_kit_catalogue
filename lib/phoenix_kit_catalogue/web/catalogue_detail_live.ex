defmodule PhoenixKitCatalogue.Web.CatalogueDetailLive do
  @moduledoc "Detail view for a single catalogue with categories and items."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitCatalogue.Web.Components

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    socket =
      assign(socket,
        page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "Loading..."),
        catalogue_uuid: uuid,
        catalogue: nil,
        uncategorized_items: [],
        confirm_delete: nil,
        view_mode: "active",
        deleted_count: 0,
        active_item_count: 0,
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
           socket
           |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue not found."))
           |> push_navigate(to: Paths.index())}
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
         {:ok, _} <- Catalogue.trash_item(item, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Item moved to deleted."))
       |> load_catalogue_data()}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Item not found."))
         |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to trash item #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete item."))
         |> load_catalogue_data()}
    end
  end

  def handle_event("restore_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.restore_item(item, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Item restored."))
       |> load_catalogue_data()}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Item not found."))
         |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to restore item #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to restore item."))
         |> load_catalogue_data()}
    end
  end

  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
  end

  def handle_event("permanently_delete_item", _params, socket) do
    {"item", uuid} = confirm_delete!(socket)

    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.permanently_delete_item(item, actor_opts(socket)) do
      {:noreply,
       socket
       |> assign(:confirm_delete, nil)
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Item permanently deleted."))
       |> load_catalogue_data()}
    else
      nil ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Item not found."))
         |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to permanently delete item #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete item."))
         |> load_catalogue_data()}
    end
  end

  def handle_event("trash_category", %{"uuid" => uuid}, socket) do
    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.trash_category(category, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Category moved to deleted."))
       |> load_catalogue_data()}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Category not found."))
         |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to trash category #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete category.")
         )
         |> load_catalogue_data()}
    end
  end

  def handle_event("restore_category", %{"uuid" => uuid}, socket) do
    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.restore_category(category, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Category restored."))
       |> load_catalogue_data()}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Category not found."))
         |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to restore category #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to restore category.")
         )
         |> load_catalogue_data()}
    end
  end

  def handle_event("permanently_delete_category", _params, socket) do
    {"category", uuid} = confirm_delete!(socket)

    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.permanently_delete_category(category, actor_opts(socket)) do
      {:noreply,
       socket
       |> assign(:confirm_delete, nil)
       |> put_flash(
         :info,
         Gettext.gettext(PhoenixKitWeb.Gettext, "Category permanently deleted.")
       )
       |> load_catalogue_data()}
    else
      nil ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Category not found."))
         |> load_catalogue_data()}

      {:error, reason} ->
        Logger.error("Failed to permanently delete category #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete category.")
         )
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

  defp confirm_delete!(socket) do
    case socket.assigns.confirm_delete do
      {_type, _uuid} = value -> value
      _ -> raise "confirm_delete not set"
    end
  end

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> [actor_uuid: uuid]
      _ -> []
    end
  end

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
    uncategorized = Catalogue.list_uncategorized_items(uuid, mode: mode)

    assign(socket,
      page_title: catalogue.name,
      catalogue: catalogue,
      uncategorized_items: uncategorized,
      deleted_count: deleted_count,
      active_item_count: Catalogue.item_count_for_catalogue(uuid),
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

      case Catalogue.swap_category_positions(cat_a, cat_b, actor_opts(socket)) do
        {:ok, _} ->
          {:noreply, load_catalogue_data(socket)}

        {:error, _} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to reorder categories.")
           )}
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
              <.icon name="hero-folder-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Add Category")}
            </.link>
            <.link navigate={Paths.item_new(@catalogue.uuid)} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Add Item")}
            </.link>
            <.link navigate={Paths.catalogue_edit(@catalogue.uuid)} class="btn btn-ghost btn-sm">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
            </.link>
          </:actions>
        </.admin_page_header>

        <div :if={@catalogue.description || Decimal.gt?(@catalogue.markup_percentage, Decimal.new("0"))} class="-mt-4">
          <p :if={@catalogue.description} class="text-base-content/60">
            {@catalogue.description}
          </p>
          <p :if={Decimal.gt?(@catalogue.markup_percentage, Decimal.new("0"))} class="text-sm text-base-content/50 mt-0.5">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Markup: %{percentage}%", percentage: Decimal.to_string(@catalogue.markup_percentage, :normal))}
          </p>
        </div>

        <%!-- Search --%>
        <.search_input :if={@view_mode == "active"} query={@search_query} placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Search items by name, description, or SKU...")} />

        <%!-- View toggle --%>
        <.view_mode_toggle storage_key="catalogue-detail-items" />

        <%!-- Search results --%>
        <div :if={@search_results != nil} class="flex flex-col gap-4">
          <.search_results_summary count={length(@search_results)} query={@search_query} />

          <.empty_state :if={@search_results == []} message={Gettext.gettext(PhoenixKitWeb.Gettext, "No items match your search.")} />

          <.item_table
            :if={@search_results != []}
            items={@search_results}
            columns={[:name, :sku, :base_price, :price, :unit, :status]}
            markup_percentage={@catalogue.markup_percentage}
            edit_path={&Paths.item_edit/1}
            cards={true}
            show_toggle={false}
            storage_key="catalogue-detail-items"
            id="catalogue-search-items"
          />
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
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Active")} ({@active_item_count})
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
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Deleted")} ({@deleted_count})
          </button>
        </div>

        <%!-- Normal view (hidden during search) --%>
        <%!-- Empty state --%>
        <div :if={is_nil(@search_results) and @catalogue.categories == [] and @uncategorized_items == [] and @view_mode == "active"} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">{Gettext.gettext(PhoenixKitWeb.Gettext, "No categories or items yet. Add a category or item to get started.")}</p>
          </div>
        </div>

        <div :if={is_nil(@search_results) and @catalogue.categories == [] and @uncategorized_items == [] and @view_mode == "deleted"} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">{Gettext.gettext(PhoenixKitWeb.Gettext, "No deleted items.")}</p>
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
                      title={Gettext.gettext(PhoenixKitWeb.Gettext, "Move up")}
                    >
                      <.icon name="hero-chevron-up" class="w-3 h-3" />
                    </button>
                    <button
                      phx-click="move_category_down"
                      phx-value-uuid={category.uuid}
                      class="btn btn-ghost btn-xs btn-square"
                      title={Gettext.gettext(PhoenixKitWeb.Gettext, "Move down")}
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
                    {Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                  </.link>
                  <button phx-click="trash_category" phx-value-uuid={category.uuid} class="btn btn-ghost btn-xs text-error">
                    {Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
                  </button>
                </div>

                <%!-- Deleted mode: Restore + Permanent Delete (for deleted categories) --%>
                <div :if={@view_mode == "deleted" && category.status == "deleted"} class="flex gap-1">
                  <button
                    phx-click="restore_category"
                    phx-value-uuid={category.uuid}
                    class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-success/30 bg-success/10 hover:bg-success/20 text-success text-xs font-medium transition-colors cursor-pointer"
                  >
                    {Gettext.gettext(PhoenixKitWeb.Gettext, "Restore")}
                  </button>
                  <button
                    phx-click="show_delete_confirm"
                    phx-value-uuid={category.uuid}
                    phx-value-type="category"
                    class="btn btn-ghost btn-xs text-error"
                  >
                    {Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}
                  </button>
                </div>
              </div>

              <p :if={category.description && @view_mode == "active"} class="text-sm text-base-content/60">
                {category.description}
              </p>

              <%!-- Items table: active mode --%>
              <div :if={category.items != [] and @view_mode == "active"} class="mt-2">
                <.item_table
                  items={category.items}
                  columns={[:name, :sku, :base_price, :price, :unit, :status]}
                  markup_percentage={@catalogue.markup_percentage}
                  edit_path={&Paths.item_edit/1}
                  on_delete="delete_item"
                  cards={true}
                  show_toggle={false}
                  storage_key="catalogue-detail-items"
                  id={"cat-items-active-#{category.uuid}"}
                  wrapper_class="overflow-x-auto shadow-none rounded-none"
                />
              </div>
              <%!-- Items table: deleted mode --%>
              <div :if={category.items != [] and @view_mode == "deleted"} class="mt-2">
                <.item_table
                  items={category.items}
                  columns={[:name, :sku, :base_price, :price, :unit, :status]}
                  markup_percentage={@catalogue.markup_percentage}
                  on_restore="restore_item"
                  on_permanent_delete="show_delete_confirm"
                  permanent_delete_type="item"
                  cards={true}
                  show_toggle={false}
                  storage_key="catalogue-detail-items"
                  id={"cat-items-deleted-#{category.uuid}"}
                  wrapper_class="overflow-x-auto shadow-none rounded-none"
                />
              </div>

              <p :if={category.items == [] and @view_mode == "active"} class="text-sm text-base-content/40 text-center py-4">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "No items in this category.")}
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Uncategorized items --%>
        <div :if={is_nil(@search_results) and @uncategorized_items != []} class="card bg-base-100 shadow">
          <div class="card-body">
            <div class="flex items-center gap-2">
              <h3 class="card-title text-lg text-base-content/70">{Gettext.gettext(PhoenixKitWeb.Gettext, "Uncategorized")}</h3>
              <span class="badge badge-ghost badge-sm">{length(@uncategorized_items)} items</span>
            </div>

            <div class="mt-2">
              <.item_table
                items={@uncategorized_items}
                columns={[:name, :sku, :base_price, :unit, :status]}
                edit_path={if @view_mode == "active", do: &Paths.item_edit/1}
                on_delete={if @view_mode == "active", do: "delete_item"}
                on_restore={if @view_mode == "deleted", do: "restore_item"}
                on_permanent_delete={if @view_mode == "deleted", do: "show_delete_confirm"}
                permanent_delete_type="item"
                cards={true}
                show_toggle={false}
                storage_key="catalogue-detail-items"
                id="uncategorized-items"
              />
            </div>
          </div>
        </div>
      </div>

      <.confirm_modal
        show={match?({"item", _}, @confirm_delete)}
        on_confirm="permanently_delete_item"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Permanently Delete Item")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitWeb.Gettext, "This item will be permanently deleted. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"category", _}, @confirm_delete)}
        on_confirm="permanently_delete_category"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Permanently Delete Category")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitWeb.Gettext, "This category and all its items will be permanently deleted. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}
        danger={true}
      />
    </div>
    """
  end
end
