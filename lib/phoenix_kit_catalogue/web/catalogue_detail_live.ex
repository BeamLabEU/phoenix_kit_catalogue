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

  use PhoenixKitWeb.Live.UrlState,
    params: [
      current_category_uuid: [default: nil, url_key: "category"],
      search_query: [default: "", url_key: "q"]
    ]

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.EmptyState, only: [empty_state: 1]
  import PhoenixKitWeb.Components.Core.Pagination, only: [load_more: 1]

  import PhoenixKitWeb.Components.Core.BulkSelect,
    only: [
      bulk_select_scope: 1,
      bulk_select_header_cell: 1,
      bulk_select_cell: 1,
      bulk_actions_toolbar: 1
    ]

  import PhoenixKitWeb.Components.Core.BulkActionsBar, only: [bulk_actions_bar: 1]

  import PhoenixKitWeb.Components.Core.Sortable, only: [sortable_tbody: 1, sortable_row: 1]
  import PhoenixKitCatalogue.Web.TableToolbar, only: [column_settings_modal: 1]
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.ReorderModal, only: [reorder_modal: 1]
  import PhoenixKitWeb.Components.Core.SortSelector, only: [sort_selector: 1]

  import PhoenixKitWeb.Components.Core.TableDefault,
    only: [
      table_default: 1,
      table_default_header: 1,
      table_default_row: 1,
      table_default_header_cell: 1,
      table_default_cell: 1,
      sort_header_cell: 1,
      drag_handle_cell: 1,
      drag_handle_header_cell: 1
    ]

  import PhoenixKitCatalogue.Web.Components

  import PhoenixKitCatalogue.Web.Helpers,
    only: [actor_opts: 1, actor_uuid: 1, log_operation_error: 3]

  alias PhoenixKit.Utils.Values
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Errors
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Web.Components.PdfSearchModal
  alias PhoenixKitCatalogue.Web.Components.ProductCard
  alias PhoenixKitCatalogue.Web.TableConfig
  alias PhoenixKitCatalogue.Web.ViewConfig

  @per_page 100
  # Cross-tab bulk-change red-flash → state-refresh delay. Long enough
  # that the receiver sees the leaving rows pulse red before they
  # vanish on the refresh, short enough not to feel laggy.
  @bulk_change_apply_delay_ms 800

  # Active-list sortable fields. Whitelist guards the sort events — the
  # context validates atoms too, but the LV must not coerce attacker
  # input into atoms. `:position` is the manual-order default.
  @items_sort_fields ~w(position name sku base_price status)a
  @items_sort_field_strs Enum.map(@items_sort_fields, &Atom.to_string/1)

  # Hardcoded string→atom whitelist for the reorder modal strategies —
  # NEVER String.to_existing_atom on the submitted value.
  @items_reorder_strategy_map %{
    "name_asc" => :name_asc,
    "name_desc" => :name_desc,
    "created_desc" => :created_desc,
    "created_asc" => :created_asc,
    "reverse" => :reverse
  }

  # PhoenixKit auto-applies its admin chrome layout to external module admin
  # views via socket.private[:live_layout]. Opt out here so this view can
  # self-wrap with LayoutWrapper.app_layout and push its title/subtitle into
  # the global admin header (same pattern as /admin/media and orders/index).
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    socket =
      assign(socket,
        page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Loading..."),
        catalogue_uuid: uuid,
        catalogue: nil,
        # ── Drill-down position ──
        # current_category_uuid is managed by UrlState (?category=).
        # nil = root level, "uncategorized" = the uncategorized bucket,
        # or a real category UUID. current_category is the resolved value:
        # nil | :uncategorized | %Category{}.
        # prior_category_uuid: tracks the last-loaded category so
        # handle_url_state can detect node changes without needing to diff
        # the assigns on a struct that includes mutable association maps.
        prior_category_uuid: :__unset__,
        current_category: nil,
        # Trimmed active-ancestor chain above the current node (root and
        # current node excluded). Drives the breadcrumb.
        breadcrumb: [],
        # Direct child categories shown as drill cards at this level.
        child_categories: [],
        child_counts: %{},
        children_with_subs: MapSet.new(),
        child_subcat_counts: %{},
        # Root-active only: the Uncategorized drill card.
        uncategorized_active_count: 0,
        # ── Current node's own direct items (single paged list) ──
        items: [],
        items_total: 0,
        items_offset: 0,
        items_has_more: false,
        show_items_section: false,
        # Per-status item counts for the current node — drive the four
        # per-status tab labels (active / inactive / discontinued / deleted).
        level_status_counts: %{},
        # `[{status, label, count}]` for the tabs to actually render — only
        # populated statuses; the strip hides itself when there's ≤1.
        status_tabs: [],
        # %{resource_uuid => attached-document count} for every row this LV
        # has loaded (level items, search results, child categories) —
        # drives the paperclip indicator. Merged per page load; per-uuid
        # entries are overwritten on reload, so staleness is bounded.
        file_counts: %{},
        # Edit links carry the current level as return_to; recomputed on
        # every level load. The bare path fn is only the pre-load default.
        edit_path_fn: &Paths.item_edit/1,
        # ── Product-view card (opened by clicking a featured thumb) ──
        card_open: false,
        card_name: nil,
        card_images: [],
        card_fields: [],
        card_files: [],
        confirm_delete: nil,
        trash_modal: nil,
        bulk_move_modal: nil,
        bulk_confirm: nil,
        selected_items: MapSet.new(),
        attribute_map: %{},
        selected_categories: MapSet.new(),
        # ── Active item list sort + strategy reorder ──
        # The active list uses the core List-UI toolkit: a sort dropdown,
        # client-side bulk-select, DnD reorder (manual mode only), and a
        # strategy "Reorder" modal. `reorder_captured_uuids` holds the
        # uuids the BulkSelectScope hook captured for the open modal
        # (empty == "reorder all").
        categories_sort_by: :position,
        categories_sort_dir: :asc,
        items_sort_by: :position,
        items_sort_dir: :asc,
        items_columns:
          ViewConfig.load(socket.assigns[:phoenix_kit_current_user], :detail_items).columns,
        categories_columns:
          ViewConfig.load(socket.assigns[:phoenix_kit_current_user], :detail_categories).columns,
        column_modal_scope: nil,
        temp_columns: nil,
        show_items_reorder: false,
        show_categories_reorder: false,
        reorder_captured_uuids: [],
        view_mode: "active",
        search_results: nil,
        search_offset: 0,
        search_total: 0,
        search_has_more: false,
        search_loading: false,
        show_pdf_search: false,
        pdf_search_item: nil
      )

    # Subscribe BEFORE the first load so a write landing between connect
    # and load doesn't leave the UI stale. The actual level load happens
    # in handle_params/3, which runs after mount and on every `?category=`
    # drill patch.
    if connected?(socket), do: PubSub.subscribe()

    socket = apply_global_detail_sorts(socket)

    {:ok, socket}
  end

  # `?category=` and `?q=` are managed by UrlState. This stub satisfies
  # Phoenix's handle_params/3 callback (required because @impl is used).
  # UrlState attaches its own hook via on_mount, which composes alongside.
  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # Called by UrlState after mount and on every URL state change. Detects
  # node changes via `prior_category_uuid` (set to :__unset__ in mount so
  # the very first call always triggers a level load). On a node change we
  # reset selections and reload the level; on a search-only change we run
  # or clear the search without touching the level data.
  @impl true
  def handle_url_state(state, socket) do
    # Normalize the key so that nil and "" both mean "root level" — the
    # same guard that the old handle_params used via normalize_category_key.
    cat_key = normalize_category_key(state.current_category_uuid)
    prev_cat = socket.assigns.prior_category_uuid
    cat_changed? = cat_key != prev_cat

    # Write the normalized key back over the raw one UrlState decoded, so the
    # assign the template reads is the same value the rest of this module
    # branches on. `?category=` (empty) otherwise leaves `""` in the assign:
    # the DOM ids built from `@current_category_uuid || "root"` come out as
    # `items-body-` instead of `items-body-root`, and because push_url_state
    # reads its merge base back from the assigns, the next search patch
    # re-writes the empty `?category=` into the URL. UrlState documents a
    # plain assign on a declared param as the supported way to do this.
    socket = assign(socket, :current_category_uuid, cat_key)

    socket =
      if cat_changed? do
        socket
        |> assign(:prior_category_uuid, cat_key)
        |> assign(:selected_items, MapSet.new())
        |> assign(:selected_categories, MapSet.new())
      else
        socket
      end

    if connected?(socket) do
      if cat_changed? do
        load_url_state_level(socket, cat_key, state.search_query)
      else
        handle_url_state_search(socket, state.search_query)
      end
    else
      socket
    end
  end

  # Resolves the category UUID from URL state, loads the level, then
  # handles any search query present in the URL. Bounces back to root on
  # an invalid / foreign category UUID; navigates to index if the
  # catalogue itself is gone.
  defp load_url_state_level(socket, cat_key, search_query) do
    case resolve_node(socket.assigns.catalogue_uuid, cat_key) do
      {:ok, current} ->
        socket
        |> assign(:current_category, current)
        |> handle_url_state_search(search_query)
        |> reset_and_load()
        |> maybe_auto_flip_to_active()

      :invalid ->
        socket
        |> put_flash(
          :error,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")
        )
        |> push_patch(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))
    end
  rescue
    Ecto.NoResultsError ->
      Logger.warning("Catalogue not found: #{socket.assigns.catalogue_uuid}")

      socket
      |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found."))
      |> push_navigate(to: Paths.index())
  end

  defp handle_url_state_search(socket, ""), do: clear_search(socket)
  defp handle_url_state_search(socket, query), do: run_search(socket, query)

  defp normalize_category_key(nil), do: nil
  defp normalize_category_key(""), do: nil
  defp normalize_category_key("uncategorized"), do: "uncategorized"
  defp normalize_category_key(uuid) when is_binary(uuid), do: uuid

  # Resolves a `?category=` key to the current node. A UUID that doesn't
  # exist or belongs to another catalogue is `:invalid` (caller bounces
  # to root). Works in `:active` and `:deleted` view alike — drilling
  # into a trashed category to inspect its deleted subtree is valid.
  defp resolve_node(_catalogue_uuid, nil), do: {:ok, nil}
  defp resolve_node(_catalogue_uuid, "uncategorized"), do: {:ok, :uncategorized}

  defp resolve_node(catalogue_uuid, uuid) do
    case Catalogue.get_category(uuid) do
      %Category{catalogue_uuid: ^catalogue_uuid} = cat -> {:ok, cat}
      _ -> :invalid
    end
  end

  # PubSub: another LV touched a category/item/catalogue/smart-rule.
  # Filter on `parent_catalogue_uuid` so a write in another catalogue
  # doesn't reset *this* page — without that filter, every item edit
  # anywhere in the system wipes the user's scroll state, and a busy
  # admin or background importer can trap the LV in a permanent
  # spinner as the mailbox queues up faster than `refresh_in_place`
  # can drain it.
  #
  # `:catalogue` events match when the affected uuid is *this*
  # catalogue. `:category` / `:item` / `:smart_rule` match when the
  # mutated resource belongs to this catalogue (parent_catalogue_uuid
  # is threaded through the broadcast). `nil` parent is treated as
  # "unknown scope, refresh defensively" — the same way pre-filter
  # behaviour worked, so older callers that haven't been updated still
  # propagate.
  @impl true
  def handle_info(
        {:catalogue_data_changed, :catalogue, uuid, _parent},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when uuid == catalogue_uuid do
    handle_catalogue_data_changed(socket)
  end

  def handle_info(
        {:catalogue_data_changed, kind, _uuid, parent},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when kind in [:category, :item, :smart_rule] and
             (parent == catalogue_uuid or is_nil(parent)) do
    handle_catalogue_data_changed(socket)
  end

  # Another admin changed a shared detail sort (global-sort scopes) —
  # apply it without re-persisting or re-broadcasting.
  def handle_info({:catalogue_view_sort_changed, :detail_items, by, dir, from}, socket) do
    if from == self() do
      {:noreply, socket}
    else
      {:noreply, apply_items_sort(socket, detail_items_sort_field(by), dir)}
    end
  end

  def handle_info({:catalogue_view_sort_changed, :detail_categories, by, dir, from}, socket) do
    if from == self() do
      {:noreply, socket}
    else
      field = detail_categories_sort_field(by)

      socket = assign(socket, categories_sort_by: field, categories_sort_dir: dir)

      {:noreply,
       assign(
         socket,
         :child_categories,
         sort_categories(socket.assigns.child_categories, socket.assigns.child_counts, field, dir)
       )}
    end
  end

  def handle_info({:catalogue_view_sort_changed, _scope, _by, _dir, _from}, socket),
    do: {:noreply, socket}

  def handle_info({:pdf_search_modal_closed}, socket) do
    {:noreply, assign(socket, show_pdf_search: false, pdf_search_item: nil)}
  end

  # Cross-tab live reorder: another open detail page just reordered
  # items inside a card on the same catalogue. Refresh just that card's
  # items (preserves scroll) and fire the same flash the originator
  # saw. `from == self()` is the originating LV — already updated
  # locally, skip to avoid double-flashing.
  def handle_info(
        {:catalogue_card_refresh, cat_uuid, scope, flash_uuid, flash_status, from},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when cat_uuid == catalogue_uuid and from != self() do
    socket = refresh_card_items(socket, scope)

    socket =
      if is_binary(flash_uuid),
        do: flash_reorder(socket, flash_uuid, flash_status),
        else: socket

    {:noreply, socket}
  end

  # Sender's own broadcast — already handled locally; ignore.
  def handle_info({:catalogue_card_refresh, _, _, _, _, from}, socket) when from == self(),
    do: {:noreply, socket}

  # Cross-tab live reorder for categories: order positions changed,
  # which affects how every streamed card is laid out. Heavier
  # reset_and_load — same trade-off the local reorder makes.
  def handle_info(
        {:catalogue_category_reorder, cat_uuid, moved_id, status, from},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when cat_uuid == catalogue_uuid and from != self() do
    socket = reset_and_load(socket)

    socket =
      if is_binary(moved_id),
        do: flash_reorder(socket, moved_id, status),
        else: socket

    {:noreply, socket}
  end

  def handle_info({:catalogue_category_reorder, _, _, _, from}, socket) when from == self(),
    do: {:noreply, socket}

  # Cross-tab live bulk change: another open detail page just bulk-
  # trashed / restored / moved / hard-deleted items. Two-step animation
  # for receivers — flash the "leaving" colour on every affected DOM
  # row immediately, schedule the actual state refresh after the flash
  # plays out (~800ms), then on refresh fire green flash for the
  # arriving rows when the kind is :restored or :moved.
  def handle_info(
        {:catalogue_bulk_change, cat_uuid, kind, uuids, from},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when cat_uuid == catalogue_uuid and from != self() do
    leaving_status =
      case kind do
        # Restored items aren't currently visible — nothing to flash red.
        :restored -> nil
        # Trashed / moved / permanent-deleted: they're on this tab now,
        # so red-flash them as they're about to leave.
        _ -> :error
      end

    socket =
      if leaving_status,
        do: Enum.reduce(uuids, socket, &flash_reorder(&2, &1, leaving_status)),
        else: socket

    Process.send_after(self(), {:bulk_change_apply, kind, uuids}, @bulk_change_apply_delay_ms)

    {:noreply, socket}
  end

  # Originator's own bulk-change broadcast — already updated locally.
  def handle_info({:catalogue_bulk_change, _, _, _, from}, socket) when from == self(),
    do: {:noreply, socket}

  # Tail of the cross-tab bulk animation — applies the actual state
  # refresh and the arriving-side green flash (for moves / restores).
  def handle_info({:bulk_change_apply, kind, uuids}, socket) do
    socket = socket |> reset_and_load() |> refresh_counts()

    socket =
      if kind in [:restored, :moved],
        do: Enum.reduce(uuids, socket, &flash_reorder(&2, &1, :ok)),
        else: socket

    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    Logger.debug("CatalogueDetailLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp handle_catalogue_data_changed(socket) do
    {:noreply, refresh_in_place(socket)}
  rescue
    Ecto.NoResultsError ->
      # The catalogue we're viewing was deleted in another session.
      {:noreply,
       socket
       |> put_flash(
         :info,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "This catalogue was just deleted.")
       )
       |> push_navigate(to: Paths.index())}
  end

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket)
      when mode in ~w(active inactive discontinued deleted) do
    {:noreply,
     socket
     |> assign(:view_mode, mode)
     |> assign(:confirm_delete, nil)
     |> assign(:selected_items, MapSet.new())
     |> assign(:selected_categories, MapSet.new())
     |> reset_and_load()}
  end

  # One bottom sentinel drives both search-result paging and the current
  # node's item list. While a search is active it pages the results;
  # otherwise it pages the level's own items.
  def handle_event("load_more", _params, socket) do
    cond do
      socket.assigns.search_results != nil ->
        if socket.assigns.search_has_more and not socket.assigns.search_loading,
          do: {:noreply, start_search_page(socket)},
          else: {:noreply, socket}

      socket.assigns.items_has_more ->
        {:noreply, load_next_items_page(socket)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)
    {:noreply, push_url_state(socket, [search_query: query], replace: true)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, push_url_state(socket, search_query: "")}
  end

  # ── Product-view card (opened by clicking a featured-image thumb) ──
  # Host-side mirror of ItemPicker's card handlers: no phx-target on the
  # thumbs/table events here, so they arrive at this LiveView. All payloads
  # are client-forgeable — every clause has a catch-all or validates the
  # uuid against the card's own state.

  def handle_event("show_product_card", %{"uuid" => uuid}, socket) do
    case Catalogue.get_item(uuid) do
      %Item{} = item ->
        locale = socket.assigns[:current_locale] || "en"

        {:noreply,
         assign(socket,
           card_open: true,
           card_name: ProductCard.resolve_name(item, locale),
           card_images: ProductCard.resolve_images(item),
           card_fields: ProductCard.build_fields(item, locale),
           card_files: ProductCard.resolve_files(item)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("show_product_card", _params, socket), do: {:noreply, socket}

  def handle_event("card_close", _params, socket) do
    {:noreply, assign(socket, :card_open, false)}
  end

  def handle_event("show_pdf_search", %{"uuid" => uuid}, socket) do
    case Catalogue.get_item(uuid) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply,
         socket
         |> assign(:pdf_search_item, item)
         |> assign(:show_pdf_search, true)}
    end
  end

  def handle_event("delete_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.trash_item(item, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item moved to deleted."))
       |> remove_item_locally(uuid)
       |> refresh_counts()}
    else
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item not found.")
         )}

      {:error, reason} ->
        log_operation_error(socket, "trash_item", %{
          entity_type: "item",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete item.")
         )}
    end
  end

  def handle_event("restore_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.restore_item(item, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item restored."))
       |> remove_item_locally(uuid)
       |> refresh_counts()}
    else
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item not found.")
         )}

      {:error, :parent_catalogue_deleted} ->
        {:noreply, put_flash(socket, :error, Errors.message(:parent_catalogue_deleted))}

      {:error, reason} ->
        log_operation_error(socket, "restore_item", %{
          entity_type: "item",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to restore item.")
         )}
    end
  end

  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
  end

  def handle_event("permanently_delete_item", _params, socket) do
    case socket.assigns.confirm_delete do
      {"item", uuid} ->
        with %{} = item <- Catalogue.get_item(uuid),
             {:ok, _} <- Catalogue.permanently_delete_item(item, actor_opts(socket)) do
          {:noreply,
           socket
           |> assign(:confirm_delete, nil)
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item permanently deleted.")
           )
           |> remove_item_locally(uuid)
           |> refresh_counts()}
        else
          nil ->
            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item not found."))}

          {:error, reason} ->
            log_operation_error(socket, "permanently_delete_item", %{
              entity_type: "item",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete item.")
             )}
        end

      _ ->
        unexpected_confirm_event(socket, "permanently_delete_item")
    end
  end

  # Entry point from the Items / Categories tab Delete buttons. When the
  # category subtree has zero active items, trashes directly. Otherwise
  # opens a modal so the operator chooses what happens to the items
  # (move them to another category, or detach them as uncategorized in
  # the same catalogue) before the category trash fires.
  def handle_event("request_trash_category", %{"uuid" => uuid}, socket) do
    case Catalogue.get_category(uuid) do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")
         )}

      category ->
        item_count = Catalogue.active_item_count_in_subtree(uuid)

        if item_count == 0 do
          do_trash_category(socket, category, items: :cascade)
        else
          {:noreply, assign(socket, :trash_modal, build_trash_modal_state(category, item_count))}
        end
    end
  end

  def handle_event("set_trash_disposition", %{"disposition" => disp}, socket) do
    modal = socket.assigns.trash_modal || %{}

    new_modal =
      case disp do
        "uncategorize" -> %{modal | disposition: :uncategorize, target_uuid: nil}
        "move_to" -> %{modal | disposition: :move_to}
        "cascade" -> %{modal | disposition: :cascade, target_uuid: nil}
        _ -> modal
      end

    {:noreply, assign(socket, :trash_modal, new_modal)}
  end

  def handle_event("select_trash_target", %{"category_uuid" => uuid}, socket) do
    modal = socket.assigns.trash_modal || %{}
    {:noreply, assign(socket, :trash_modal, %{modal | target_uuid: Values.blank_to_nil(uuid)})}
  end

  def handle_event("confirm_trash_category", _params, socket) do
    case socket.assigns.trash_modal do
      %{bulk: true, bulk_uuids: uuids, disposition: disp, target_uuid: target_uuid} ->
        items_opt = disposition_to_items_opt(disp, target_uuid)

        if is_nil(items_opt) do
          {:noreply, socket}
        else
          socket
          |> assign(:trash_modal, nil)
          |> do_bulk_trash_categories_with(uuids, items_opt)
        end

      %{category: category, disposition: :uncategorize} ->
        socket
        |> assign(:trash_modal, nil)
        |> do_trash_category(category, items: :uncategorize)

      %{category: category, disposition: :move_to, target_uuid: target_uuid}
      when not is_nil(target_uuid) ->
        socket
        |> assign(:trash_modal, nil)
        |> do_trash_category(category, items: {:move_to, target_uuid})

      %{category: category, disposition: :cascade} ->
        socket
        |> assign(:trash_modal, nil)
        |> do_trash_category(category, items: :cascade)

      _ ->
        # Confirm should be disabled in this state; defensive no-op.
        {:noreply, socket}
    end
  end

  def handle_event("cancel_trash_category", _params, socket) do
    {:noreply, assign(socket, :trash_modal, nil)}
  end

  # ── Bulk selection + actions ────────────────────────────────────

  def handle_event("toggle_select_item", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, :selected_items, toggle(socket.assigns.selected_items, uuid))}
  end

  def handle_event("toggle_select_category", %{"uuid" => uuid}, socket) do
    {:noreply,
     assign(socket, :selected_categories, toggle(socket.assigns.selected_categories, uuid))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     assign(socket,
       selected_items: MapSet.new(),
       selected_categories: MapSet.new()
     )}
  end

  # Bulk delete items — opens a confirm modal stamped with the selection
  # and the operation type. The active list (core toolkit) supplies the
  # uuids client-side via `%{"uuids" => [...]}`; the deleted list (still
  # server-side select) falls back to the `@selected_items` MapSet.
  # Confirmation routes through `confirm_bulk_action` below.
  def handle_event("request_bulk_delete_items", params, socket) do
    uuids = resolve_bulk_uuids(params, socket)

    if uuids == [] do
      {:noreply, socket}
    else
      mode =
        if socket.assigns.view_mode == "deleted",
          do: :permanent,
          else: :trash

      {:noreply,
       assign(socket, :bulk_confirm, %{
         kind: :items,
         mode: mode,
         count: length(uuids),
         uuids: uuids
       })}
    end
  end

  def handle_event("request_bulk_restore_items", params, socket) do
    uuids = resolve_bulk_uuids(params, socket)
    if uuids == [], do: {:noreply, socket}, else: do_bulk_restore_items(socket, uuids)
  end

  def handle_event("request_bulk_move_items", params, socket) do
    uuids = resolve_bulk_uuids(params, socket)

    if uuids == [] do
      {:noreply, socket}
    else
      targets =
        socket.assigns.catalogue_uuid
        |> Catalogue.list_category_tree(mode: :active)

      {:noreply,
       assign(socket, :bulk_move_modal, %{
         count: length(uuids),
         uuids: uuids,
         targets: targets,
         disposition: :uncategorize,
         target_uuid: nil
       })}
    end
  end

  def handle_event("set_bulk_move_disposition", %{"disposition" => disp}, socket) do
    modal = socket.assigns.bulk_move_modal || %{}

    new_modal =
      case disp do
        "uncategorize" -> %{modal | disposition: :uncategorize, target_uuid: nil}
        "move_to" -> %{modal | disposition: :move_to}
        _ -> modal
      end

    {:noreply, assign(socket, :bulk_move_modal, new_modal)}
  end

  def handle_event("select_bulk_move_target", %{"category_uuid" => uuid}, socket) do
    modal = socket.assigns.bulk_move_modal || %{}

    {:noreply,
     assign(socket, :bulk_move_modal, %{modal | target_uuid: Values.blank_to_nil(uuid)})}
  end

  def handle_event("confirm_bulk_move_items", _params, socket) do
    case socket.assigns.bulk_move_modal do
      %{disposition: :uncategorize, uuids: uuids} ->
        do_bulk_move_items(socket, uuids, nil)

      %{disposition: :move_to, target_uuid: target_uuid, uuids: uuids}
      when not is_nil(target_uuid) ->
        do_bulk_move_items(socket, uuids, target_uuid)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_bulk_move", _params, socket) do
    {:noreply, assign(socket, :bulk_move_modal, nil)}
  end

  def handle_event("confirm_bulk_action", _params, socket) do
    case socket.assigns.bulk_confirm do
      %{kind: :items, mode: :trash, uuids: uuids} ->
        do_bulk_trash_items(socket, uuids)

      %{kind: :items, mode: :permanent, uuids: uuids} ->
        do_bulk_permanent_delete_items(socket, uuids)

      %{kind: :categories} ->
        do_bulk_trash_categories(socket)

      _ ->
        {:noreply, assign(socket, :bulk_confirm, nil)}
    end
  end

  def handle_event("cancel_bulk_action", _params, socket) do
    {:noreply, assign(socket, :bulk_confirm, nil)}
  end

  # Bulk delete categories: routes through trash_modal with bulk: true
  # so the disposition picker is shared with the single-category flow.
  def handle_event("request_bulk_delete_categories", _params, socket) do
    uuids = socket.assigns.selected_categories |> MapSet.to_list()

    if uuids == [] do
      {:noreply, socket}
    else
      # The bulk modal needs at least one category struct for the
      # name preview + same-catalogue target list. Pull one and use
      # it as the surface.
      case Catalogue.get_category(hd(uuids)) do
        nil ->
          {:noreply, socket}

        category ->
          {:noreply,
           assign(socket, :trash_modal, %{
             category: category,
             item_count: bulk_subtree_item_count(uuids),
             targets: Catalogue.list_move_target_categories(category),
             disposition: :uncategorize,
             target_uuid: nil,
             bulk: true,
             bulk_uuids: uuids
           })}
      end
    end
  end

  def handle_event("request_bulk_restore_categories", _params, socket) do
    uuids = socket.assigns.selected_categories |> MapSet.to_list()
    if uuids == [], do: {:noreply, socket}, else: do_bulk_restore_categories(socket, uuids)
  end

  def handle_event("restore_category", %{"uuid" => uuid}, socket) do
    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.restore_category(category, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category restored."))
       |> reset_and_load()}
    else
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")
         )}

      {:error, :parent_catalogue_deleted} ->
        {:noreply, put_flash(socket, :error, Errors.message(:parent_catalogue_deleted))}

      {:error, reason} ->
        log_operation_error(socket, "restore_category", %{
          entity_type: "category",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to restore category.")
         )}
    end
  end

  def handle_event("permanently_delete_category", _params, socket) do
    case socket.assigns.confirm_delete do
      {"category", uuid} ->
        with %{} = category <- Catalogue.get_category(uuid),
             {:ok, _} <- Catalogue.permanently_delete_category(category, actor_opts(socket)) do
          {:noreply,
           socket
           |> assign(:confirm_delete, nil)
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category permanently deleted.")
           )
           |> reset_and_load()}
        else
          nil ->
            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")
             )}

          {:error, reason} ->
            log_operation_error(socket, "permanently_delete_category", %{
              entity_type: "category",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete category.")
             )}
        end

      _ ->
        unexpected_confirm_event(socket, "permanently_delete_category")
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event("reorder_categories", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    apply_category_reorder(socket, ordered_ids, params["moved_id"])
  end

  # DnD reorder of the active item list. The drill view is always one
  # node, so scope comes from socket assigns (the current node), NOT
  # from DOM attrs — core `<.sortable_tbody>` doesn't carry the
  # catalogue's `data-sortable-scope-*` attrs.
  def handle_event("reorder_items", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    catalogue_uuid = socket.assigns.catalogue_uuid
    category_uuid = Catalogue.normalize_category_uuid(socket.assigns.current_category)
    moved_id = params["moved_id"]

    apply_in_scope_item_reorder(socket, catalogue_uuid, category_uuid, ordered_ids, moved_id)
  end

  # ── Active item list: sort + strategy reorder ────────────────────

  # Sort selector (field <select> + direction arrow). The select sends
  # `%{"sort_by" => ...}`, the arrow `%{"sort_dir" => ...}` — derive the
  # missing half from assigns (race-free, see SortSelector docs). Field
  # is whitelist-validated; direction is only `:asc`/`:desc`.
  def handle_event("sort_items", params, socket) do
    field =
      case params["sort_by"] do
        f when f in @items_sort_field_strs -> String.to_existing_atom(f)
        _ -> socket.assigns.items_sort_by
      end

    dir =
      case params["sort_dir"] do
        "desc" -> :desc
        "asc" -> :asc
        _ -> socket.assigns.items_sort_dir
      end

    {:noreply, socket |> apply_items_sort(field, dir) |> persist_detail_sort(:detail_items)}
  end

  # Categories sort — same SortSelector contract as items/catalogues
  # (select sends only sort_by, the arrow only sort_dir). Hardcoded
  # whitelist; drag + Reorder-all only make sense in manual mode.
  def handle_event("sort_categories", params, socket) do
    field =
      case params["sort_by"] do
        "position" -> :position
        "name" -> :name
        "items" -> :items
        "updated" -> :updated
        _ -> socket.assigns.categories_sort_by
      end

    dir =
      case params["sort_dir"] do
        "desc" -> :desc
        "asc" -> :asc
        _ -> socket.assigns.categories_sort_dir
      end

    socket =
      socket
      |> assign(categories_sort_by: field, categories_sort_dir: dir)
      |> persist_detail_sort(:detail_categories)

    {:noreply,
     assign(
       socket,
       :child_categories,
       sort_categories(socket.assigns.child_categories, socket.assigns.child_counts, field, dir)
     )}
  end

  # Sortable column header click — toggles direction on the active field,
  # otherwise switches field (ascending).
  # ── Columns configuration (per-user, ViewConfig) — one modal serving
  # both detail scopes; `column_modal_scope` says which table it edits. ──

  def handle_event("show_column_modal", %{"scope" => scope_str}, socket)
      when scope_str in ~w(detail_items detail_categories) do
    scope = String.to_existing_atom(scope_str)

    {:noreply,
     assign(socket,
       column_modal_scope: scope,
       temp_columns: current_scope_columns(socket, scope)
     )}
  end

  def handle_event("hide_column_modal", _p, socket),
    do: {:noreply, assign(socket, column_modal_scope: nil, temp_columns: nil)}

  def handle_event("add_column", %{"column_id" => id}, socket) do
    {:noreply, update(socket, :temp_columns, &((&1 || []) ++ [id]))}
  end

  def handle_event("remove_column", %{"column_id" => id}, socket) do
    {:noreply, update(socket, :temp_columns, &Enum.reject(&1 || [], fn c -> c == id end))}
  end

  def handle_event("reorder_columns", %{"ordered_ids" => ids}, socket) when is_list(ids) do
    {:noreply, assign(socket, :temp_columns, ids)}
  end

  def handle_event("reset_columns", _p, socket) do
    case socket.assigns.column_modal_scope do
      nil ->
        {:noreply, socket}

      scope ->
        {:noreply, assign(socket, :temp_columns, TableConfig.default_columns(scope))}
    end
  end

  def handle_event("apply_columns", params, socket) do
    case socket.assigns.column_modal_scope do
      nil ->
        {:noreply, socket}

      scope ->
        ids =
          TableConfig.validate_columns(
            scope,
            params["ordered_ids"] || socket.assigns.temp_columns || []
          )

        ids = if ids == [], do: TableConfig.default_columns(scope), else: ids

        user = socket.assigns[:phoenix_kit_current_user]
        cfg = %{ViewConfig.load(user, scope) | columns: ids}
        ViewConfig.save(user, scope, cfg)

        assigns_key = if scope == :detail_items, do: :items_columns, else: :categories_columns

        {:noreply,
         socket
         |> assign(assigns_key, ids)
         |> assign(column_modal_scope: nil, temp_columns: nil)}
    end
  end

  def handle_event("toggle_sort_items", %{"by" => field_str}, socket)
      when field_str in @items_sort_field_strs do
    field = String.to_existing_atom(field_str)

    dir =
      if field == socket.assigns.items_sort_by do
        if socket.assigns.items_sort_dir == :asc, do: :desc, else: :asc
      else
        :asc
      end

    {:noreply, socket |> apply_items_sort(field, dir) |> persist_detail_sort(:detail_items)}
  end

  def handle_event("toggle_sort_items", _params, socket), do: {:noreply, socket}

  # Open the strategy-reorder modal. Captures the client-side selection
  # (via the BulkSelectScope hook payload). A 0–1 selection collapses to
  # "reorder all" (stored as `[]`) — a single-row reorder is a no-op.
  def handle_event("open_categories_reorder_modal", _params, socket) do
    {:noreply, assign(socket, :show_categories_reorder, true)}
  end

  def handle_event("close_categories_reorder_modal", _params, socket) do
    {:noreply, assign(socket, :show_categories_reorder, false)}
  end

  # Strategy reorder for the current level's sibling categories ("Reorder
  # all" next to the category list). `@child_categories` is the full,
  # unpaginated sibling set, so re-indexing it can't collide with unseen
  # rows; `Catalogue.reorder_categories/4` re-asserts siblinghood anyway.
  def handle_event("apply_categories_reorder", %{"strategy" => strategy_str}, socket)
      when is_map_key(@items_reorder_strategy_map, strategy_str) do
    strategy = Map.fetch!(@items_reorder_strategy_map, strategy_str)

    ordered =
      socket.assigns.child_categories
      |> order_categories_for_strategy(strategy)
      |> Enum.map(& &1.uuid)

    parent_uuid =
      case socket.assigns.current_category do
        %Category{uuid: uuid} -> uuid
        _ -> nil
      end

    case Catalogue.reorder_categories(
           socket.assigns.catalogue_uuid,
           parent_uuid,
           ordered,
           actor_opts(socket)
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(:show_categories_reorder, false)
         |> put_flash(
           :info,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Categories reordered.")
         )
         |> reset_and_load()}

      {:error, reason} ->
        log_operation_error(socket, "apply_categories_reorder", %{reason: reason})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to reorder.")
         )}
    end
  end

  def handle_event("apply_categories_reorder", _params, socket), do: {:noreply, socket}

  def handle_event("open_items_reorder_modal", params, socket) do
    captured =
      case sanitize_uuids(params) do
        list when length(list) < 2 -> []
        list -> list
      end

    {:noreply, assign(socket, show_items_reorder: true, reorder_captured_uuids: captured)}
  end

  def handle_event("close_items_reorder_modal", _params, socket) do
    {:noreply, assign(socket, show_items_reorder: false, reorder_captured_uuids: [])}
  end

  def handle_event("apply_items_reorder", %{"strategy" => strategy_str}, socket)
      when is_map_key(@items_reorder_strategy_map, strategy_str) do
    strategy = Map.fetch!(@items_reorder_strategy_map, strategy_str)

    scope =
      case socket.assigns.reorder_captured_uuids do
        [] -> :all
        uuids -> uuids
      end

    catalogue_uuid = socket.assigns.catalogue_uuid
    category_uuid = Catalogue.normalize_category_uuid(socket.assigns.current_category)

    case Catalogue.reorder_items_by(
           catalogue_uuid,
           category_uuid,
           strategy,
           scope,
           actor_opts(socket)
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items reordered."))
         |> assign(show_items_reorder: false, reorder_captured_uuids: [])
         |> push_event("bulk_select:clear", %{})
         |> reset_and_load()}

      {:error, :duplicate_positions} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Selected items share positions. Apply \"Reorder all\" first to normalise."
           )
         )}

      {:error, reason} ->
        log_operation_error(socket, "reorder_items_by", %{reason: reason})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to reorder items.")
         )}
    end
  end

  def handle_event("apply_items_reorder", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pick a strategy before applying.")
     )}
  end

  # ── Bulk-action helpers ──────────────────────────────────────────

  defp toggle(set, uuid) do
    if MapSet.member?(set, uuid), do: MapSet.delete(set, uuid), else: MapSet.put(set, uuid)
  end

  # Resolves the target uuids for a bulk op. The active list (core
  # toolkit) supplies them client-side via `%{"uuids" => [...]}`; the
  # deleted list (still server-side select) falls back to the
  # `@selected_items` MapSet.
  defp resolve_bulk_uuids(%{"uuids" => _} = params, _socket), do: sanitize_uuids(params)
  defp resolve_bulk_uuids(_params, socket), do: MapSet.to_list(socket.assigns.selected_items)

  defp sanitize_uuids(%{"uuids" => uuids}) when is_list(uuids),
    do: Enum.filter(uuids, &is_binary/1)

  defp sanitize_uuids(_), do: []

  # Clears both selection models after a bulk op: the server-side MapSet
  # (deleted list) and the client-side BulkSelectScope (active list).
  defp clear_item_selection(socket) do
    socket
    |> assign(:selected_items, MapSet.new())
    |> push_event("bulk_select:clear", %{})
  end

  # Sort change resets the item offset to 0 and reloads page 1 — else
  # infinite-scroll would stitch the new order onto a stale prefix.
  defp apply_items_sort(socket, field, dir) do
    socket
    |> assign(items_sort_by: field, items_sort_dir: dir, items_offset: 0)
    |> reset_and_load()
  end

  # ── Shared (all-user) detail sorts — same mechanism as the catalogues
  # index: the setting is the source of truth, changes broadcast so open
  # sessions follow live, and mount reads it back. ──────────────────

  # Accepts the socket (event handlers) or the assigns map (templates).
  defp current_scope_columns(%Phoenix.LiveView.Socket{} = socket, scope),
    do: current_scope_columns(socket.assigns, scope)

  defp current_scope_columns(assigns, :detail_items), do: assigns.items_columns
  defp current_scope_columns(assigns, :detail_categories), do: assigns.categories_columns

  defp persist_detail_sort(socket, :detail_items) do
    by = Atom.to_string(socket.assigns.items_sort_by)
    dir = socket.assigns.items_sort_dir
    ViewConfig.save_global_sort(:detail_items, by, dir)
    PubSub.broadcast_view_sort_changed(:detail_items, by, dir)
    socket
  end

  defp persist_detail_sort(socket, :detail_categories) do
    by = Atom.to_string(socket.assigns.categories_sort_by)
    dir = socket.assigns.categories_sort_dir
    ViewConfig.save_global_sort(:detail_categories, by, dir)
    PubSub.broadcast_view_sort_changed(:detail_categories, by, dir)
    socket
  end

  defp apply_global_detail_sorts(socket) do
    {items_by, items_dir} = ViewConfig.load_global_sort(:detail_items)
    {cats_by, cats_dir} = ViewConfig.load_global_sort(:detail_categories)

    assign(socket,
      items_sort_by: detail_items_sort_field(items_by),
      items_sort_dir: items_dir,
      categories_sort_by: detail_categories_sort_field(cats_by),
      categories_sort_dir: cats_dir
    )
  end

  # Stored ids are validated by ViewConfig against TableConfig's
  # sortable columns for the scope, so these total maps only ever see
  # known ids — the fallbacks are for defense, not routing.
  defp detail_items_sort_field(by)
       when by in ~w(position name sku base_price status),
       do: String.to_existing_atom(by)

  defp detail_items_sort_field(_), do: :position

  defp detail_categories_sort_field(by)
       when by in ~w(position name items updated),
       do: String.to_existing_atom(by)

  defp detail_categories_sort_field(_), do: :position

  defp disposition_to_items_opt(:uncategorize, _), do: :uncategorize
  defp disposition_to_items_opt(:cascade, _), do: :cascade
  defp disposition_to_items_opt(:move_to, target) when not is_nil(target), do: {:move_to, target}
  defp disposition_to_items_opt(_, _), do: nil

  defp bulk_subtree_item_count(uuids) do
    Enum.reduce(uuids, 0, fn uuid, acc ->
      acc + Catalogue.active_item_count_in_subtree(uuid)
    end)
  end

  # Active-list bulk ops read the client-captured uuids; deleted-list
  # bulk ops pass `@selected_items`. After each op we clear BOTH the
  # server-side MapSet (deleted list) AND push `bulk_select:clear` so a
  # stale client-side checkmark can't persist on the active list.
  defp do_bulk_trash_items(socket, uuids) do
    {count, _} = Catalogue.bulk_trash_items(uuids, actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :trashed, uuids)

    socket
    |> assign(:bulk_confirm, nil)
    |> clear_item_selection()
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted %{count} items.", count: count)
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_permanent_delete_items(socket, uuids) do
    {count, _} = Catalogue.bulk_permanently_delete_items(uuids, actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :permanent_delete, uuids)

    socket
    |> assign(:bulk_confirm, nil)
    |> clear_item_selection()
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently deleted %{count} items.",
        count: count
      )
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_restore_items(socket, uuids) do
    {count, _} = Catalogue.bulk_restore_items(uuids, actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :restored, uuids)

    socket
    |> clear_item_selection()
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restored %{count} items.", count: count)
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_move_items(socket, uuids, target_uuid) do
    opts =
      actor_opts(socket) |> Keyword.put(:catalogue_uuid, socket.assigns.catalogue_uuid)

    case Catalogue.bulk_move_items_to_category(uuids, target_uuid, opts) do
      {:ok, count} ->
        # `:moved` triggers the receiver's full red-fade → refresh →
        # green-fade sequence on every other open tab.
        PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :moved, uuids)

        socket
        |> assign(:bulk_move_modal, nil)
        |> clear_item_selection()
        |> put_flash(
          :info,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moved %{count} items.", count: count)
        )
        |> reset_and_load()
        |> then(&{:noreply, &1})

      {:error, :category_not_found} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Target category not found.")
         )}

      {:error, scope_err} when scope_err in [:wrong_catalogue_scope, :missing_catalogue_scope] ->
        log_operation_error(socket, "bulk_move_items_to_category", %{reason: scope_err})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Items can only be moved within this catalogue."
           )
         )}
    end
  end

  defp do_bulk_trash_categories(socket) do
    # Without a disposition picker, default cascade. The bulk modal
    # path goes through confirm_trash_category instead.
    do_bulk_trash_categories_with(
      socket,
      socket.assigns.selected_categories |> MapSet.to_list(),
      :cascade
    )
  end

  defp do_bulk_trash_categories_with(socket, uuids, items_opt) do
    case Catalogue.bulk_trash_categories(uuids, items_opt, actor_opts(socket)) do
      {:ok, %{categories: count}} ->
        socket
        |> assign(:bulk_confirm, nil)
        |> assign(:selected_categories, MapSet.new())
        |> put_flash(
          :info,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted %{count} categories.",
            count: count
          )
        )
        |> reset_and_load()
        |> then(&{:noreply, &1})

      {:error, reason} ->
        log_operation_error(socket, "bulk_trash_categories", %{reason: reason})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete categories.")
         )}
    end
  end

  defp do_bulk_restore_categories(socket, uuids) do
    {ok, errors} =
      Enum.reduce(uuids, {0, []}, fn uuid, {ok, errs} ->
        with %{} = category <- Catalogue.get_category(uuid),
             {:ok, _} <- Catalogue.restore_category(category, actor_opts(socket)) do
          {ok + 1, errs}
        else
          {:error, reason} -> {ok, [reason | errs]}
          _ -> {ok, errs}
        end
      end)

    socket =
      socket
      |> assign(:selected_categories, MapSet.new())
      |> put_flash(
        :info,
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restored %{count} categories.", count: ok)
      )
      |> reset_and_load()

    if errors == [] do
      {:noreply, socket}
    else
      log_operation_error(socket, "bulk_restore_categories_partial", %{reasons: errors})

      {:noreply,
       put_flash(
         socket,
         :error,
         Gettext.gettext(
           PhoenixKitCatalogue.Gettext,
           "Some categories couldn't be restored. The catalogue may be deleted — restore it first."
         )
       )}
    end
  end

  defp build_trash_modal_state(%Category{} = category, item_count) do
    %{
      category: category,
      item_count: item_count,
      targets: Catalogue.list_move_target_categories(category),
      disposition: :uncategorize,
      target_uuid: nil
    }
  end

  defp do_trash_category(socket, category, opts) do
    full_opts = Keyword.merge(opts, actor_opts(socket))

    case Catalogue.trash_category(category, full_opts) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved to deleted.")
         )
         |> reset_and_load()}

      {:error, reason} ->
        log_operation_error(socket, "trash_category", %{
          entity_type: "category",
          entity_uuid: category.uuid,
          reason: reason
        })

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete category.")
         )}
    end
  end

  defp apply_in_scope_item_reorder(socket, catalogue_uuid, category_uuid, ordered_ids, moved_id) do
    # Dropped back in the same place — the order is unchanged, so skip the
    # DB write, PubSub broadcast, and flash entirely.
    if ordered_ids == Enum.map(socket.assigns.items, & &1.uuid) do
      {:noreply, socket}
    else
      do_in_scope_item_reorder(socket, catalogue_uuid, category_uuid, ordered_ids, moved_id)
    end
  end

  defp do_in_scope_item_reorder(socket, catalogue_uuid, category_uuid, ordered_ids, moved_id) do
    case Catalogue.reorder_items(
           catalogue_uuid,
           category_uuid,
           ordered_ids,
           actor_opts(socket)
         ) do
      :ok ->
        scope = category_uuid || :uncategorized
        # Tell other open detail tabs to refresh this card + flash.
        PubSub.broadcast_card_refresh(catalogue_uuid, scope, moved_id, :ok)

        {:noreply,
         socket
         |> refresh_card_items(scope)
         |> flash_reorder(moved_id, :ok)}

      {:error, reason} ->
        log_operation_error(socket, "reorder_items", %{reason: reason})

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to reorder items.")
         )
         |> reset_and_load()
         |> flash_reorder(moved_id, :error)}
    end
  end

  # Pushes the `sortable:flash` event the SortableGrid hook listens for.
  # `moved_id` may be nil if a stale client missed the JS-side update;
  # we no-op in that case so the success/error flash isn't required.
  defp flash_reorder(socket, nil, _status), do: socket

  defp flash_reorder(socket, moved_id, status) when is_binary(moved_id) do
    push_event(socket, "sortable:flash", %{uuid: moved_id, status: to_string(status)})
  end

  # ── Helpers ─────────────────────────────────────────────────────

  # Graceful handler for an unreachable UI state: a delete event fires
  # while `confirm_delete` is nil (e.g. someone pushed the event without
  # first opening the modal). Clears the state, flashes a warning, and
  # logs a warning so we can see it in production without crashing the
  # LV and dropping the user's unrelated in-flight state.
  defp unexpected_confirm_event(socket, event_name) do
    Logger.warning(
      "Catalogue detail LV: #{event_name} fired without confirm_delete — assigns=#{inspect(socket.assigns.confirm_delete)} actor_uuid=#{inspect(actor_uuid(socket))}"
    )

    {:noreply,
     socket
     |> assign(:confirm_delete, nil)
     |> put_flash(
       :error,
       Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unexpected request. Please try again.")
     )}
  end

  # actor_opts/1, actor_uuid/1, and log_operation_error/3 imported from
  # PhoenixKitCatalogue.Web.Helpers.

  # Reloads the whole drill level from scratch (item list back to page 1).
  # Called after any structural change — drilling, view switch, trash /
  # restore / reorder.
  defp reset_and_load(socket) do
    socket
    |> load_level(@per_page)
    |> maybe_auto_flip_to_active()
  end

  # Loads everything the current level renders for the active view_mode:
  # catalogue + breadcrumb, the direct child categories (drill cards) with
  # their item counts and has-subcategories flags, the root-only
  # Uncategorized card count, the current node's own direct items (first
  # `item_limit`), and the per-level Active/Deleted counts that drive the
  # toggle labels + auto-flip. `item_limit` lets a PubSub refresh preserve
  # the user's scroll depth instead of snapping back to page 1.
  defp load_level(socket, item_limit) do
    uuid = socket.assigns.catalogue_uuid
    catalogue = Catalogue.fetch_catalogue!(uuid)
    current = socket.assigns.current_category

    # Per-status item counts for the current node — drive the tab labels and
    # the default-tab pick below.
    status_counts = node_status_counts(current, uuid)

    # `status` is the exact item status shown. The root is a pure navigation
    # step (always Active, no tabs). Inside a node we auto-select a populated
    # tab: keep the chosen status if it has items, else fall to the first one
    # that does — so e.g. a category with only deleted items opens straight on
    # Deleted instead of an empty Active. `cat_mode` is the active/deleted
    # bucket for the (status-less) subcategory cards.
    status =
      if is_nil(current),
        do: "active",
        else: effective_view_mode(socket.assigns.view_mode, status_counts)

    socket = assign(socket, :view_mode, status)
    cat_mode = view_mode_to_atom(status)
    show_categories? = status in ["active", "deleted"]

    {child_categories, children_with_subs} =
      if show_categories?,
        do: load_level_children(uuid, current, cat_mode),
        else: {[], MapSet.new()}

    {counts_map, subcat_counts} = level_count_maps(uuid, cat_mode, show_categories?)

    uncat_active = Catalogue.uncategorized_count_for_catalogue(uuid, mode: :active)

    node_total = Map.get(status_counts, status, 0)

    # Active root with categories shows only cards (its uncategorized items
    # are reached via the Uncategorized card). Every other case — a drilled
    # node, or any non-active tab, or an empty active root with loose items —
    # shows the node's own item list.
    show_items_section =
      current != nil or status != "active" or
        (child_categories == [] and node_total > 0)

    items =
      if show_items_section and node_total > 0,
        do:
          fetch_card_items(
            node_scope(current),
            uuid,
            status,
            item_limit,
            0,
            items_sort_opts(socket)
          ),
        else: []

    assign(socket,
      page_title: catalogue.name,
      catalogue: catalogue,
      breadcrumb: build_breadcrumb(current, cat_mode),
      child_categories:
        sort_categories(
          child_categories,
          counts_map,
          socket.assigns.categories_sort_by,
          socket.assigns.categories_sort_dir
        ),
      child_counts: counts_map,
      children_with_subs: children_with_subs,
      child_subcat_counts: subcat_counts,
      uncategorized_active_count: uncat_active,
      items: items,
      edit_path_fn:
        item_edit_with_return(%{current_category: current, catalogue_uuid: catalogue.uuid}),
      file_counts:
        socket.assigns.file_counts
        |> Map.merge(Catalogue.attached_file_counts(items))
        |> Map.merge(Catalogue.attached_file_counts(child_categories)),
      attribute_map:
        Map.merge(
          socket.assigns.attribute_map,
          Catalogue.item_attribute_group_map(Enum.map(items, & &1.uuid))
        ),
      items_total: node_total,
      items_offset: length(items),
      items_has_more: length(items) < node_total,
      show_items_section: show_items_section,
      level_status_counts: status_counts,
      status_tabs: visible_status_tabs(status, status_counts)
    )
  end

  # The child categories shown at this level (in the current `mode` only)
  # plus the set of those with their own sub-children. The uncategorized
  # bucket has none. `mode` is always `:active`/`:deleted` here (the caller
  # only loads children on those tabs). Active mode reuses orphan
  # promotion; deleted mode is strict (see `list_child_categories/3`).
  # `@child_counts` / `@child_subcat_counts` are read only inside the
  # category rows, which are empty unless categories show — skip both
  # whole-catalogue GROUP BYs on the inactive/discontinued tabs.
  defp level_count_maps(uuid, cat_mode, true) do
    {Catalogue.item_counts_by_category_for_catalogue(uuid, mode: cat_mode),
     Catalogue.category_children_counts(uuid, mode: cat_mode)}
  end

  defp level_count_maps(_uuid, _cat_mode, false), do: {%{}, %{}}

  defp load_level_children(_uuid, :uncategorized, _mode), do: {[], MapSet.new()}

  defp load_level_children(uuid, current, mode) do
    parent_uuid = node_parent_uuid(current)
    shown = Catalogue.list_child_categories(uuid, parent_uuid, mode: mode)
    subs = Catalogue.category_uuids_with_children(uuid, mode: mode)
    {shown, subs}
  end

  # The current node's own direct-item counts in both modes. Root and the
  # uncategorized bucket count the uncategorized items; a category counts
  # its own direct items.
  # `%{status => count}` for the current node's own direct items — drives
  # the four per-status tabs. Root and the Uncategorized bucket both count
  # the catalogue's uncategorized items.
  defp node_status_counts(%Category{uuid: u}, _catalogue_uuid),
    do: Catalogue.item_status_counts_for_category(u)

  defp node_status_counts(_current, catalogue_uuid),
    do: Catalogue.item_status_counts_for_uncategorized(catalogue_uuid)

  # Loads the next page of the current node's own items (the bottom
  # sentinel during normal browsing — search paging is separate).
  defp load_next_items_page(socket) do
    current = socket.assigns.current_category
    status = socket.assigns.view_mode
    offset = socket.assigns.items_offset

    page =
      fetch_card_items(
        node_scope(current),
        socket.assigns.catalogue_uuid,
        status,
        @per_page,
        offset,
        items_sort_opts(socket)
      )

    new_offset = offset + length(page)

    assign(socket,
      items: socket.assigns.items ++ page,
      file_counts: Map.merge(socket.assigns.file_counts, Catalogue.attached_file_counts(page)),
      attribute_map:
        Map.merge(
          socket.assigns.attribute_map,
          Catalogue.item_attribute_group_map(Enum.map(page, & &1.uuid))
        ),
      items_offset: new_offset,
      items_has_more: page != [] and new_offset < socket.assigns.items_total
    )
  end

  # Parent scope of a node for the child-categories query.
  defp node_parent_uuid(nil), do: nil
  defp node_parent_uuid(:uncategorized), do: nil
  defp node_parent_uuid(%Category{uuid: uuid}), do: uuid

  # The item-fetch scope of a node: a category UUID, or `:uncategorized`
  # for the root (whose own items are the uncategorized ones) and the
  # uncategorized bucket.
  defp node_scope(nil), do: :uncategorized
  defp node_scope(:uncategorized), do: :uncategorized
  defp node_scope(%Category{uuid: uuid}), do: uuid

  # Breadcrumb ancestors above the current node (root + current excluded).
  # In Active mode the chain is trimmed to its contiguous active suffix:
  # an orphan promoted to root (its parent trashed) gets an empty chain,
  # so it renders as `Catalogue ▸ <current>` — never a dead link to a
  # deleted ancestor. In Deleted mode the full chain shows (each crumb
  # drills within deleted mode).
  defp build_breadcrumb(%Category{} = cat, :active) do
    cat.uuid
    |> Catalogue.list_category_ancestors()
    |> Enum.reverse()
    |> Enum.take_while(&(&1.status == "active"))
    |> Enum.reverse()
  end

  defp build_breadcrumb(%Category{} = cat, :deleted),
    do: Catalogue.list_category_ancestors(cat.uuid)

  defp build_breadcrumb(_current, _mode), do: []

  # Reloads the current level after a mutation but keeps the user's
  # scroll depth — re-fetches at least as many items as are currently
  # loaded instead of snapping back to page 1 — then runs the auto-flip.
  defp refresh_counts(socket) do
    socket
    |> load_level(max(socket.assigns.items_offset, @per_page))
    |> maybe_auto_flip_to_active()
  end

  # When a mutation (restore / trash / permanent-delete) empties the
  # current non-Active status tab, flip the view back to Active so the
  # user isn't stranded on an empty tab. Runs only after `load_level` has
  # refreshed `items_total` (items of the current status) and
  # `child_categories` (the deleted subcategories shown in the Deleted
  # tab), so a tab that still lists deleted subcategories — even with no
  # items of its own — correctly stays put.
  defp maybe_auto_flip_to_active(%{assigns: %{view_mode: "active"}} = socket), do: socket

  defp maybe_auto_flip_to_active(socket) do
    if socket.assigns.items_total == 0 and socket.assigns.child_categories == [] do
      socket
      |> assign(:view_mode, "active")
      |> load_level(@per_page)
    else
      socket
    end
  end

  # PubSub-driven refresh. Reloads the current level preserving scroll
  # depth so a cross-tab broadcast (another admin, the import wizard)
  # doesn't collapse a deep item scroll. The `Ecto.NoResultsError` rescue
  # in the caller handles the catalogue-was-deleted-elsewhere edge case.
  defp refresh_in_place(socket), do: refresh_counts(socket)

  # Runs a fresh search query asynchronously. If a prior search is still
  # in flight, `start_async/3` cancels it — so fast typing (type-pause-
  # type-pause) doesn't flash stale intermediate results as each old
  # request lands out of order. The actual assign happens in
  # `handle_async(:search, ...)`, guarded by a query equality check.
  defp run_search(socket, query) do
    uuid = socket.assigns.catalogue_uuid
    current = socket.assigns.current_category

    socket
    |> assign(search_query: query, search_loading: true)
    |> start_async(:search, fn ->
      results = search_in_scope(uuid, current, query, @per_page, 0)
      total = search_count_in_scope(uuid, current, query)
      {query, results, total}
    end)
  end

  # Search scope follows the drill level: catalogue-wide at root, the
  # category's subtree when drilled in (`search_items_in_category/3`
  # defaults to `include_descendants: true`), and uncategorized-only in
  # the uncategorized bucket. Search is Active-mode only (the context
  # search excludes deleted rows), so the input is hidden in Deleted view.
  defp search_in_scope(uuid, nil, query, limit, offset),
    do: Catalogue.search_items_in_catalogue(uuid, query, limit: limit, offset: offset)

  defp search_in_scope(uuid, :uncategorized, query, limit, offset),
    do:
      Catalogue.search_items(query,
        catalogue_uuids: [uuid],
        only: :uncategorized_only,
        limit: limit,
        offset: offset
      )

  defp search_in_scope(_uuid, %Category{uuid: cuuid}, query, limit, offset),
    do: Catalogue.search_items_in_category(cuuid, query, limit: limit, offset: offset)

  defp search_count_in_scope(uuid, nil, query),
    do: Catalogue.count_search_items_in_catalogue(uuid, query)

  defp search_count_in_scope(uuid, :uncategorized, query),
    do: Catalogue.count_search_items(query, catalogue_uuids: [uuid], only: :uncategorized_only)

  defp search_count_in_scope(_uuid, %Category{uuid: cuuid}, query),
    do: Catalogue.count_search_items_in_category(cuuid, query)

  @impl true
  def handle_async(:search, {:ok, {query, results, total}}, socket) do
    # Only apply if the user is still asking for this query. A late
    # response for a query the user has already superseded gets dropped.
    if socket.assigns.search_query == query do
      {:noreply,
       assign(socket,
         search_results: results,
         file_counts:
           Map.merge(socket.assigns.file_counts, Catalogue.attached_file_counts(results)),
         attribute_map:
           Map.merge(
             socket.assigns.attribute_map,
             Catalogue.item_attribute_group_map(Enum.map(results, & &1.uuid))
           ),
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
        Logger.warning(
          "Catalogue detail LV search task exited unexpectedly: reason=#{inspect(other)} query=#{inspect(socket.assigns.search_query)} catalogue_uuid=#{inspect(socket.assigns.catalogue_uuid)} actor_uuid=#{inspect(actor_uuid(socket))}"
        )

        {:noreply,
         socket
         |> assign(:search_loading, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search failed. Please try again.")
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
         file_counts: Map.merge(socket.assigns.file_counts, Catalogue.attached_file_counts(page)),
         attribute_map:
           Map.merge(
             socket.assigns.attribute_map,
             Catalogue.item_attribute_group_map(Enum.map(page, & &1.uuid))
           ),
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
        Logger.warning(
          "Catalogue detail LV search_page task exited unexpectedly: reason=#{inspect(other)} query=#{inspect(socket.assigns.search_query)} offset=#{socket.assigns.search_offset} catalogue_uuid=#{inspect(socket.assigns.catalogue_uuid)} actor_uuid=#{inspect(actor_uuid(socket))}"
        )

        {:noreply,
         socket
         |> assign(:search_loading, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search failed. Please try again.")
         )}
    end
  end

  # Fires the next-page query off the LV process so scrolling a 50k-item
  # catalogue doesn't freeze the socket on every batch (ILIKE-against-
  # jsonb-as-text is not a fast query). Appending happens in
  # `handle_async(:search_page, …)` guarded by `{query, offset}` so a
  # superseding new search or a double-scroll can't double-append.
  defp start_search_page(socket) do
    %{catalogue_uuid: uuid, current_category: current, search_query: query, search_offset: offset} =
      socket.assigns

    socket
    |> assign(:search_loading, true)
    |> start_async(:search_page, fn ->
      page = search_in_scope(uuid, current, query, @per_page, offset)
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

  # Removes a trashed/restored/deleted item from the current node's item
  # list in place. No DB reload, so scroll position is preserved (the
  # following `refresh_counts` reconciles totals).
  defp remove_item_locally(socket, item_uuid) do
    assign(socket, :items, Enum.reject(socket.assigns.items, &(&1.uuid == item_uuid)))
  end

  # Re-fetches the current node's items after an in-place change (DnD
  # reorder, or a cross-tab reorder broadcast). `scope` identifies which
  # node changed; we only reload when it's the node currently on screen,
  # preserving the loaded slice depth. `delta` is accepted for call-site
  # compatibility but unused — there is one item list now, no cross-card
  # count drift to correct.
  defp refresh_card_items(socket, scope, _delta \\ 0) do
    if scope == node_scope(socket.assigns.current_category) do
      catalogue_uuid = socket.assigns.catalogue_uuid
      status = socket.assigns.view_mode
      limit = max(socket.assigns.items_offset, @per_page)
      fresh = fetch_card_items(scope, catalogue_uuid, status, limit, 0, items_sort_opts(socket))
      total = card_total(scope, catalogue_uuid, status)

      assign(socket,
        items: fresh,
        items_total: total,
        items_offset: length(fresh),
        items_has_more: length(fresh) < total
      )
    else
      socket
    end
  end

  # `status` is the exact item status of the current tab
  # ("active" | "inactive" | "discontinued" | "deleted").
  defp card_total(:uncategorized, catalogue_uuid, status) do
    Catalogue.uncategorized_count_for_catalogue(catalogue_uuid, status: status)
  end

  defp card_total(category_uuid, _catalogue_uuid, status) when is_binary(category_uuid) do
    Catalogue.item_count_for_category(category_uuid, status: status)
  end

  defp fetch_card_items(:uncategorized, catalogue_uuid, status, limit, offset, sort_opts) do
    Catalogue.list_uncategorized_items_paged(
      catalogue_uuid,
      [status: status, offset: offset, limit: limit] ++ sort_opts
    )
  end

  defp fetch_card_items(category_uuid, _catalogue_uuid, status, limit, offset, sort_opts)
       when is_binary(category_uuid) do
    Catalogue.list_items_for_category_paged(
      category_uuid,
      [status: status, offset: offset, limit: limit] ++ sort_opts
    )
  end

  # Sort opts threaded into the active-list paged fetches. Deleted mode
  # keeps the position-default order (the deleted list still renders via
  # the plain item_table without a sort control).
  # The deleted list renders without a sort control; every other status
  # (active/inactive/discontinued) uses the core toolkit table with sorting.
  defp items_sort_opts(%{assigns: %{view_mode: "deleted"}}), do: []

  defp items_sort_opts(socket),
    do: [sort_by: socket.assigns.items_sort_by, sort_dir: socket.assigns.items_sort_dir]

  # Re-fetches the current level's child categories in their new order
  # after a sibling DnD reorder. Items are untouched (reorder of the
  # subcategory cards doesn't affect the node's own item scroll).
  defp refresh_categories_in_place(socket) do
    uuid = socket.assigns.catalogue_uuid
    mode = view_mode_to_atom(socket.assigns.view_mode)

    child_categories =
      if socket.assigns.current_category == :uncategorized,
        do: [],
        else:
          Catalogue.list_child_categories(uuid, node_parent_uuid(socket.assigns.current_category),
            mode: mode
          )

    assign(socket, :child_categories, child_categories)
  end

  # The category bucket for the current view. Categories only have
  # active/deleted, so the inactive/discontinued item tabs reuse the active
  # category set (those tabs hide the category cards anyway).
  defp view_mode_to_atom("deleted"), do: :deleted
  defp view_mode_to_atom(_), do: :active

  # The four item-status tabs (status value + label), in display order.
  defp item_status_tabs do
    [
      {"active", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active")},
      {"inactive", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive")},
      {"discontinued", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discontinued")},
      {"deleted", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted")}
    ]
  end

  defp status_tab_active_class("deleted"), do: "border-error text-error"
  defp status_tab_active_class(_), do: "border-primary text-primary"

  # The status to actually show for a node: keep the selected `view_mode` if it
  # has items, otherwise fall to the first populated status (active → inactive →
  # discontinued → deleted), or "active" when the node is empty in every status.
  defp effective_view_mode(view_mode, counts) do
    if Map.get(counts, view_mode, 0) > 0 do
      view_mode
    else
      item_status_tabs()
      |> Enum.map(&elem(&1, 0))
      |> Enum.find(&(Map.get(counts, &1, 0) > 0))
      |> case do
        nil -> "active"
        populated -> populated
      end
    end
  end

  # `[{status, label, count}]` for the tabs to render — only populated statuses,
  # so an empty Active no longer sits next to a populated Deleted. When nothing
  # is populated, surface just the current tab (count 0) so it's representable;
  # the strip is hidden anyway whenever there's ≤1 tab (see render).
  defp visible_status_tabs(view_mode, counts) do
    item_status_tabs()
    |> Enum.map(fn {status, label} -> {status, label, Map.get(counts, status, 0)} end)
    |> Enum.filter(fn {_status, _label, count} -> count > 0 end)
    |> case do
      [] ->
        label =
          Enum.find_value(item_status_tabs(), fn {status, l} -> status == view_mode && l end) ||
            ""

        [{view_mode, label, 0}]

      tabs ->
        tabs
    end
  end

  # Processes a flat list of category UUIDs that came back from the
  # detail-view DnD. Categories live in a parent-scoped tree, but the
  # client sees them as one ordered list. We group the dropped order by
  # `parent_uuid`, preserve the relative order inside each group, and
  # hand the whole batch to `Catalogue.reorder_categories_groups/3` —
  # one outer transaction so partial failure can't leave the tree in
  # a half-reordered state. UUIDs whose parent changed are silently
  # kept under their original parent — DnD here is for sibling-only
  # reorder, not reparenting.
  defp apply_category_reorder(socket, ordered_ids, moved_id) do
    by_uuid = Map.new(socket.assigns.child_categories, fn %Category{} = c -> {c.uuid, c} end)

    groups =
      ordered_ids
      |> Enum.flat_map(fn id ->
        case Map.fetch(by_uuid, id) do
          {:ok, c} -> [{c.parent_uuid, id}]
          :error -> []
        end
      end)
      |> Enum.group_by(fn {parent_uuid, _id} -> parent_uuid end, fn {_parent, id} -> id end)
      |> Enum.into([])

    result =
      Catalogue.reorder_categories_groups(
        socket.assigns.catalogue_uuid,
        groups,
        actor_opts(socket)
      )

    socket = refresh_categories_in_place(socket)

    case result do
      :ok ->
        # Other open tabs need a full reset_and_load to pick up the new
        # category order — affects how every streamed card renders.
        PubSub.broadcast_category_reorder(socket.assigns.catalogue_uuid, moved_id, :ok)
        {:noreply, flash_reorder(socket, moved_id, :ok)}

      {:error, reason} ->
        log_operation_error(socket, "reorder_categories", %{reason: reason})

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to reorder categories.")
         )
         |> reset_and_load()
         |> flash_reorder(moved_id, :error)}
    end
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_section={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogues")}
      page_section_path={Paths.index()}
      page_subtitle={@current_category && current_node_label(@current_category)}
      current_path={assigns[:url_path] || Paths.index()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full px-4 py-6 gap-6">
        <%!-- Loading state --%>
        <div :if={is_nil(@catalogue)} class="flex justify-center py-12">
          <span class="loading loading-spinner loading-lg"></span>
        </div>

        <div :if={@catalogue} class="flex flex-col gap-6">
          <%!-- In-body header: breadcrumb when drilled into a category
               (catalogue name now lives in the global admin header); action
               buttons whenever the view is active. --%>
          <div
            :if={@view_mode == "active" or @current_category != nil}
            class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-3"
          >
            <%!-- Drill trail — ALWAYS rendered (media-browser principle: the
                 row keeps its place so drilling doesn't jump the layout, and
                 "where am I" reads the same way on every level). At root the
                 catalogue name is the current node; drilled it links back and
                 the ancestor chain + current node follow. --%>
            <div class="min-w-0">
              <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content flex flex-wrap items-center gap-x-2 gap-y-1">
                <%= if @current_category != nil do %>
                  <.link
                    patch={Paths.catalogue_detail(@catalogue.uuid)}
                    class="font-normal text-base-content/50 hover:text-primary"
                  >
                    {@catalogue.name}
                  </.link>
                  <%= for cat <- @breadcrumb do %>
                    <.icon name="hero-chevron-right" class="w-5 h-5 text-base-content/30 shrink-0" />
                    <.link
                      patch={Paths.category_browse(@catalogue.uuid, cat.uuid)}
                      class="font-normal text-base-content/50 hover:text-primary"
                    >
                      {cat.name}
                    </.link>
                  <% end %>
                  <.icon name="hero-chevron-right" class="w-5 h-5 text-base-content/30 shrink-0" />
                  <span class="truncate">{current_node_label(@current_category)}</span>
                <% else %>
                  <span class="truncate">{@catalogue.name}</span>
                <% end %>
              </h1>
            </div>
            <div :if={@view_mode == "active"} class="flex flex-wrap items-center gap-2 sm:flex-shrink-0">
              <.link navigate={new_category_path(assigns)} class="btn btn-outline btn-sm">
                <.icon name="hero-folder-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add Category")}
              </.link>
              <.link navigate={new_item_path(assigns)} class="btn btn-primary btn-sm">
                <.icon name="hero-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add Item")}
              </.link>
              <.link navigate={Paths.catalogue_edit(@catalogue.uuid)} class="btn btn-ghost btn-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
              </.link>
            </div>
          </div>

          <div :if={@catalogue.description} class="-mt-4">
          <p class="text-base-content/60">
            {@catalogue.description}
          </p>
        </div>

        <%!-- Toolbar: scoped search (Active mode only — context search
             excludes deleted rows) + per-level Active/Deleted toggle.
             The input also stays up whenever a search is on screen: `?q=` now
             survives the level load, so a deep link into a node whose Active
             tab is empty lands in the Deleted view with results rendered —
             hiding the input there would leave them with no way to clear. --%>
        <% show_search_input = @view_mode == "active" or @search_results != nil or @search_loading %>
        <div class="flex items-end justify-between gap-4 flex-wrap border-b border-base-200 pb-2">
          <.search_input
            :if={show_search_input}
            class="grow"
            query={@search_query}
            placeholder={search_placeholder(@current_category)}
          />
          <div :if={not show_search_input}></div>

          <%!-- One tab per populated item status; each shows only that status's
               items so e.g. discontinued isn't mixed in with active. The strip
               renders only alongside an actual item list (`show_items_section`)
               AND only when there's more than one status to choose between — the
               root category step is pure navigation, and a node with a single
               populated status just shows those items with no redundant tab. --%>
          <div
            :if={@show_items_section and length(@status_tabs) > 1 and is_nil(@search_results) and not @search_loading}
            class="flex items-center gap-0.5 pb-1 flex-wrap"
          >
            <button
              :for={{status, label, count} <- @status_tabs}
              type="button"
              phx-click="switch_view"
              phx-value-mode={status}
              class={[
                "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer whitespace-nowrap",
                if(@view_mode == status,
                  do: status_tab_active_class(status),
                  else: "border-transparent text-base-content/50 hover:text-base-content"
                )
              ]}
            >
              {label} ({count})
            </button>
          </div>
        </div>

        <%!-- Search results (Active mode; unchanged machinery) --%>
        <div :if={@search_results != nil or @search_loading} class="flex flex-col gap-4">
          <div class="flex items-center gap-2">
            <%= if @search_loading and is_nil(@search_results) do %>
              <span class="text-sm text-base-content/60">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Searching for \"%{query}\"...", query: @search_query)}
              </span>
            <% else %>
              <.search_results_summary :if={@search_results != nil} count={@search_total} query={@search_query} loaded={length(@search_results)} />
            <% end %>
            <span :if={@search_loading} class="loading loading-spinner loading-xs text-base-content/40"></span>
          </div>

          <.empty_state :if={@search_results == [] and not @search_loading} variant="card" title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items match your search.")} />

          <div :if={@search_results not in [nil, []]} class="flex justify-end">
            <.view_mode_toggle storage_key="catalogue-detail-items" />
          </div>

          <div :if={@search_results not in [nil, []]} class={["transition-opacity", @search_loading && "opacity-50"]}>
            <.item_table
              photo_click="show_product_card"
              file_counts={@file_counts}
              attribute_map={@attribute_map}
              items={@search_results}
              columns={[:name, :sku, :price, :unit, :status]}
              markup_percentage={@catalogue.markup_percentage}
              edit_path={@edit_path_fn}
              pdf_search_event="show_pdf_search"
              cards={true}
              show_toggle={false}
              storage_key="catalogue-detail-items"
              id="catalogue-search-items"
            />
          </div>

          <.load_more
            :if={@search_results not in [nil, []]}
            id="search-load-more"
            loaded={length(@search_results)}
            total={@search_total}
            noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
            infinite={not @search_loading}
            cursor={"search-#{@search_offset}"}
          />
        </div>

        <%!-- ── Browse view (no active search) ──────────────────────── --%>
        <div :if={is_nil(@search_results) and not @search_loading} class="flex flex-col gap-6">
          <%!-- One control row: category Reorder-all (manual/drag order is
               the only category order, so the shortcut is always offered
               with >1 sibling) next to the view toggle — not two stacked
               right-aligned rows. --%>
          <div
            :if={
              @child_categories != [] or
                (@show_items_section and (@items != [] or @search_results not in [nil, []]))
            }
            class="flex flex-wrap items-center justify-end gap-2"
          >
            <.sort_selector
              :if={@child_categories != []}
              sort_by={@categories_sort_by}
              sort_dir={@categories_sort_dir}
              options={category_sort_options()}
              manual_field={:position}
              event="sort_categories"
              id="categories-sort-selector"
            />
            <%!-- Item-only levels put the items sort here too — same row,
                 same order as the catalogues index. Mixed levels keep the
                 items controls in their own section to avoid two identical
                 unlabeled sort dropdowns side by side. --%>
            <.sort_selector
              :if={
                @child_categories == [] and @show_items_section and @items != [] and
                  @view_mode == "active"
              }
              sort_by={@items_sort_by}
              sort_dir={@items_sort_dir}
              options={item_sort_options()}
              manual_field={:position}
              event="sort_items"
              id="items-header-sort-selector"
            />
            <button
              :if={
                @child_categories == [] and @show_items_section and @items_total > 1 and
                  @items_sort_by == :position and @view_mode == "active"
              }
              type="button"
              phx-click="open_items_reorder_modal"
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-arrows-up-down" class="w-4 h-4" />
              <span class="hidden sm:inline">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Reorder all")}
              </span>
            </button>
            <button
              :if={
                @view_mode == "active" and length(@child_categories) > 1 and
                  @categories_sort_by == :position
              }
              type="button"
              phx-click="open_categories_reorder_modal"
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-arrows-up-down" class="w-4 h-4" />
              <span class="hidden sm:inline">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Reorder all")}
              </span>
            </button>
            <button
              :if={@child_categories != [] and @view_mode == "active"}
              type="button"
              phx-click="show_column_modal"
              phx-value-scope="detail_categories"
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
              <span class="hidden sm:inline">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Columns")}
              </span>
            </button>
            <button
              :if={@show_items_section and @view_mode == "active"}
              type="button"
              phx-click="show_column_modal"
              phx-value-scope="detail_items"
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
              <span class="hidden sm:inline">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Columns")}
              </span>
            </button>
            <.view_mode_toggle storage_key="catalogue-detail-items" />
          </div>
          <%!-- The Uncategorized drill card only appears when there are
               categories to drill past. With no categories, the items
               render inline (see `show_items_section`), so the card would
               be a redundant extra click. --%>
          <% show_uncat_card =
            is_nil(@current_category) and @view_mode == "active" and
              @uncategorized_active_count > 0 and @child_categories != [] %>

          <%!-- Category bulk-action bar (when subcategories selected) --%>
          <.bulk_actions_bar
            :if={MapSet.size(@selected_categories) > 0}
            count={MapSet.size(@selected_categories)}
            clear_event="clear_selection"
            wrapper_class="sticky top-[72px] z-40 -mx-1 px-3 py-2 rounded-lg bg-base-100/95 border border-primary/40 shadow-md backdrop-blur"
          >
            <button
              :if={@view_mode == "active"}
              phx-click="request_bulk_delete_categories"
              class="btn btn-sm btn-outline btn-error"
            >
              <.icon name="hero-trash" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
            </button>
            <button
              :if={@view_mode != "active"}
              phx-click="request_bulk_restore_categories"
              class="btn btn-sm btn-outline btn-success"
            >
              <.icon name="hero-arrow-path" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
            </button>
          </.bulk_actions_bar>

          <.reorder_modal
            id="categories-reorder-modal"
            show={@show_categories_reorder}
            on_close="close_categories_reorder_modal"
            on_apply="apply_categories_reorder"
            selected_count={0}
            total_count={length(@child_categories)}
            strategies={item_reorder_strategies()}
            noun_singular={Gettext.gettext(PhoenixKitCatalogue.Gettext, "category")}
            noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "categories")}
          />

          <%!-- Categories in the level's chosen view. The page-level
               card/table toggle drives this via the shared TableCardView
               storage key: "table" = the one-per-line rows, "card" = the
               tile grid. Deleted mode renders rows only (no card branch),
               and the hook no-ops when a branch is missing, so nothing can
               toggle itself invisible. Both branches carry their own
               SortableGrid on the same reorder event. --%>
          <div
            :if={@child_categories != [] or show_uncat_card}
            id="catalogue-categories-views"
            phx-hook="TableCardView"
            data-storage-key="catalogue-detail-items"
          >
            <div data-table-view class={@view_mode == "active" && "hidden md:block"}>
              <.categories_table
                categories_sort_by={@categories_sort_by}
                categories_columns={@categories_columns}
                child_subcat_counts={@child_subcat_counts}
                catalogue={@catalogue}
                child_categories={@child_categories}
                child_counts={@child_counts}
                children_with_subs={@children_with_subs}
                selected_categories={@selected_categories}
                view_mode={@view_mode}
                file_counts={@file_counts}
                show_uncat={show_uncat_card}
                uncategorized_active_count={@uncategorized_active_count}
              />
            </div>

            <div :if={@view_mode == "active"} data-card-view class="md:hidden">
              <div
                id="catalogue-child-categories-tiles"
                class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3"
                data-sortable="true"
                data-sortable-event="reorder_categories"
                data-sortable-items=".sortable-item"
                data-sortable-hide-source="false"
                data-sortable-group="catalogue-child-categories-tiles"
                data-sortable-handle=".pk-drag-handle"
                phx-hook="SortableGrid"
              >
                <%= for cat <- @child_categories do %>
                  <.category_tile
                    catalogue_uuid={@catalogue.uuid}
                    category={cat}
                    count={Map.get(@child_counts, cat.uuid, 0)}
                    has_subs={MapSet.member?(@children_with_subs, cat.uuid)}
                    view_mode={@view_mode}
                    sibling_count={length(@child_categories)}
                    selected={MapSet.member?(@selected_categories, cat.uuid)}
                    has_files={Map.get(@file_counts, cat.uuid, 0) > 0}
                  />
                <% end %>
                <.uncategorized_tile
                  :if={show_uncat_card}
                  catalogue_uuid={@catalogue.uuid}
                  count={@uncategorized_active_count}
                />
              </div>
            </div>
          </div>

          <%!-- Deleted-list bulk-action bar (server-side select). The
               active list owns its selection client-side via the core
               BulkSelectScope toolkit inside `level_items`. --%>
          <.bulk_actions_bar
            :if={@view_mode == "deleted" and MapSet.size(@selected_items) > 0}
            count={MapSet.size(@selected_items)}
            clear_event="clear_selection"
            wrapper_class="sticky top-[72px] z-40 -mx-1 px-3 py-2 rounded-lg bg-base-100/95 border border-primary/40 shadow-md backdrop-blur"
          >
            <button phx-click="request_bulk_restore_items" class="btn btn-sm btn-outline btn-success">
              <.icon name="hero-arrow-path" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
            </button>
            <button phx-click="request_bulk_delete_items" class="btn btn-sm btn-outline btn-error">
              <.icon name="hero-trash" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")}
            </button>
          </.bulk_actions_bar>

          <%!-- Card/table view toggle. One toggle, one storage key
               ("catalogue-detail-items") — it drives every item table on
               this page live (search results, active level items, deleted
               list) via the TableCardView sync event. It used to render
               for the deleted list only, on the grounds that the active
               list's cards lack select-all / drag-reorder; that caution
               was overridden by a deliberate product call (2026-08-14):
               card view is wanted everywhere, and card-side reorder is
               tracked as its own follow-up. --%>

          <%!-- The current node's own direct items --%>
          <.level_items
            attribute_map={@attribute_map}
            items_columns={@items_columns}
            controls_in_page_header={@child_categories == []}
            :if={@show_items_section}
            items={@items}
            file_counts={@file_counts}
            edit_path_fn={@edit_path_fn}
            view_mode={@view_mode}
            catalogue={@catalogue}
            current_category={@current_category}
            current_category_uuid={@current_category_uuid}
            selected_items={@selected_items}
            items_total={@items_total}
            items_offset={@items_offset}
            items_sort_by={@items_sort_by}
            items_sort_dir={@items_sort_dir}
            show_items_reorder={@show_items_reorder}
            reorder_captured_uuids={@reorder_captured_uuids}
          />

          <%!-- Level is completely empty (root/active with no categories
               and no uncategorized items). The items section renders its
               own empty message for drilled-in nodes. --%>
          <.empty_state
            :if={@child_categories == [] and not show_uncat_card and not @show_items_section}
            variant="card"
            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No categories or items yet. Add a category or item to get started.")}
          />
        </div>
      </div>

      <.column_settings_modal
        :if={@column_modal_scope}
        show={@column_modal_scope != nil}
        scope={@column_modal_scope}
        selected={current_scope_columns(assigns, @column_modal_scope)}
        temp_selected={@temp_columns}
      />

      <.confirm_modal
        show={match?({"item", _}, @confirm_delete)}
        on_confirm="permanently_delete_item"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Item")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This item will be permanently deleted. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"category", _}, @confirm_delete)}
        on_confirm="permanently_delete_category"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Category")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This category and all its items will be permanently deleted. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        danger={true}
      />

      <%!-- "What about the items?" modal — opens when the operator
           clicks Delete on a category that still has active items in
           its V103 subtree. The boss's rule: deleting the category
           shouldn't drag the items down with it; the operator picks
           a destination first. --%>
      <.confirm_modal
        :if={@trash_modal}
        show={true}
        on_confirm="confirm_trash_category"
        on_cancel="cancel_trash_category"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete category — what about the items?")}
        title_icon="hero-folder-minus"
        confirm_text={
          if @trash_modal[:disposition] == :cascade,
            do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete category and items"),
            else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move items and delete category")
        }
        confirm_disabled={
          @trash_modal[:disposition] == :move_to and is_nil(@trash_modal[:target_uuid])
        }
        danger={true}
      >
        <p class="text-sm text-base-content/70">
          <strong>{@trash_modal[:category].name}</strong>
          {Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
            "and its subtree contain %{count} active items. Choose where they should go before the category is deleted.",
            count: @trash_modal[:item_count]
          )}
        </p>

        <div class="space-y-3 mt-4">
          <%!-- Option 1: uncategorize (no further input needed) --%>
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="trash_disposition"
              value="uncategorize"
              checked={@trash_modal[:disposition] == :uncategorize}
              phx-click="set_trash_disposition"
              phx-value-disposition="uncategorize"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Make items uncategorized")}
              </p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Items stay in this catalogue but are no longer attached to any category."
                )}
              </p>
            </div>
          </label>

          <%!-- Option 2: move to another category in the same catalogue.
               Only meaningful when there's a sibling/elsewhere to move to;
               we still render the radio when the list is empty so the UI
               is symmetric, but the dropdown shows an empty-state hint. --%>
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="trash_disposition"
              value="move_to"
              checked={@trash_modal[:disposition] == :move_to}
              phx-click="set_trash_disposition"
              phx-value-disposition="move_to"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move items to another category")}
              </p>
              <p class="text-xs text-base-content/60 mb-2">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Pick a target category in this catalogue. The category being deleted and its subtree are excluded."
                )}
              </p>
              <%= if @trash_modal[:targets] == [] do %>
                <p class="text-xs text-warning">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No other categories available — use Uncategorized instead.")}
                </p>
              <% else %>
                <select
                  name="category_uuid"
                  phx-change="select_trash_target"
                  disabled={@trash_modal[:disposition] != :move_to}
                  class="select select-sm w-full"
                >
                  <option value="">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select category --")}</option>
                  <%= for {cat, depth} <- @trash_modal[:targets] do %>
                    <option value={cat.uuid} selected={@trash_modal[:target_uuid] == cat.uuid}>
                      {String.duplicate("— ", depth)}{cat.name}
                    </option>
                  <% end %>
                </select>
              <% end %>
            </div>
          </label>

          <%!-- Option 3: cascade — items follow the category to the
               Deleted view. Soft-delete, restorable. The "I want everything
               gone" path; not the default since the boss specifically
               disliked this being implicit. --%>
          <label class="flex items-start gap-3 p-3 rounded-lg border border-error/30 cursor-pointer hover:bg-error/5">
            <input
              type="radio"
              name="trash_disposition"
              value="cascade"
              checked={@trash_modal[:disposition] == :cascade}
              phx-click="set_trash_disposition"
              phx-value-disposition="cascade"
              class="radio radio-sm radio-error mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm text-error">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete items along with the category")}
              </p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Items move to the Deleted view alongside the category. Both can be restored later."
                )}
              </p>
            </div>
          </label>
        </div>
      </.confirm_modal>

      <%!-- Bulk-action confirm modal (for items: trash or permanent
           delete; categories use the trash_modal in bulk mode for the
           item-disposition picker). --%>
      <.confirm_modal
        :if={@bulk_confirm}
        show={true}
        on_confirm="confirm_bulk_action"
        on_cancel="cancel_bulk_action"
        title={
          case @bulk_confirm[:mode] do
            :permanent -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently delete selected items?")
            _ -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete selected items?")
          end
        }
        title_icon="hero-trash"
        confirm_text={
          case @bulk_confirm[:mode] do
            :permanent -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")
            _ -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")
          end
        }
        danger={true}
        messages={
          case @bulk_confirm[:mode] do
            :permanent ->
              [
                {:warning,
                 Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} items will be permanently deleted. This cannot be undone.", count: @bulk_confirm[:count])}
              ]

            _ ->
              [
                {:warning,
                 Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} items will be moved to the Deleted view. They can be restored later.", count: @bulk_confirm[:count])}
              ]
          end
        }
      />

      <%!-- Bulk-move modal for items — same shape as the trash modal's
           Move-to-another-category branch but applied to all selected
           items. --%>
      <.confirm_modal
        :if={@bulk_move_modal}
        show={true}
        on_confirm="confirm_bulk_move_items"
        on_cancel="cancel_bulk_move"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move selected items")}
        title_icon="hero-arrows-right-left"
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move items")}
        confirm_disabled={
          @bulk_move_modal[:disposition] == :move_to and is_nil(@bulk_move_modal[:target_uuid])
        }
      >
        <p class="text-sm text-base-content/70">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pick where %{count} items should go.", count: @bulk_move_modal[:count])}
        </p>

        <div class="space-y-3 mt-4">
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="bulk_move_disposition"
              value="uncategorize"
              checked={@bulk_move_modal[:disposition] == :uncategorize}
              phx-click="set_bulk_move_disposition"
              phx-value-disposition="uncategorize"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Make items uncategorized")}
              </p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items keep their catalogue but lose their category.")}
              </p>
            </div>
          </label>

          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="bulk_move_disposition"
              value="move_to"
              checked={@bulk_move_modal[:disposition] == :move_to}
              phx-click="set_bulk_move_disposition"
              phx-value-disposition="move_to"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move items to another category")}
              </p>
              <%= if @bulk_move_modal[:targets] == [] do %>
                <p class="text-xs text-warning">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No categories available — use Uncategorized instead.")}
                </p>
              <% else %>
                <select
                  name="category_uuid"
                  phx-change="select_bulk_move_target"
                  disabled={@bulk_move_modal[:disposition] != :move_to}
                  class="select select-sm w-full mt-2"
                >
                  <option value="">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select category --")}</option>
                  <%= for {cat, depth} <- @bulk_move_modal[:targets] do %>
                    <option value={cat.uuid} selected={@bulk_move_modal[:target_uuid] == cat.uuid}>
                      {String.duplicate("— ", depth)}{cat.name}
                    </option>
                  <% end %>
                </select>
              <% end %>
            </div>
          </label>
        </div>
      </.confirm_modal>

      <.live_component
        :if={@pdf_search_item}
        module={PdfSearchModal}
        id="catalogue-detail-pdf-search"
        item={@pdf_search_item}
        show={@show_pdf_search}
      />

      <ProductCard.product_card
        id="catalogue-detail-product"
        show={@card_open}
        item_name={@card_name}
        images={@card_images}
        fields={@card_fields}
        files={@card_files}
        target={nil}
        on_close="card_close"
      />
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # ── Drill-down level components ──────────────────────────────────

  # The level's categories as a REAL table — same anatomy as the item and
  # catalogue tables (drag column, checkbox, photo column, Name, count,
  # Actions) so the three levels read as one product ("uniform experience",
  # boss call 2026-08-15). This is the table branch of the level's
  # card/table toggle; the tile grid below is the card branch.
  attr(:catalogue, :map, required: true)
  attr(:child_categories, :list, required: true)
  attr(:child_counts, :map, required: true)
  attr(:children_with_subs, :any, required: true)
  attr(:selected_categories, :any, required: true)
  attr(:view_mode, :string, required: true)
  attr(:categories_sort_by, :atom, default: :position)
  attr(:file_counts, :map, required: true)
  attr(:show_uncat, :boolean, default: false)
  attr(:uncategorized_active_count, :integer, default: 0)
  attr(:categories_columns, :list, default: ["items"])
  attr(:child_subcat_counts, :map, default: %{})

  defp categories_table(assigns) do
    assigns =
      assigns
      |> assign(
        :draggable?,
        assigns.view_mode == "active" and length(assigns.child_categories) > 1 and
          assigns.categories_sort_by == :position
      )
      |> assign(
        :photo_col?,
        any_media_thumb?(assigns.child_categories, assigns.file_counts)
      )

    ~H"""
    <%!-- Plain table (no `items`): the level's OWN card/table wrapper
         drives visibility and the pk-comfy marker; passing items here
         would spawn table_default's nested view machinery with its own
         storage key, drifting out of sync with the page toggle. --%>
    <.table_default
      id="catalogue-categories-table"
      size="sm"
      wrapper_class="overflow-x-auto shadow-none rounded-none"
    >
      <.table_default_header>
        <.table_default_row>
          <.drag_handle_header_cell :if={@draggable?} />
          <.table_default_header_cell class="w-8"></.table_default_header_cell>
          <.table_default_header_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5"></.table_default_header_cell>
          <.table_default_header_cell>
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
          </.table_default_header_cell>
          <%= for col <- @categories_columns do %>
            <%= case col do %>
              <% "items" -> %>
                <.table_default_header_cell class="text-right">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")}
                </.table_default_header_cell>
              <% "updated" -> %>
                <.table_default_header_cell>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated")}
                </.table_default_header_cell>
              <% "subcategories" -> %>
                <.table_default_header_cell class="text-right">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Subcategories")}
                </.table_default_header_cell>
              <% "description" -> %>
                <.table_default_header_cell>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
                </.table_default_header_cell>
              <% "files" -> %>
                <.table_default_header_cell>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}
                </.table_default_header_cell>
              <% "status" -> %>
                <.table_default_header_cell>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                </.table_default_header_cell>
              <% "created" -> %>
                <.table_default_header_cell>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Created")}
                </.table_default_header_cell>
              <% _ -> %>
            <% end %>
          <% end %>
          <.table_default_header_cell class="text-right">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}
          </.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.sortable_tbody
        id="catalogue-child-categories"
        enabled={@draggable?}
        event="reorder_categories"
      >
        <.sortable_row :for={cat <- @child_categories} item_id={cat.uuid}>
          <.drag_handle_cell :if={@draggable? and cat.status == "active"} />
          <td :if={@draggable? and cat.status != "active"} class="w-8"></td>
          <.table_default_cell class="w-8">
            <input
              :if={@view_mode == "active" and cat.status == "active"}
              type="checkbox"
              class="checkbox checkbox-xs"
              checked={MapSet.member?(@selected_categories, cat.uuid)}
              phx-click="toggle_select_category"
              phx-value-uuid={cat.uuid}
            />
          </.table_default_cell>
          <.table_default_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
            <.featured_thumb resource={cat} has_files={Map.get(@file_counts, cat.uuid, 0) > 0} />
          </.table_default_cell>
          <.table_default_cell class="font-medium">
            <div class="flex items-center gap-2 min-w-0">
              <.link
                patch={Paths.category_browse(@catalogue.uuid, cat.uuid)}
                class={["link link-hover font-medium", cat.status == "deleted" && "text-error/70"]}
              >
                {cat.name}
              </.link>
              <span
                :if={MapSet.member?(@children_with_subs, cat.uuid)}
                class="badge badge-ghost badge-xs"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Has subcategories")}
              >
                <.icon name="hero-rectangle-stack" class="w-3 h-3" />
              </span>
              <span :if={cat.status == "deleted"} class="badge badge-error badge-xs">deleted</span>
            </div>
          </.table_default_cell>
          <%= for col <- @categories_columns do %>
            <%= case col do %>
              <% "items" -> %>
                <.table_default_cell class="text-right tabular-nums">
                  {Map.get(@child_counts, cat.uuid, 0)}
                </.table_default_cell>
              <% "updated" -> %>
                <.table_default_cell class="text-sm text-base-content/60">
                  {Calendar.strftime(cat.updated_at, "%Y-%m-%d %H:%M")}
                </.table_default_cell>
              <% "subcategories" -> %>
                <.table_default_cell class="text-right tabular-nums text-base-content/60">
                  {Map.get(@child_subcat_counts, cat.uuid, 0)}
                </.table_default_cell>
              <% "description" -> %>
                <.table_default_cell class="text-sm text-base-content/60 max-w-64">
                  <span class="line-clamp-2">{cat.description || "—"}</span>
                </.table_default_cell>
              <% "files" -> %>
                <.table_default_cell class="text-sm tabular-nums text-base-content/60">
                  {Map.get(@file_counts, cat.uuid, 0)}
                </.table_default_cell>
              <% "status" -> %>
                <.table_default_cell>
                  <.status_badge status={cat.status} size={:xs} />
                </.table_default_cell>
              <% "created" -> %>
                <.table_default_cell class="text-sm text-base-content/60">
                  {Calendar.strftime(cat.inserted_at, "%Y-%m-%d %H:%M")}
                </.table_default_cell>
              <% _ -> %>
            <% end %>
          <% end %>
          <.table_default_cell class="text-right whitespace-nowrap">
            <.table_row_menu
              :if={@view_mode == "active" and cat.status == "active"}
              mode="auto"
              id={"category-menu-#{cat.uuid}"}
            >
              <.table_row_menu_link
                navigate={Paths.category_edit(cat.uuid)}
                icon="hero-pencil"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
              />
              <.table_row_menu_link
                patch={Paths.category_browse(@catalogue.uuid, cat.uuid)}
                icon="hero-folder-open"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open")}
              />
              <.table_row_menu_divider />
              <.table_row_menu_button
                phx-click="request_trash_category"
                phx-value-uuid={cat.uuid}
                icon="hero-trash"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                variant="error"
              />
            </.table_row_menu>
            <.table_row_menu
              :if={@view_mode == "deleted" and cat.status == "deleted"}
              mode="auto"
              id={"category-del-menu-#{cat.uuid}"}
            >
              <.table_row_menu_button
                phx-click="restore_category"
                phx-value-uuid={cat.uuid}
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")}
                icon="hero-arrow-path"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
                variant="success"
              />
              <.table_row_menu_divider />
              <.table_row_menu_button
                phx-click="show_delete_confirm"
                phx-value-uuid={cat.uuid}
                phx-value-type="category"
                icon="hero-trash"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
                variant="error"
              />
            </.table_row_menu>
          </.table_default_cell>
        </.sortable_row>
        <tr :if={@show_uncat}>
          <td :if={@draggable?} class="w-8"></td>
          <td class="w-8"></td>
          <td :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
            <span class="w-8 h-8 rounded bg-base-200 flex items-center justify-center">
              <.icon name="hero-folder-open" class="w-4 h-4 text-base-content/40" />
            </span>
          </td>
          <td class="font-medium">
            <.link patch={Paths.uncategorized_browse(@catalogue.uuid)} class="link link-hover">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uncategorized")}
            </.link>
          </td>
          <%= for col <- @categories_columns do %>
            <%= case col do %>
              <% "items" -> %>
                <td class="text-right tabular-nums">{@uncategorized_active_count}</td>
              <% "updated" -> %>
                <td></td>
              <% "subcategories" -> %>
                <td></td>
              <% "description" -> %>
                <td></td>
              <% "files" -> %>
                <td></td>
              <% "status" -> %>
                <td></td>
              <% "created" -> %>
                <td></td>
              <% _ -> %>
            <% end %>
          <% end %>
          <td class="text-right">
            <.table_row_menu mode="auto" id="category-menu-uncategorized">
              <.table_row_menu_link
                patch={Paths.uncategorized_browse(@catalogue.uuid)}
                icon="hero-folder-open"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open")}
              />
            </.table_row_menu>
          </td>
        </tr>
      </.sortable_tbody>
    </.table_default>
    """
  end

  # Tile form of the category card — the "card view" branch of the level's
  # categories. Same affordances as the row (drill, select, drag among
  # siblings, edit); the file indicator moves into the badge row because a
  # corner emblem would clip against the tile's figure.
  attr(:catalogue_uuid, :string, required: true)
  attr(:category, :map, required: true)
  attr(:count, :integer, required: true)
  attr(:has_subs, :boolean, default: false)
  attr(:view_mode, :string, required: true)
  attr(:sibling_count, :integer, required: true)
  attr(:selected, :boolean, default: false)
  attr(:has_files, :boolean, default: false)

  defp category_tile(assigns) do
    ~H"""
    <div
      class={[
        "group card card-sm bg-base-100 shadow hover:shadow-md transition-shadow overflow-hidden",
        @view_mode == "active" and @category.status == "active" && "sortable-item"
      ]}
      data-id={@view_mode == "active" and @category.status == "active" && @category.uuid}
    >
      <figure class="relative h-24 bg-base-200">
        <.featured_thumb resource={@category} class="w-full h-full" />
        <.icon
          :if={!featured_image_uuid(@category)}
          name="hero-folder"
          class="w-10 h-10 text-base-content/20 absolute inset-0 m-auto"
        />
        <input
          :if={@view_mode == "active" and @category.status == "active"}
          type="checkbox"
          class="checkbox checkbox-xs absolute top-1.5 left-1.5 bg-base-100/80"
          checked={@selected}
          phx-click="toggle_select_category"
          phx-value-uuid={@category.uuid}
        />
        <span
          :if={@view_mode == "active" and @category.status == "active" and @sibling_count > 1}
          class="pk-drag-handle cursor-grab active:cursor-grabbing absolute top-1.5 right-1.5 rounded bg-base-100/80 p-0.5 text-base-content/50 hover:text-base-content/80"
          title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to reorder (among siblings)")}
        >
          <.icon name="hero-bars-3" class="w-4 h-4" />
        </span>
      </figure>
      <div class="card-body p-3 gap-1.5">
        <.link
          patch={Paths.category_browse(@catalogue_uuid, @category.uuid)}
          class="font-medium truncate hover:text-primary"
        >
          {@category.name}
        </.link>
        <div class="flex items-center gap-1.5">
          <span class="badge badge-ghost badge-sm">
            {@count} {Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
          </span>
          <span
            :if={@has_subs}
            class="badge badge-ghost badge-xs"
            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Has subcategories")}
          >
            <.icon name="hero-rectangle-stack" class="w-3 h-3" />
          </span>
          <span
            :if={@has_files}
            class="badge badge-ghost badge-xs"
            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}
          >
            <.icon name="hero-paper-clip" class="w-3 h-3 rotate-45" />
          </span>
          <div class="flex-1"></div>
          <.table_row_menu mode="auto" id={"category-tile-menu-#{@category.uuid}"}>
            <.table_row_menu_link
              navigate={Paths.category_edit(@category.uuid)}
              icon="hero-pencil"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
            />
            <.table_row_menu_link
              patch={Paths.category_browse(@catalogue_uuid, @category.uuid)}
              icon="hero-folder-open"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open")}
            />
            <.table_row_menu_divider />
            <.table_row_menu_button
              phx-click="request_trash_category"
              phx-value-uuid={@category.uuid}
              icon="hero-trash"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
              variant="error"
            />
          </.table_row_menu>
        </div>
      </div>
    </div>
    """
  end

  # Tile form of the Uncategorized drill (root, active mode).
  attr(:catalogue_uuid, :string, required: true)
  attr(:count, :integer, required: true)

  defp uncategorized_tile(assigns) do
    ~H"""
    <.link
      patch={Paths.uncategorized_browse(@catalogue_uuid)}
      class="card card-sm bg-base-100 shadow hover:shadow-md transition-shadow overflow-hidden"
    >
      <figure class="relative h-24 bg-base-200">
        <.icon
          name="hero-folder-open"
          class="w-10 h-10 text-base-content/20 absolute inset-0 m-auto"
        />
      </figure>
      <div class="card-body p-3 gap-1.5">
        <span class="font-medium truncate">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uncategorized")}
        </span>
        <span class="badge badge-ghost badge-sm w-fit">
          {@count} {Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
        </span>
      </div>
    </.link>
    """
  end

  # The current node's own direct items.
  #
  # Active mode: the core List-UI toolkit — a sort dropdown, client-side
  # bulk-select with a floating actions toolbar, node-scoped DnD reorder
  # (manual mode only), and a strategy "Reorder" modal. Deleted mode:
  # the existing `<.item_table>` (Restore / Delete-forever per row +
  # server-side selection). One InfiniteScroll sentinel pages the list.
  attr(:items, :list, required: true)
  attr(:view_mode, :string, required: true)
  attr(:catalogue, :any, required: true)
  attr(:current_category, :any, required: true)
  attr(:current_category_uuid, :any, required: true)
  attr(:selected_items, :any, required: true)
  attr(:items_total, :integer, required: true)
  attr(:items_offset, :integer, required: true)
  attr(:items_sort_by, :atom, required: true)
  attr(:items_sort_dir, :atom, required: true)
  attr(:show_items_reorder, :boolean, required: true)
  attr(:reorder_captured_uuids, :list, required: true)
  attr(:file_counts, :map, default: %{})
  attr(:attribute_map, :map, default: %{})
  attr(:edit_path_fn, :any, required: true)
  attr(:items_columns, :list, default: ["sku", "price", "unit", "status"])

  attr(:controls_in_page_header, :boolean,
    default: false,
    doc:
      "Item-only levels render the sort selector + Reorder-all in the page " <>
        "control row; the in-section toolbar then only offers selection-scoped " <>
        "reorder and bulk actions."
  )

  defp level_items(assigns) do
    # `draggable?` controls the handle *column* (manual sort, not the deleted
    # list); `reorderable?` controls the actual grip + DnD, which needs ≥2
    # items. The column is kept even at a single item — rendered as an empty
    # spacer cell — so deleting down to one row doesn't shift the layout.
    draggable? = assigns.items_sort_by == :position and assigns.view_mode != "deleted"

    assigns =
      assigns
      |> assign(:draggable?, draggable?)
      |> assign(:reorderable?, draggable? and assigns.items_total > 1)

    ~H"""
    <div class="flex flex-col gap-2">
      <%!-- ── Active list: core List-UI toolkit ── --%>
      <.bulk_select_scope
        :if={@items != [] and @view_mode != "deleted"}
        id={"items-bulk-" <> (@current_category_uuid || "root")}
        total_count={@items_total}
        class="flex flex-col gap-2"
      >
        <%!-- With the sort selector + Reorder-all promoted to the page
             control row, the toolbar has nothing to show until rows are
             selected — hide the empty bar (hook re-shows it on selection). --%>
        <div
          data-bulk-show={if @controls_in_page_header, do: "has-selection"}
          style={if @controls_in_page_header, do: "display: none;"}
        >
          <.bulk_actions_toolbar
            on_open_reorder="open_items_reorder_modal"
          reorder_dialog_id="items-reorder-modal"
          reorder_gate={
            if not @controls_in_page_header and @items_total > 1 and
                 @items_sort_by == :position,
               do: :always,
               else: :multi
          }
          on_bulk_delete="request_bulk_delete_items"
          noun_singular={Gettext.gettext(PhoenixKitCatalogue.Gettext, "item")}
          noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
        >
          <:leading>
            <.sort_selector
              :if={!@controls_in_page_header}
              sort_by={@items_sort_by}
              sort_dir={@items_sort_dir}
              options={item_sort_options()}
              manual_field={:position}
              event="sort_items"
            />
            <%!-- Move isn't a built-in toolbar action (core ships
                 Reorder/Delete/Clear), so it's a custom client-side
                 button: `data-bulk-action` makes the BulkSelectScope
                 hook push the captured uuids as `%{"uuids" => [...]}`.
                 Shown only when ≥1 row is selected. --%>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              data-bulk-action="request_bulk_move_items"
              data-bulk-show="has-selection"
              style="display: none;"
            >
              <.icon name="hero-arrows-right-left" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
            </button>
          </:leading>
          </.bulk_actions_toolbar>
        </div>

        <.table_default
          id="level-items-active"
          size="sm"
          wrapper_class="overflow-x-auto shadow-none rounded-none"
          toggleable={true}
          show_toggle={false}
          items={@items}
          storage_key="catalogue-detail-items"
        >
          <%!-- Mobile card view: name + checkbox header, key-value body,
               icon-only action footer. Checkbox uses data-bulk-role so
               the BulkSelectScope hook picks it up without a phx-click. --%>
          <:card_body :let={item}>
            <div class="flex items-center gap-2 font-medium text-sm">
              <input
                type="checkbox"
                class="checkbox checkbox-xs shrink-0"
                data-bulk-role="row"
                data-uuid={item.uuid}
              />
              <.featured_thumb
                resource={item}
                class="w-12 h-12"
                on_click="show_product_card"
                has_files={Map.get(@file_counts, item.uuid, 0) > 0}
              />
              <.link
                :if={item.uuid}
                navigate={@edit_path_fn.(item.uuid)}
                class="link link-hover min-w-0 truncate"
              >
                {item.name || "—"}
              </.link>
              <span
                :if={Map.has_key?(@attribute_map, item.uuid)}
                class="shrink-0"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Has attribute group")}
              >
                <.icon name="hero-swatch" class="w-3.5 h-3.5 text-primary/60" />
              </span>
            </div>
            <div class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm flex-1">
              <%= for col <- @items_columns do %>
                <%= case col do %>
                  <% "sku" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")}</div>
                    <div class="font-mono text-base-content/60">{item.sku || "—"}</div>
                  <% "price" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price")}</div>
                    <div class="font-semibold">
                      {if sale_price = Catalogue.item_pricing(item).sale_price,
                        do: Decimal.to_string(sale_price, :normal),
                        else: "—"}
                    </div>
                  <% "unit" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit")}</div>
                    <div>{Item.unit_label(item.unit)}</div>
                  <% "status" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}</div>
                    <div><.status_badge status={item.status || "unknown"} size={:xs} /></div>
                  <% "attributes" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")}</div>
                    <div>
                      <.icon
                        :if={Map.has_key?(@attribute_map, item.uuid)}
                        name="hero-swatch"
                        class="w-4 h-4 text-primary/60"
                      />
                      <span :if={!Map.has_key?(@attribute_map, item.uuid)}>—</span>
                    </div>
                  <% "files" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}</div>
                    <div class="tabular-nums">{Map.get(@file_counts, item.uuid, 0)}</div>
                  <% "description" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}</div>
                    <div class="line-clamp-2">{item.description || "—"}</div>
                  <% "updated" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated")}</div>
                    <div>{Calendar.strftime(item.updated_at, "%Y-%m-%d %H:%M")}</div>
                  <% "created" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Created")}</div>
                    <div>{Calendar.strftime(item.inserted_at, "%Y-%m-%d %H:%M")}</div>
                  <% _ -> %>
                <% end %>
              <% end %>
            </div>
          </:card_body>
          <:card_actions :let={item}>
            <.item_card_menu
              :if={item.uuid}
              item={item}
              edit_path={@edit_path_fn}
              on_delete="delete_item"
              pdf_search_event="show_pdf_search"
            />
          </:card_actions>
          <%!-- Desktop table view: sort headers, bulk-select, DnD unchanged --%>
          <.table_default_header>
            <.table_default_row>
              <.drag_handle_header_cell :if={@draggable?} />
              <.bulk_select_header_cell
                id="level-items-select-all"
                aria_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select all items")}
              />
              <%!-- Featured images get their own slim column (inline-left
                   of the name made rows jagged); only when some row on
                   this level actually has one. --%>
              <.table_default_header_cell :if={any_media_thumb?(@items, @file_counts)} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5"></.table_default_header_cell>
              <.sort_header_cell field={:name} sort={%{by: @items_sort_by, dir: @items_sort_dir}} event="toggle_sort_items">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
              </.sort_header_cell>
              <%= for col <- @items_columns do %>
                <%= case col do %>
                  <% "sku" -> %>
                    <.sort_header_cell field={:sku} sort={%{by: @items_sort_by, dir: @items_sort_dir}} event="toggle_sort_items">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")}
                    </.sort_header_cell>
                  <% "price" -> %>
                    <.sort_header_cell field={:base_price} sort={%{by: @items_sort_by, dir: @items_sort_dir}} event="toggle_sort_items">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price")}
                    </.sort_header_cell>
                  <% "unit" -> %>
                    <.table_default_header_cell>
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit")}
                    </.table_default_header_cell>
                  <% "status" -> %>
                    <.sort_header_cell field={:status} sort={%{by: @items_sort_by, dir: @items_sort_dir}} event="toggle_sort_items">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                    </.sort_header_cell>
                  <% "attributes" -> %>
                    <.table_default_header_cell>
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")}
                    </.table_default_header_cell>
                  <% "files" -> %>
                    <.table_default_header_cell>
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}
                    </.table_default_header_cell>
                  <% "description" -> %>
                    <.table_default_header_cell>
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
                    </.table_default_header_cell>
                  <% "updated" -> %>
                    <.table_default_header_cell>
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated")}
                    </.table_default_header_cell>
                  <% "created" -> %>
                    <.table_default_header_cell>
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Created")}
                    </.table_default_header_cell>
                  <% _ -> %>
                <% end %>
              <% end %>
              <.table_default_header_cell class="text-right whitespace-nowrap">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}
              </.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <.sortable_tbody
            id={"items-body-" <> (@current_category_uuid || "root")}
            enabled={@reorderable?}
            event="reorder_items"
          >
            <.sortable_row :for={item <- @items} item_id={item.uuid}>
              <.drag_handle_cell :if={@reorderable?} />
              <%!-- Single-item list: keep the column width so the layout
                   doesn't jump when a delete drops the list to one row. --%>
              <td :if={@draggable? and not @reorderable?} class="w-8"></td>
              <.bulk_select_cell value={item.uuid} />
              <.table_default_cell :if={any_media_thumb?(@items, @file_counts)} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
                <.featured_thumb
                  resource={item}
                  on_click="show_product_card"
                  has_files={Map.get(@file_counts, item.uuid, 0) > 0}
                />
              </.table_default_cell>
              <.item_pricing_cell
                item={item}
                edit_path={@edit_path_fn}
                has_attributes={Map.has_key?(@attribute_map, item.uuid)}
                file_count={Map.get(@file_counts, item.uuid, 0)}
                columns={@items_columns}
              />
              <.item_row_menu
                item={item}
                edit_path={@edit_path_fn}
                on_delete="delete_item"
                pdf_search_event="show_pdf_search"
              />
            </.sortable_row>
          </.sortable_tbody>
        </.table_default>
      </.bulk_select_scope>

      <%!-- ── Deleted list: existing item_table (read-only-ish) ── --%>
      <.item_table
        :if={@items != [] and @view_mode == "deleted"}
        file_counts={@file_counts}
        attribute_map={@attribute_map}
        items={@items}
        columns={[:name, :sku, :unit, :status]}
        on_restore="restore_item"
        on_permanent_delete="show_delete_confirm"
        permanent_delete_type="item"
        cards={true}
        show_toggle={false}
        storage_key="catalogue-detail-items"
        id="level-items-deleted"
        wrapper_class="overflow-x-auto shadow-none rounded-none"
        selectable={true}
        selected_uuids={@selected_items}
        on_toggle_select="toggle_select_item"
      />

      <p :if={@items == []} class="text-sm text-base-content/40 text-center py-8">
        {level_items_empty(@current_category, @view_mode)}
      </p>

      <%!-- Core load-more footer: "Showing N of M" + a manual button,
           and (via `infinite`) auto-loads on scroll through core's
           InfiniteScroll hook. --%>
      <.load_more
        :if={@items != []}
        id="level-items-load-more"
        loaded={length(@items)}
        total={@items_total}
        noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
        infinite
        cursor={"items-#{@items_offset}"}
      />

      <%!-- Strategy reorder modal (non-deleted lists). Kept-in-DOM so the
           toolbar's `data-bulk-opens-dialog` opens it instantly. --%>
      <.reorder_modal
        :if={@view_mode != "deleted"}
        id="items-reorder-modal"
        show={@show_items_reorder}
        on_close="close_items_reorder_modal"
        on_apply="apply_items_reorder"
        selected_count={length(@reorder_captured_uuids)}
        total_count={@items_total}
        strategies={item_reorder_strategies()}
        noun_singular={Gettext.gettext(PhoenixKitCatalogue.Gettext, "item")}
        noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
      />
    </div>
    """
  end

  # Orders sibling categories for a reorder strategy; "reverse" reverses
  # the manual order (position, name-tiebroken), matching the drag order.
  defp order_categories_for_strategy(cats, :name_asc),
    do: Enum.sort_by(cats, &String.downcase(&1.name || ""))

  defp order_categories_for_strategy(cats, :name_desc),
    do: Enum.sort_by(cats, &String.downcase(&1.name || ""), :desc)

  defp order_categories_for_strategy(cats, :created_desc),
    do: Enum.sort_by(cats, & &1.inserted_at, {:desc, DateTime})

  defp order_categories_for_strategy(cats, :created_asc),
    do: Enum.sort_by(cats, & &1.inserted_at, {:asc, DateTime})

  defp order_categories_for_strategy(cats, :reverse) do
    cats
    |> Enum.sort_by(&{&1.position, String.downcase(&1.name || "")})
    |> Enum.reverse()
  end

  # Active-list sort dropdown options. `:position` is "Manual" (the DnD
  # mode). gettext via the module backend so labels localize.
  # In-memory categories sort — the list is small and already loaded.
  # Manual (:position) mirrors the DB order and is what enables drag.
  defp sort_categories(categories, counts, sort_by, dir) do
    sorted =
      case sort_by do
        :position -> Enum.sort_by(categories, &{&1.position, String.downcase(&1.name || "")})
        :name -> Enum.sort_by(categories, &String.downcase(&1.name || ""))
        :items -> Enum.sort_by(categories, &Map.get(counts, &1.uuid, 0))
        :updated -> Enum.sort_by(categories, & &1.updated_at)
      end

    if sort_by != :position and dir == :desc, do: Enum.reverse(sorted), else: sorted
  end

  defp category_sort_options do
    [
      {:position, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manual")},
      {:name, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")},
      {:items, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")},
      {:updated, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated")}
    ]
  end

  defp item_sort_options do
    [
      {:position, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manual")},
      {:name, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")},
      {:sku, Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")},
      {:base_price, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price")},
      {:status, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
    ]
  end

  # Strategy-reorder modal options. Values must match the keys in
  # `@items_reorder_strategy_map`.
  defp item_reorder_strategies do
    [
      {"name_asc", Gettext.gettext(PhoenixKitCatalogue.Gettext, "A → Z by name")},
      {"name_desc", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Z → A by name")},
      {"created_desc", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Newest first")},
      {"created_asc", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Oldest first")},
      {"reverse", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Reverse current order")}
    ]
  end

  # ── Drill-level label helpers ────────────────────────────────────

  # ── Origin-aware navigation ──────────────────────────────────────
  # "Add Item should be aware where it's clicked": the level you're on
  # travels with you — the new-item/new-category forms prefill the
  # category/parent, and return_to brings save/cancel back HERE instead
  # of dumping everyone at the catalogue root.

  defp current_level_path(assigns) do
    case assigns.current_category do
      %Category{uuid: uuid} -> Paths.category_browse(assigns.catalogue_uuid, uuid)
      :uncategorized -> Paths.uncategorized_browse(assigns.catalogue_uuid)
      _ -> Paths.catalogue_detail(assigns.catalogue_uuid)
    end
  end

  defp new_item_path(assigns) do
    query =
      case assigns.current_category do
        %Category{uuid: uuid} -> [{"category", uuid}]
        _ -> []
      end ++ [{"return_to", current_level_path(assigns)}]

    Paths.item_new(assigns.catalogue_uuid) <> "?" <> URI.encode_query(query)
  end

  defp new_category_path(assigns) do
    query =
      case assigns.current_category do
        %Category{uuid: uuid} -> [{"parent_uuid", uuid}]
        _ -> []
      end ++ [{"return_to", current_level_path(assigns)}]

    Paths.category_new(assigns.catalogue_uuid) <> "?" <> URI.encode_query(query)
  end

  # 1-arity closure for the item tables' edit_path attrs — every edit
  # link from this page carries the level to return to.
  defp item_edit_with_return(assigns) do
    query = "?" <> URI.encode_query([{"return_to", current_level_path(assigns)}])
    fn uuid -> Paths.item_edit(uuid) <> query end
  end

  defp current_node_label(:uncategorized),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uncategorized")

  defp current_node_label(%Category{} = cat), do: cat.name
  defp current_node_label(_), do: ""

  defp search_placeholder(nil),
    do:
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search items by name, description, or SKU...")

  defp search_placeholder(:uncategorized),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search uncategorized items...")

  defp search_placeholder(%Category{}),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search within this category...")

  defp level_items_empty(_current, "deleted"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Nothing deleted here.")

  defp level_items_empty(_current, "inactive"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No inactive items here.")

  defp level_items_empty(_current, "discontinued"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No discontinued items here.")

  defp level_items_empty(:uncategorized, _),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No uncategorized items.")

  defp level_items_empty(_current, _),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items in this category.")
end
