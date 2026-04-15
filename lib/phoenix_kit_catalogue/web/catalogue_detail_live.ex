defmodule PhoenixKitCatalogue.Web.CatalogueDetailLive do
  @moduledoc """
  Detail view for a single catalogue, with infinite-scroll paging over
  its categories and items.

  A single `InfiniteScroll` sentinel at the page bottom drives loading.
  The cursor walks categories in display order: it fills the current
  category's card up to `@per_page` items at a time, then advances to
  the next category, then finally pages through uncategorized items.
  Each `load_more` event loads exactly one batch — the user can keep
  scrolling to stream through catalogues with thousands of items
  without a single blocking query.
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitCatalogue.Web.Components

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths

  @per_page 100

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    socket =
      assign(socket,
        page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "Loading..."),
        catalogue_uuid: uuid,
        catalogue: nil,
        category_list: [],
        category_counts: %{},
        uncategorized_total: 0,
        loaded_cards: [],
        cursor: initial_cursor(),
        has_more: false,
        loading: false,
        confirm_delete: nil,
        view_mode: "active",
        deleted_count: 0,
        active_item_count: 0,
        search_query: "",
        search_results: nil,
        search_offset: 0,
        search_total: 0,
        search_has_more: false,
        search_loading: false
      )

    if connected?(socket) do
      try do
        {:ok, reset_and_load(socket)}
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
     |> reset_and_load()}
  end

  def handle_event("load_more", _params, socket) do
    cond do
      socket.assigns.search_results != nil and socket.assigns.search_has_more and
          not socket.assigns.search_loading ->
        {:noreply, start_search_page(socket)}

      is_nil(socket.assigns.search_results) and socket.assigns.has_more and
          not socket.assigns.loading ->
        {:noreply, socket |> assign(:loading, true) |> load_next_batch()}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, clear_search(socket)}
    else
      {:noreply, run_search(socket, query)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, clear_search(socket)}
  end

  def handle_event("delete_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.trash_item(item, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Item moved to deleted."))
       |> remove_item_locally(uuid)
       |> refresh_counts()}
    else
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Item not found.")
         )}

      {:error, reason} ->
        Logger.error("Failed to trash item #{uuid}: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete item.")
         )}
    end
  end

  def handle_event("restore_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.restore_item(item, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Item restored."))
       |> remove_item_locally(uuid)
       |> refresh_counts()}
    else
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Item not found.")
         )}

      {:error, reason} ->
        Logger.error("Failed to restore item #{uuid}: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to restore item.")
         )}
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
       |> remove_item_locally(uuid)
       |> refresh_counts()}
    else
      nil ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Item not found."))}

      {:error, reason} ->
        Logger.error("Failed to permanently delete item #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete item."))}
    end
  end

  def handle_event("trash_category", %{"uuid" => uuid}, socket) do
    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.trash_category(category, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Category moved to deleted."))
       |> reset_and_load()}
    else
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Category not found.")
         )}

      {:error, reason} ->
        Logger.error("Failed to trash category #{uuid}: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete category.")
         )}
    end
  end

  def handle_event("restore_category", %{"uuid" => uuid}, socket) do
    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.restore_category(category, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Category restored."))
       |> reset_and_load()}
    else
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Category not found.")
         )}

      {:error, reason} ->
        Logger.error("Failed to restore category #{uuid}: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to restore category.")
         )}
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
       |> reset_and_load()}
    else
      nil ->
        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Category not found."))}

      {:error, reason} ->
        Logger.error("Failed to permanently delete category #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete category.")
         )}
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

  defp initial_cursor, do: %{phase: :categories, category_index: 0, item_offset: 0}

  # Resets paging state and loads the first batch. Called on mount, when
  # the user switches active/deleted tabs, and after any structural
  # change (category trash/restore/permanent-delete/reorder) because
  # those can affect which cards render and in what order.
  defp reset_and_load(socket) do
    uuid = socket.assigns.catalogue_uuid
    deleted_count = Catalogue.deleted_count_for_catalogue(uuid)

    # Auto-switch back to active if the deleted tab was visible but has
    # no content left.
    view_mode =
      if deleted_count == 0 and socket.assigns.view_mode == "deleted",
        do: "active",
        else: socket.assigns.view_mode

    mode = view_mode_to_atom(view_mode)
    catalogue = Catalogue.fetch_catalogue!(uuid)
    category_list = Catalogue.list_categories_metadata_for_catalogue(uuid, mode: mode)
    category_counts = Catalogue.item_counts_by_category_for_catalogue(uuid, mode: mode)
    uncategorized_total = Catalogue.uncategorized_count_for_catalogue(uuid, mode: mode)

    has_any_content = category_list != [] or uncategorized_total > 0

    socket
    |> assign(
      page_title: catalogue.name,
      catalogue: catalogue,
      category_list: category_list,
      category_counts: category_counts,
      uncategorized_total: uncategorized_total,
      loaded_cards: [],
      cursor: initial_cursor(),
      has_more: has_any_content,
      loading: has_any_content,
      deleted_count: deleted_count,
      active_item_count: Catalogue.item_count_for_catalogue(uuid),
      view_mode: view_mode
    )
    |> load_next_batch()
  end

  # Refreshes the header counts (Active / Deleted tabs) and the
  # per-category + uncategorized totals after an item mutation, without
  # reloading the card list. Preserves scroll position.
  defp refresh_counts(socket) do
    uuid = socket.assigns.catalogue_uuid
    mode = view_mode_to_atom(socket.assigns.view_mode)

    assign(socket,
      deleted_count: Catalogue.deleted_count_for_catalogue(uuid),
      active_item_count: Catalogue.item_count_for_catalogue(uuid),
      category_counts: Catalogue.item_counts_by_category_for_catalogue(uuid, mode: mode),
      uncategorized_total: Catalogue.uncategorized_count_for_catalogue(uuid, mode: mode)
    )
  end

  # Loads one batch (up to `@per_page` items) based on the current
  # cursor and appends/merges it into `loaded_cards`. Advances the
  # cursor. Sets `has_more = false` when nothing else remains to load.
  defp load_next_batch(socket) do
    %{
      cursor: cursor,
      catalogue_uuid: uuid,
      view_mode: view_mode,
      category_list: categories,
      loaded_cards: cards
    } = socket.assigns

    mode = view_mode_to_atom(view_mode)

    case fetch_next(cursor, uuid, categories, mode) do
      :done ->
        assign(socket, has_more: false, loading: false)

      {:category, category, items, exhausted?} ->
        new_cards = merge_category_card(cards, category, items)

        new_cursor =
          if exhausted? do
            %{cursor | category_index: cursor.category_index + 1, item_offset: 0}
          else
            %{cursor | item_offset: cursor.item_offset + length(items)}
          end

        assign(socket,
          loaded_cards: new_cards,
          cursor: new_cursor,
          has_more: true,
          loading: false
        )

      {:uncategorized, items, exhausted?} ->
        new_cards = merge_uncategorized_card(cards, items)

        new_cursor =
          if exhausted? do
            %{cursor | phase: :done}
          else
            %{
              phase: :uncategorized,
              category_index: 0,
              item_offset: cursor.item_offset + length(items)
            }
          end

        assign(socket,
          loaded_cards: new_cards,
          cursor: new_cursor,
          has_more: new_cursor.phase != :done,
          loading: false
        )
    end
  end

  # Runs a fresh search query asynchronously. If a prior search is still
  # in flight, `start_async/3` cancels it — so fast typing (type-pause-
  # type-pause) doesn't flash stale intermediate results as each old
  # request lands out of order. The actual assign happens in
  # `handle_async(:search, ...)`, guarded by a query equality check.
  defp run_search(socket, query) do
    uuid = socket.assigns.catalogue_uuid

    socket
    |> assign(search_query: query, search_loading: true)
    |> start_async(:search, fn ->
      results =
        Catalogue.search_items_in_catalogue(uuid, query, limit: @per_page, offset: 0)

      total = Catalogue.count_search_items_in_catalogue(uuid, query)
      {query, results, total}
    end)
  end

  @impl true
  def handle_async(:search, {:ok, {query, results, total}}, socket) do
    # Only apply if the user is still asking for this query. A late
    # response for a query the user has already superseded gets dropped.
    if socket.assigns.search_query == query do
      {:noreply,
       assign(socket,
         search_results: results,
         search_offset: length(results),
         search_total: total,
         search_has_more: length(results) < total,
         search_loading: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:search, {:exit, reason}, socket) do
    # Cancellations (reason `:shutdown` / `:killed` / `{:shutdown, _}`) are
    # expected when a newer query supersedes a pending one — the newer
    # handler owns `search_loading`, so leave the socket alone. For any
    # other exit (crashed DB query, timeout, raise in the task fn) clear
    # loading and flash the user so they don't stare at a perpetual
    # spinner, and log so we can debug without reproducing.
    case reason do
      r when r in [:shutdown, :killed] ->
        {:noreply, socket}

      {:shutdown, _} ->
        {:noreply, socket}

      other ->
        Logger.warning("search task exited unexpectedly: #{inspect(other)}")

        {:noreply,
         socket
         |> assign(:search_loading, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Search failed. Please try again.")
         )}
    end
  end

  def handle_async(:search_page, {:ok, {query, offset, page}}, socket) do
    # Same-shape guard as `:search`: only apply if the socket is still on
    # the query we paged for AND still expecting this offset. If the user
    # typed a new search mid-flight, `search_query` moved on; if they
    # somehow triggered a parallel page (shouldn't happen — `load_more`
    # checks `search_loading`), `search_offset` moved on.
    if socket.assigns.search_query == query and socket.assigns.search_offset == offset do
      new_offset = offset + length(page)
      # `page == []` protects against stale `search_total` (items
      # concurrently deleted) keeping `search_has_more` true forever.
      has_more = page != [] and new_offset < socket.assigns.search_total

      {:noreply,
       assign(socket,
         search_results: (socket.assigns.search_results || []) ++ page,
         search_offset: new_offset,
         search_has_more: has_more,
         search_loading: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:search_page, {:exit, reason}, socket) do
    case reason do
      r when r in [:shutdown, :killed] ->
        {:noreply, socket}

      {:shutdown, _} ->
        {:noreply, socket}

      other ->
        Logger.warning("search page task exited unexpectedly: #{inspect(other)}")

        {:noreply,
         socket
         |> assign(:search_loading, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Search failed. Please try again.")
         )}
    end
  end

  # Fires the next-page query off the LV process so scrolling a 50k-item
  # catalogue doesn't freeze the socket on every batch (ILIKE-against-
  # jsonb-as-text is not a fast query). Appending happens in
  # `handle_async(:search_page, …)` guarded by `{query, offset}` so a
  # superseding new search or a double-scroll can't double-append.
  defp start_search_page(socket) do
    %{catalogue_uuid: uuid, search_query: query, search_offset: offset} = socket.assigns

    socket
    |> assign(:search_loading, true)
    |> start_async(:search_page, fn ->
      page = Catalogue.search_items_in_catalogue(uuid, query, limit: @per_page, offset: offset)
      {query, offset, page}
    end)
  end

  defp clear_search(socket) do
    assign(socket,
      search_query: "",
      search_results: nil,
      search_offset: 0,
      search_total: 0,
      search_has_more: false,
      search_loading: false
    )
  end

  # Drives the cursor walk. Returns the next batch to render, or
  # `:done` when the cursor has nothing left in either phase. Walks:
  # categories (in display order) → uncategorized → done.
  defp fetch_next(%{phase: :categories} = cursor, uuid, categories, mode) do
    case Enum.at(categories, cursor.category_index) do
      nil ->
        fetch_next(
          %{phase: :uncategorized, category_index: 0, item_offset: 0},
          uuid,
          categories,
          mode
        )

      category ->
        fetch_category_batch(category, cursor, uuid, categories, mode)
    end
  end

  defp fetch_next(%{phase: :uncategorized, item_offset: off}, uuid, _categories, mode) do
    items =
      Catalogue.list_uncategorized_items_paged(uuid,
        mode: mode,
        offset: off,
        limit: @per_page
      )

    if items == [] do
      :done
    else
      {:uncategorized, items, length(items) < @per_page}
    end
  end

  defp fetch_next(%{phase: :done}, _uuid, _categories, _mode), do: :done

  defp fetch_category_batch(category, cursor, uuid, categories, mode) do
    items =
      Catalogue.list_items_for_category_paged(category.uuid,
        mode: mode,
        offset: cursor.item_offset,
        limit: @per_page
      )

    cond do
      # Empty category — push an empty card on the first visit so the
      # category is still visible with its controls, then advance.
      items == [] and cursor.item_offset == 0 ->
        {:category, category, [], true}

      items == [] ->
        fetch_next(
          %{phase: :categories, category_index: cursor.category_index + 1, item_offset: 0},
          uuid,
          categories,
          mode
        )

      true ->
        {:category, category, items, length(items) < @per_page}
    end
  end

  # Appends items to the last card if it's already for this category,
  # otherwise pushes a fresh card.
  defp merge_category_card(cards, category, items) do
    case List.last(cards) do
      %{kind: :category, category: last_cat, items: existing}
      when last_cat.uuid == category.uuid ->
        updated = %{kind: :category, category: category, items: existing ++ items}
        List.replace_at(cards, length(cards) - 1, updated)

      _ ->
        cards ++ [%{kind: :category, category: category, items: items}]
    end
  end

  defp merge_uncategorized_card(cards, items) do
    case List.last(cards) do
      %{kind: :uncategorized, items: existing} ->
        updated = %{kind: :uncategorized, items: existing ++ items}
        List.replace_at(cards, length(cards) - 1, updated)

      _ ->
        cards ++ [%{kind: :uncategorized, items: items}]
    end
  end

  # Removes a trashed/restored/deleted item from its card's items list
  # in place. No DB reload, so scroll position is preserved.
  defp remove_item_locally(socket, item_uuid) do
    cards =
      Enum.map(socket.assigns.loaded_cards, fn card ->
        Map.update!(card, :items, fn items ->
          Enum.reject(items, &(&1.uuid == item_uuid))
        end)
      end)

    assign(socket, :loaded_cards, cards)
  end

  defp view_mode_to_atom("active"), do: :active
  defp view_mode_to_atom("deleted"), do: :deleted

  defp reorder_category(socket, uuid, direction) do
    categories = socket.assigns.category_list
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
          {:noreply, reset_and_load(socket)}

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

        <%!-- Search results (visible when the user has typed a query) --%>
        <div :if={@search_results != nil or @search_loading} class="flex flex-col gap-4">
          <%!-- Status line: spinner while loading, "X of Y results" when settled --%>
          <div class="flex items-center gap-2">
            <%= if @search_loading and is_nil(@search_results) do %>
              <span class="text-sm text-base-content/60">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Searching for \"%{query}\"...", query: @search_query)}
              </span>
            <% else %>
              <.search_results_summary :if={@search_results != nil} count={@search_total} query={@search_query} loaded={length(@search_results)} />
            <% end %>
            <span :if={@search_loading} class="loading loading-spinner loading-xs text-base-content/40"></span>
          </div>

          <.empty_state :if={@search_results == [] and not @search_loading} message={Gettext.gettext(PhoenixKitWeb.Gettext, "No items match your search.")} />

          <%!-- Stale results are dimmed while a newer query is in flight to
               signal that the list is about to update. --%>
          <div :if={@search_results not in [nil, []]} class={["transition-opacity", @search_loading && "opacity-50"]}>
            <.item_table
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

          <%!-- Infinite-scroll sentinel for search results --%>
          <div
            :if={@search_has_more and not @search_loading}
            id="search-load-more-sentinel"
            phx-hook="InfiniteScroll"
            data-cursor={"search-#{@search_offset}"}
            class="py-4"
          >
            <div class="flex justify-center">
              <span class="loading loading-spinner loading-sm text-base-content/30"></span>
            </div>
          </div>
        </div>

        <%!-- Status tabs --%>
        <div :if={@deleted_count > 0 and is_nil(@search_results) and not @search_loading} class="flex items-center gap-0.5 border-b border-base-200">
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

        <%!-- Normal (non-search) view: infinite-scroll cards --%>
        <%!-- Empty states only shown when nothing is loading AND nothing was ever loaded --%>
        <div :if={is_nil(@search_results) and not @search_loading and @loaded_cards == [] and not @has_more and not @loading and @view_mode == "active"} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">{Gettext.gettext(PhoenixKitWeb.Gettext, "No categories or items yet. Add a category or item to get started.")}</p>
          </div>
        </div>

        <div :if={is_nil(@search_results) and not @search_loading and @loaded_cards == [] and not @has_more and not @loading and @view_mode == "deleted"} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">{Gettext.gettext(PhoenixKitWeb.Gettext, "No deleted items.")}</p>
          </div>
        </div>

        <%!-- Streamed cards (one per category, one for uncategorized). --%>
        <%= for {card, card_idx} <- Enum.with_index(@loaded_cards), is_nil(@search_results) and not @search_loading do %>
          <.detail_card
            card={card}
            card_idx={card_idx}
            view_mode={@view_mode}
            category_total={length(@category_list)}
            category_counts={@category_counts}
            uncategorized_total={@uncategorized_total}
            catalogue={@catalogue}
          />
        <% end %>

        <%!-- Infinite-scroll sentinel --%>
        <div
          :if={is_nil(@search_results) and not @search_loading and @has_more}
          id="detail-load-more-sentinel"
          phx-hook="InfiniteScroll"
          data-cursor={"#{@cursor.phase}-#{@cursor.category_index}-#{@cursor.item_offset}"}
          class="py-4"
        >
          <div class="flex justify-center">
            <span class="loading loading-spinner loading-sm text-base-content/30"></span>
          </div>
        </div>

        <div :if={is_nil(@search_results) and not @search_loading and not @has_more and @loaded_cards != []} class="text-center text-xs text-base-content/40 py-2">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "All items loaded")}
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

    <script>
      window.PhoenixKitHooks = window.PhoenixKitHooks || {};
      window.PhoenixKitHooks.InfiniteScroll = window.PhoenixKitHooks.InfiniteScroll || {
        mounted() {
          this.intersecting = false;
          this.observer = new IntersectionObserver((entries) => {
            this.intersecting = entries[0].isIntersecting;
            if (this.intersecting) {
              this.pushEvent("load_more", {});
            }
          }, { rootMargin: "200px" });
          this.observer.observe(this.el);
        },
        updated() {
          // IntersectionObserver only fires on state transitions. When the
          // viewport is tall or the user jumped via Page Down / resize, the
          // sentinel stays continuously in view across batches — so the
          // observer goes silent after the first fire. Re-trigger explicitly
          // whenever the server patches us while we're still on-screen.
          // The server's `loading` guard dedupes duplicate events.
          if (this.intersecting) {
            this.pushEvent("load_more", {});
          }
        },
        destroyed() {
          this.observer.disconnect();
        }
      };
    </script>
    """
  end

  # Renders one card in the detail view: a category with its
  # progressively-loaded items, or the Uncategorized bucket.
  attr(:card, :map, required: true)
  attr(:card_idx, :integer, required: true)
  attr(:view_mode, :string, required: true)
  attr(:category_total, :integer, required: true)
  attr(:category_counts, :map, required: true)
  attr(:uncategorized_total, :integer, required: true)
  attr(:catalogue, :any, required: true)

  defp detail_card(%{card: %{kind: :category}} = assigns) do
    assigns =
      assign(assigns, :total, Map.get(assigns.category_counts, assigns.card.category.uuid, 0))

    ~H"""
    <div :if={@view_mode == "active" or @card.category.status == "deleted" or @total > 0} class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <div :if={@category_total > 1 && @view_mode == "active"} class="flex flex-col">
              <button
                phx-click="move_category_up"
                phx-value-uuid={@card.category.uuid}
                class="btn btn-ghost btn-xs btn-square"
                title={Gettext.gettext(PhoenixKitWeb.Gettext, "Move up")}
              >
                <.icon name="hero-chevron-up" class="w-3 h-3" />
              </button>
              <button
                phx-click="move_category_down"
                phx-value-uuid={@card.category.uuid}
                class="btn btn-ghost btn-xs btn-square"
                title={Gettext.gettext(PhoenixKitWeb.Gettext, "Move down")}
              >
                <.icon name="hero-chevron-down" class="w-3 h-3" />
              </button>
            </div>
            <.link
              :if={@view_mode == "active"}
              navigate={Paths.category_edit(@card.category.uuid)}
              class="card-title text-lg link link-hover"
            >
              {@card.category.name}
            </.link>
            <h3
              :if={@view_mode != "active"}
              class={["card-title text-lg", @card.category.status == "deleted" && "text-error/70"]}
            >
              {@card.category.name}
            </h3>
            <span :if={@card.category.status == "deleted"} class="badge badge-error badge-xs">deleted</span>
            <span class="badge badge-ghost badge-sm">{@total} {Gettext.gettext(PhoenixKitWeb.Gettext, "items")}</span>
          </div>

          <%!-- Active mode: Edit + Delete --%>
          <div :if={@view_mode == "active"} class="flex gap-1">
            <.link navigate={Paths.category_edit(@card.category.uuid)} class="btn btn-ghost btn-xs">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
            </.link>
            <button phx-click="trash_category" phx-value-uuid={@card.category.uuid} class="btn btn-ghost btn-xs text-error">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
            </button>
          </div>

          <%!-- Deleted mode: Restore + Permanent Delete (for deleted categories) --%>
          <div :if={@view_mode == "deleted" && @card.category.status == "deleted"} class="flex gap-1">
            <button
              phx-click="restore_category"
              phx-value-uuid={@card.category.uuid}
              class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-success/30 bg-success/10 hover:bg-success/20 text-success text-xs font-medium transition-colors cursor-pointer"
            >
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Restore")}
            </button>
            <button
              phx-click="show_delete_confirm"
              phx-value-uuid={@card.category.uuid}
              phx-value-type="category"
              class="btn btn-ghost btn-xs text-error"
            >
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}
            </button>
          </div>
        </div>

        <p :if={@card.category.description && @view_mode == "active"} class="text-sm text-base-content/60">
          {@card.category.description}
        </p>

        <%!-- Items table: active mode --%>
        <div :if={@card.items != [] and @view_mode == "active"} class="mt-2">
          <.item_table
            items={@card.items}
            columns={[:name, :sku, :base_price, :price, :unit, :status]}
            markup_percentage={@catalogue.markup_percentage}
            edit_path={&Paths.item_edit/1}
            on_delete="delete_item"
            cards={true}
            show_toggle={false}
            storage_key="catalogue-detail-items"
            id={"cat-items-active-#{@card.category.uuid}"}
            wrapper_class="overflow-x-auto shadow-none rounded-none"
          />
        </div>
        <%!-- Items table: deleted mode --%>
        <div :if={@card.items != [] and @view_mode == "deleted"} class="mt-2">
          <.item_table
            items={@card.items}
            columns={[:name, :sku, :base_price, :price, :unit, :status]}
            markup_percentage={@catalogue.markup_percentage}
            on_restore="restore_item"
            on_permanent_delete="show_delete_confirm"
            permanent_delete_type="item"
            cards={true}
            show_toggle={false}
            storage_key="catalogue-detail-items"
            id={"cat-items-deleted-#{@card.category.uuid}"}
            wrapper_class="overflow-x-auto shadow-none rounded-none"
          />
        </div>

        <p :if={@card.items == [] and @view_mode == "active"} class="text-sm text-base-content/40 text-center py-4">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "No items in this category.")}
        </p>
      </div>
    </div>
    """
  end

  defp detail_card(%{card: %{kind: :uncategorized}} = assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center gap-2">
          <h3 class="card-title text-lg text-base-content/70">{Gettext.gettext(PhoenixKitWeb.Gettext, "Uncategorized")}</h3>
          <span class="badge badge-ghost badge-sm">{@uncategorized_total} {Gettext.gettext(PhoenixKitWeb.Gettext, "items")}</span>
        </div>

        <div class="mt-2">
          <.item_table
            items={@card.items}
            columns={[:name, :sku, :base_price, :unit, :status]}
            edit_path={if @view_mode == "active", do: &Paths.item_edit/1}
            on_delete={if @view_mode == "active", do: "delete_item"}
            on_restore={if @view_mode == "deleted", do: "restore_item"}
            on_permanent_delete={if @view_mode == "deleted", do: "show_delete_confirm"}
            permanent_delete_type="item"
            cards={true}
            show_toggle={false}
            storage_key="catalogue-detail-items"
            id={"uncategorized-items-#{@card_idx}"}
          />
        </div>
      </div>
    </div>
    """
  end
end
