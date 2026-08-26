defmodule PhoenixKitCatalogue.Web.Components.ItemSelectorModal do
  @moduledoc """
  Catalogue item selector modal: the catalogue's analogue of core's
  `MediaSelectorModal`. A logged-in user browses the catalogue inside a
  modal — search, category chips, photo-forward card grid — picks items,
  sets a quantity per item, reviews the selection in a tray, and confirms.

  ## Usage

      # In the parent LiveView's template. Mount it with :if — unmounting
      # on close is what gives clean reopen semantics (fresh search, fresh
      # scroll, preselects re-read).
      <.live_component
        :if={@show_item_selector}
        module={PhoenixKitCatalogue.Web.Components.ItemSelectorModal}
        id="order-item-selector"
        scope={%{catalogue_uuids: [@catalogue.uuid]}}
        selected={@order_lines_by_uuid}
      />

  ## Required host wiring (do not skip — silent failure otherwise)

  This is a `LiveComponent`; it reports through process messages to the
  host LiveView, exactly like `MediaSelectorModal`. The host MUST handle
  both, or a confirmed selection is silently dropped:

    * `handle_info({:items_selected, %{id: id, mode: mode, picks: picks}}, socket)`
      — fired on Confirm, and only when at least one available pick
      exists: with nothing confirmable the event is refused server-side,
      exactly as the button is disabled client-side, so `picks` is never
      `[]`. Each pick is a map with `:uuid`, `:qty`
      (**always** a `Decimal`, integers included — hosts write one clause),
      `:unit`, and a display snapshot: `:name`, `:sku`, `:price`,
      `:line_total` (`price × qty`, nil when the item has no price) and
      `:photo_url` (a signed URL — it expires, render it, never persist
      it). The snapshot is for rendering the host's own summary without a
      re-query; it is NOT an order record — re-read and re-price items
      server-side when the selection becomes something real.
    * `handle_info({:item_selector_closed, %{id: id}}, socket)` — fired on
      cancel/ESC/backdrop, AND after a confirm. Reset the `:if` assign
      here.

  ## Views and columns

  Two presentations over the same fetch: `view: "table"` (the default — a
  compact admin-look list) and `view: "card"` (the photo-forward grid). A
  toggle beside the search box switches them; the choice is transient and
  the host attr only sets the STARTING view — like `scope`, it is read at
  init and not refreshed by later parent renders.

  Table columns are a host contract, because the popup can be
  client-facing: pass `columns` as a non-empty list from
  `Browse.table_columns/0` (`:thumb :name :sku :manufacturer :unit :price
  :qty`) in display order, and only those render. Unknown entries raise.
  Omitted, the full set applies minus what `show_sku: false` /
  `show_prices: false` already opt out of. Omitting `:qty` hides the
  inline stepper — quantities are then edited in the tray only.

  ## Selection modes

  `selection_mode: "click"` (default) is the classic picker: clicking a
  row/card toggles it, and the stepper appears once selected.
  `selection_mode: "quantity"` is the order-sheet flavour: EVERY rendered
  row shows its stepper at 0, entering a positive quantity (plus button
  or typing) IS the selection, stepping back to 0 removes it, and
  rows/cards are not click-targets at all — no separate "select" step.
  The tray, Confirm, and every guard behave identically in both modes.

  ## Scope

  `scope` fixes what the user may browse: any of `:catalogue_uuids`,
  `:category_uuids`, `:only`, `:statuses`, `:include_descendants` (the
  `Catalogue.search_items/2` vocabulary). It is enforced in `BrowseState`
  — every fetch re-derives from it, and client events can only narrow
  within it, so a crafted event cannot browse or select outside what the
  host allowed. Selection events are additionally accepted only for uuids
  the component itself has rendered (or that arrived preselected).

  ## Preselection

  `selected` is `%{uuid => qty}` (string uuids, `Decimal` or integer
  quantities). Preselected items are hydrated at mount ignoring scope —
  the tray must be able to render what the host handed it. A hydrated item
  that falls OUTSIDE the scope renders in the tray marked unavailable and
  is excluded from the confirm picks, never silently dropped. A uuid that
  no longer resolves at all (deleted or unknown) IS dropped — there is
  nothing to render. Hydrated quantities are clamped like typed ones
  (min/max/precision and the absolute ceiling), and in `:single` mode at
  most one preselected entry survives (first by uuid).

  ## Quantities

  `qty_precision: 0` (default) is whole numbers; a positive precision
  turns the same stepper decimal-capable ("2.5" of unit "L"). The input
  commits on blur/Enter; decimal commas are accepted ("2,5" — ru/et
  keyboards); all limits re-clamped server-side.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]
  import PhoenixKitCatalogue.Web.Components.Browse

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.BrowseState
  alias PhoenixKitCatalogue.Catalogue.Tree
  alias PhoenixKitCatalogue.Web.Components.Browse

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       initialized: false,
       tray_open: false,
       drafts: %{}
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id]))

    if socket.assigns.initialized do
      # A parent re-render must not clobber live selection state (the
      # classic LiveComponent update/2 trap) — after init, only cosmetic
      # props may refresh.
      {:ok, assign(socket, Map.take(assigns, [:title, :show_prices, :show_sku]))}
    else
      {:ok, initialize(socket, assigns)}
    end
  end

  defp initialize(socket, assigns) do
    # BrowseState.init/1 validates the scope keys (atoms, search_items/2
    # vocabulary) so a string-keyed map cannot silently widen browsing.
    browse =
      BrowseState.init(
        scope: expand_scope(assigns[:scope] || %{}),
        per_page: assigns[:per_page] || 24
      )

    {browse, effect} = BrowseState.command(browse, :reset)

    locale = assigns[:locale] || Gettext.get_locale(PhoenixKitCatalogue.Gettext)
    qty_precision = assigns[:qty_precision] || 0
    mode = assigns[:mode] || :multiple
    scope = browse.scope

    # Bounds are normalized to the precision once, here: clamp/2 applies
    # qty_max AFTER rounding, so a fractional max under qty_precision: 0
    # would reintroduce the fraction it just removed. Max floors, min
    # ceils — both stay inside the host's stated bound.
    limits = %{
      qty_min: Decimal.round(to_decimal(assigns[:qty_min] || 1), qty_precision, :ceiling),
      qty_max:
        assigns[:qty_max] && Decimal.round(to_decimal(assigns[:qty_max]), qty_precision, :floor),
      qty_precision: qty_precision
    }

    display = display_opts(assigns)

    socket =
      socket
      |> assign(display)
      |> assign(
        initialized: true,
        mode: mode,
        locale: locale,
        view: resolve_view!(assigns[:view]),
        columns: resolve_columns!(assigns[:columns], display),
        selection_mode: resolve_selection_mode!(assigns[:selection_mode]),
        qty_precision: qty_precision,
        qty_min: limits.qty_min,
        qty_max: limits.qty_max,
        categories: chip_categories(scope, locale),
        presented: %{},
        selection: hydrate_preselection(assigns[:selected] || %{}, scope, locale, limits, mode),
        browse: browse
      )

    run_fetch(socket, effect)
  end

  defp resolve_view!(nil), do: "table"
  defp resolve_view!(view) when view in ["table", "card"], do: view
  defp resolve_view!(view) when view in [:table, :card], do: to_string(view)

  defp resolve_view!(other),
    do:
      raise(
        ArgumentError,
        ~s(ItemSelectorModal view must be "table" or "card", got: #{inspect(other)})
      )

  defp resolve_selection_mode!(nil), do: "click"
  defp resolve_selection_mode!(mode) when mode in ["click", "quantity"], do: mode
  defp resolve_selection_mode!(mode) when mode in [:click, :quantity], do: to_string(mode)

  defp resolve_selection_mode!(other),
    do:
      raise(
        ArgumentError,
        ~s(ItemSelectorModal selection_mode must be "click" or "quantity", got: #{inspect(other)})
      )

  # The popup is potentially client-facing, so columns are a host contract:
  # nothing renders that the embed didn't ask for. With no explicit list,
  # the full vocabulary applies minus whatever show_sku/show_prices already
  # opt out of; an explicit list is taken verbatim, in order, and unknown
  # entries raise — a silently-dropped column is how a price ends up shown
  # to the wrong audience's sibling.
  defp resolve_columns!(nil, display) do
    Enum.reject(
      Browse.table_columns(),
      &((&1 == :sku and not display.show_sku) or (&1 == :price and not display.show_prices))
    )
  end

  defp resolve_columns!(columns, _display) when is_list(columns) and columns != [] do
    case Enum.reject(columns, &(&1 in Browse.table_columns())) do
      [] ->
        columns

      bad ->
        raise ArgumentError,
              "ItemSelectorModal columns has unknown entries #{inspect(bad)} — " <>
                "use #{inspect(Browse.table_columns())}"
    end
  end

  defp resolve_columns!(other, _display),
    do:
      raise(
        ArgumentError,
        "ItemSelectorModal columns must be a non-empty list of atoms, got: #{inspect(other)}"
      )

  # A parent-category scope means "that category and its subtree"
  # (include_descendants defaults to true across the search vocabulary),
  # but chips and `BrowseState.category_allowed?/2` compare literally — so
  # descendant chips vanished from the row and narrowing to one was
  # rejected as out of scope. Expand the subtree ONCE here and hand every
  # consumer (query, chips, allowed?, in_scope?) the same literal list.
  # Anything not shaped like an expandable scope passes through untouched
  # for BrowseState.init/1 to validate loudly.
  defp expand_scope(scope) do
    scope = if is_map(scope), do: scope, else: Map.new(scope)

    case scope[:category_uuids] do
      uuids when is_list(uuids) and uuids != [] ->
        if Map.get(scope, :include_descendants, true) do
          # subtree_uuids_for/1 returns Postgres' raw 16-byte binaries;
          # normalize to the string form chips render and client events
          # carry, or membership checks compare apples to bytes.
          expanded = Enum.map(Tree.subtree_uuids_for(uuids), &normalize_uuid/1)

          scope
          |> Map.put(:category_uuids, expanded)
          |> Map.put(:include_descendants, false)
        else
          scope
        end

      _ ->
        scope
    end
  end

  defp display_opts(assigns) do
    %{
      immediate: assigns[:immediate] || false,
      show_prices: Map.get(assigns, :show_prices, true),
      show_sku: Map.get(assigns, :show_sku, true),
      title: assigns[:title]
    }
  end

  # ── Fetching ─────────────────────────────────────────────────────────

  # Synchronous by design: LiveComponent events serialize, so there is no
  # stale-result race today. BrowseState still carries a generation, so
  # moving this into start_async later is a drop-in, not a redesign.
  defp run_fetch(socket, :noop), do: socket

  defp run_fetch(socket, {:fetch, opts, gen}) do
    %{browse: browse, locale: locale} = socket.assigns

    items = Catalogue.search_items(browse.search, opts)
    total = Catalogue.count_search_items(browse.search, opts)
    presented_page = Browse.present_items(items, locale)

    browse = BrowseState.ingest(browse, gen, presented_page, total)

    # `presented` gates card_click ("only items this component rendered"),
    # so it mirrors ingest/4's discipline: a fresh fetch (offset 0 — new
    # search, chip, or reset) replaces it rather than accreting pages from
    # every query this modal ever ran, and a stale gen (rejected by ingest,
    # so `browse.gen != gen`) contributes nothing — without that guard the
    # documented start_async migration would leak superseded pages in.
    # Load-more keeps accumulating, matching the grid.
    presented =
      if browse.gen == gen do
        base = if Keyword.get(opts, :offset, 0) == 0, do: %{}, else: socket.assigns.presented
        Enum.into(presented_page, base, fn item -> {item.uuid, item} end)
      else
        socket.assigns.presented
      end

    assign(socket, browse: browse, presented: presented)
  end

  # ── Preselection hydration ───────────────────────────────────────────

  # The scope-exempt read: the tray must render whatever the host handed
  # in, so these uuids are fetched directly. Availability is then judged
  # against the scope so out-of-scope rows can be shown-but-excluded.
  # `list_items_by_uuids/2` is one query and already drops soft-deleted
  # rows, matching the fetch layer — a uuid that no longer resolves (deleted
  # or unknown) is dropped from the tray entirely.
  #
  # Hydrated quantities go through the same `clamp/2` as typed and stepped
  # ones — "all limits re-clamped server-side" covers the host's numbers
  # too, and an absurd host qty must not outlive mount. In `:single` mode
  # at most one entry survives (first by uuid, stable): the tray, the
  # confirm payload, and `select/2`'s replace-not-add all promise a single
  # pick, and a multi-entry `selected` must not be the one path around it.
  defp hydrate_preselection(selected, _scope, _locale, _limits, _mode) when selected == %{},
    do: %{}

  defp hydrate_preselection(selected, scope, locale, limits, mode) do
    expanded_categories = expand_scope_categories(scope)

    items_by_uuid =
      selected
      |> Map.keys()
      |> Catalogue.list_items_by_uuids()
      |> Map.new(&{to_string(&1.uuid), &1})

    selection =
      selected
      |> Enum.flat_map(fn {uuid, qty} ->
        uuid = to_string(uuid)

        case items_by_uuid[uuid] do
          nil ->
            []

          item ->
            [presented] = Browse.present_items([item], locale)

            [
              {uuid,
               %{
                 qty: clamp(to_decimal(qty), limits),
                 item: presented,
                 available: in_scope?(item, scope, expanded_categories)
               }}
            ]
        end
      end)
      |> Map.new()

    case {mode, map_size(selection)} do
      {:single, n} when n > 1 ->
        {uuid, entry} = Enum.min_by(selection, fn {uuid, _entry} -> uuid end)
        %{uuid => entry}

      _ ->
        selection
    end
  end

  # Mirrors every restriction `query_opts/1` sends to the fetch layer —
  # including `:only`, descendant-expanded `:category_uuids`, and the
  # deleted-parent joins — or a preselected row the browse itself could
  # never return would confirm as available.
  defp in_scope?(item, scope, expanded_categories) do
    parents_alive?(item) and
      allowed?(scope[:catalogue_uuids], item.catalogue_uuid) and
      category_in_scope?(expanded_categories, item.category_uuid) and
      allowed?(scope[:statuses], item.status) and
      only_ok?(scope[:only], item)
  end

  # The search joins exclude items under a soft-deleted catalogue or
  # category; `list_items_by_uuids/2` only filters the item's own status,
  # so the hydration path re-checks the parents it preloads. A NotLoaded
  # association has no :status key and falls through to true — absent
  # evidence is not exclusion.
  defp parents_alive?(item) do
    not match?(%{status: "deleted"}, item.catalogue) and
      not match?(%{status: "deleted"}, item.category)
  end

  defp allowed?(nil, _value), do: true
  defp allowed?([], _value), do: true
  defp allowed?(_list, nil), do: false
  defp allowed?(list, value), do: normalize_uuid(value) in Enum.map(list, &normalize_uuid/1)

  defp category_in_scope?(nil, _value), do: true
  defp category_in_scope?([], _value), do: true
  defp category_in_scope?(_expanded, nil), do: false

  defp category_in_scope?(expanded, value) do
    MapSet.member?(expanded, normalize_uuid(value))
  end

  # Same expansion Search.search_items/2 applies (Tree.subtree_uuids_for/1,
  # skipped when the host passed include_descendants: false).
  defp expand_scope_categories(scope) do
    case scope[:category_uuids] do
      nil ->
        nil

      [] ->
        []

      uuids ->
        raw =
          if scope[:include_descendants] == false,
            do: uuids,
            else: Tree.subtree_uuids_for(uuids)

        MapSet.new(Enum.map(raw, &normalize_uuid/1))
    end
  end

  defp normalize_uuid(nil), do: nil

  defp normalize_uuid(bin) when is_binary(bin) and byte_size(bin) == 16 do
    case Ecto.UUID.load(bin) do
      {:ok, uuid} -> uuid
      :error -> bin
    end
  end

  defp normalize_uuid(other), do: to_string(other)

  defp only_ok?(:uncategorized_only, item), do: is_nil(item.category_uuid)
  defp only_ok?(:categorized_only, item), do: not is_nil(item.category_uuid)
  defp only_ok?(_other, _item), do: true

  # Chips only make sense inside one catalogue — with several (or all),
  # a flat chip row of every category across catalogues is noise, and
  # search does the narrowing instead.
  #
  # Metadata-only: `list_categories_for_catalogue/1` preloads every item
  # in every item category, which is a full-catalogue load just to render
  # chips. Names go through `translated_name/2` — chips face the viewer,
  # and the primary-language column ignored their locale (PR #76 review,
  # finding 14).
  # An :uncategorized_only scope contradicts every category narrowing —
  # search_items/2 raises on the combination — so offering chips would
  # offer only invalid actions (BrowseState rejects them too; see
  # category_allowed?/2).
  defp chip_categories(%{only: :uncategorized_only}, _locale), do: []

  defp chip_categories(%{catalogue_uuids: [catalogue_uuid]} = scope, locale) do
    categories = Catalogue.list_categories_metadata_for_catalogue(catalogue_uuid)

    categories =
      case scope[:category_uuids] do
        nil ->
          categories

        [] ->
          categories

        allowed ->
          allowed = Enum.map(allowed, &to_string/1)
          Enum.filter(categories, fn category -> to_string(category.uuid) in allowed end)
      end

    Enum.map(categories, fn category ->
      %{uuid: to_string(category.uuid), name: translated_name(category, locale)}
    end)
  rescue
    _ -> []
  end

  defp chip_categories(_scope, _locale), do: []

  defp translated_name(record, locale) do
    translation =
      try do
        Catalogue.get_translation(record, locale)
      rescue
        _ -> %{}
      end

    Map.get(translation, "_name") ||
      Map.get(translation, "name") ||
      Map.get(record, :name)
  end

  # ── Events: browsing ─────────────────────────────────────────────────

  @impl true
  def handle_event("set_view", %{"mode" => mode}, socket) when mode in ["table", "card"] do
    {:noreply, assign(socket, :view, mode)}
  end

  def handle_event("browse_search", %{"search" => q}, socket) do
    {browse, effect} = BrowseState.command(socket.assigns.browse, {:search, q})
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  def handle_event("browse_category", %{"uuid" => uuid}, socket) do
    cmd = {:set_category, if(uuid == "", do: nil, else: uuid)}
    {browse, effect} = BrowseState.command(socket.assigns.browse, cmd)
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  def handle_event("load_more", _params, socket) do
    {browse, effect} = BrowseState.command(socket.assigns.browse, :load_more)
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  # ── Events: selection ────────────────────────────────────────────────

  def handle_event("card_click", %{"uuid" => uuid}, socket) do
    selection = socket.assigns.selection

    cond do
      # Quantity-first embeds have no click-selection: the stepper IS the
      # selector. The markup renders nothing clickable; a crafted click is
      # refused here for the same reason.
      socket.assigns.selection_mode == "quantity" ->
        {:noreply, socket}

      Map.has_key?(selection, uuid) ->
        {:noreply, deselect(socket, uuid)}

      # Only items this component itself rendered are selectable — an
      # event with a foreign uuid (crafted, or stale DOM) is refused.
      item = socket.assigns.presented[uuid] ->
        {:noreply, select(socket, item)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("qty_inc", %{"uuid" => uuid}, socket),
    do: {:noreply, step_qty(socket, uuid, :inc)}

  def handle_event("qty_dec", %{"uuid" => uuid}, socket),
    do: {:noreply, step_qty(socket, uuid, :dec)}

  def handle_event("qty_commit", %{"uuid" => uuid, "value" => raw}, socket) do
    # Only rows that are selected — or, quantity-first, RENDERED — get any
    # state at all: without the gate, crafted commits with unique foreign
    # uuids grow `drafts` without bound (put_qty/3 would no-op, but only
    # after the revision bump already stored a key).
    cond do
      Map.has_key?(socket.assigns.selection, uuid) ->
        {:noreply, commit_qty(socket, uuid, raw)}

      socket.assigns.selection_mode == "quantity" and is_map(socket.assigns.presented[uuid]) ->
        {:noreply, commit_first_qty(socket, uuid, raw)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_pick", %{"uuid" => uuid}, socket),
    do: {:noreply, deselect(socket, uuid)}

  def handle_event("toggle_tray", _params, socket),
    do: {:noreply, assign(socket, tray_open: !socket.assigns.tray_open)}

  # ── Events: closing ──────────────────────────────────────────────────

  def handle_event("confirm", _params, socket) do
    # Same predicate that disables the button: a crafted confirm with
    # nothing confirmable must not deliver `{picks: []}` to a host that
    # trusts the button state. The modal simply stays open.
    if confirmable_selection?(socket.assigns.selection) do
      send(self(), {:items_selected, confirm_payload(socket.assigns)})
      send(self(), {:item_selector_closed, %{id: socket.assigns.id}})
    end

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    send(self(), {:item_selector_closed, %{id: socket.assigns.id}})
    {:noreply, socket}
  end

  # A crafted payload with missing keys must degrade to a no-op, not a
  # FunctionClauseError that takes the whole LiveView down.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Selected row: bump the per-row revision so the input's id changes —
  # morphdom will not reset typed garbage (or "01") when the value attr is
  # unchanged — then re-clamp the parse.
  defp commit_qty(socket, uuid, raw) do
    socket = bump_qty_rev(socket, uuid)

    case parse_qty(raw, socket.assigns) do
      {:ok, qty} -> put_qty(socket, uuid, qty)
      :error -> socket
    end
  end

  # Quantity-first, unselected row: a typed POSITIVE quantity is the
  # selection ("0" stays unselected — in this mode zero IS the unselected
  # state, whatever qty_min says).
  defp commit_first_qty(socket, uuid, raw) do
    socket = bump_qty_rev(socket, uuid)

    case parse_qty(raw, socket.assigns) do
      {:ok, qty} ->
        if Decimal.gt?(qty, 0),
          do: socket |> select(socket.assigns.presented[uuid]) |> put_qty(uuid, qty),
          else: socket

      :error ->
        socket
    end
  end

  # ── Selection mechanics ──────────────────────────────────────────────

  defp select(socket, item) do
    entry = %{qty: clamp(item.default_qty, socket.assigns), item: item, available: true}

    socket =
      case socket.assigns.mode do
        # Single mode replaces the previous pick — the map never grows.
        :single -> assign(socket, selection: %{item.uuid => entry})
        _ -> assign(socket, selection: Map.put(socket.assigns.selection, item.uuid, entry))
      end

    if socket.assigns.mode == :single and socket.assigns.immediate do
      send(self(), {:items_selected, confirm_payload(socket.assigns)})
      send(self(), {:item_selector_closed, %{id: socket.assigns.id}})
    end

    socket
  end

  defp deselect(socket, uuid) do
    assign(socket,
      selection: Map.delete(socket.assigns.selection, uuid),
      drafts: Map.delete(socket.assigns.drafts, uuid)
    )
  end

  defp step_qty(socket, uuid, direction) do
    case socket.assigns.selection[uuid] do
      nil ->
        # Quantity-first: plus on an unselected (but RENDERED — the
        # presented gate applies to steppers exactly as to clicks) row is
        # the selection itself, entering at the minimum quantity.
        with "quantity" <- socket.assigns.selection_mode,
             :inc <- direction,
             %{} = item <- socket.assigns.presented[uuid] do
          select(socket, item)
        else
          _ -> socket
        end

      %{qty: qty} ->
        step = Decimal.new(1)
        next = if direction == :inc, do: Decimal.add(qty, step), else: Decimal.sub(qty, step)

        # Stepping below the minimum IS deselection — the minus button on
        # a qty-1 card removes the pick, which is what a client expects.
        if Decimal.compare(next, socket.assigns.qty_min) == :lt do
          deselect(socket, uuid)
        else
          put_qty(socket, uuid, next)
        end
    end
  end

  defp put_qty(socket, uuid, qty) do
    case socket.assigns.selection[uuid] do
      nil ->
        socket

      entry ->
        qty = clamp(qty, socket.assigns)
        assign(socket, selection: Map.put(socket.assigns.selection, uuid, %{entry | qty: qty}))
    end
  end

  defp bump_qty_rev(socket, uuid) do
    update(socket, :drafts, fn drafts ->
      Map.update(drafts, uuid, 1, &(&1 + 1))
    end)
  end

  # A hard ceiling even when the host sets no qty_max: Decimal.parse
  # accepts "1e1000000" as a full match, and an absurd exponent is a
  # process-DoS the moment it hits multiplication.
  @qty_ceiling Decimal.new(1_000_000)

  # Quantities arrive from the client and are clamped here, not trusted
  # from input attributes: min, max, precision AND the absolute ceiling are
  # all re-enforced. The ceiling lives here (not only in parse_qty/2) so
  # every inlet — typed, stepped, hydrated — is capped: a held/scripted
  # plus button walks past any softer bound one event at a time.
  defp clamp(qty, %{qty_min: min, qty_max: max, qty_precision: precision}) do
    qty
    |> Decimal.round(precision)
    |> Decimal.max(min)
    |> Decimal.min(@qty_ceiling)
    |> then(fn q -> if max, do: Decimal.min(q, max), else: q end)
  end

  defp parse_qty(raw, assigns) when is_binary(raw) do
    # ru/et keyboards produce a decimal comma; Decimal.parse wants a dot.
    # Plain digits only — exponent forms are rejected before parse.
    # Below-minimum input is rejected (field reverts) rather than silently
    # clamped up; with `qty_min: 0` that correctly admits a typed "0",
    # which the stepper's minus button could already reach.
    normalized = raw |> String.trim() |> String.replace(",", ".")

    with true <- Regex.match?(~r/^\d{1,12}(\.\d{1,6})?$/, normalized),
         {qty, ""} <- Decimal.parse(normalized),
         false <- Decimal.lt?(qty, assigns.qty_min) do
      {:ok, clamp(qty, assigns)}
    else
      _ -> :error
    end
  end

  defp parse_qty(_, _), do: :error

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal(n) when is_binary(n) do
    case Decimal.parse(String.trim(n)) do
      {d, ""} -> d
      _ -> raise ArgumentError, "not a quantity: #{inspect(n)}"
    end
  end

  # ── Confirm payload ──────────────────────────────────────────────────

  defp confirm_payload(assigns) do
    picks =
      assigns.selection
      # An unavailable row (preselected, now outside scope) is shown in
      # the tray but must never reach the host as a pick — the host's
      # scope said no.
      |> Enum.filter(fn {_uuid, entry} -> entry.available end)
      |> Enum.sort_by(fn {_uuid, entry} -> entry.item.name || "" end)
      |> Enum.map(fn {uuid, %{qty: qty, item: item}} ->
        %{
          uuid: uuid,
          qty: qty,
          unit: item.unit,
          name: item.name,
          sku: item.sku,
          price: item.price,
          line_total: item.price && Decimal.mult(item.price, qty),
          photo_url: item.photo_url
        }
      end)

    %{id: assigns.id, mode: assigns.mode, picks: picks}
  end

  # ── Render helpers ───────────────────────────────────────────────────

  defp qty_display(assigns, uuid) do
    case assigns.selection[uuid] do
      nil -> ""
      %{qty: qty} -> format_qty(qty)
    end
  end

  # Whether a rendered row/card shows its stepper: any selected available
  # entry — plus, in quantity-first mode, EVERY rendered row (rendered
  # means in-scope by construction, and the stepper at 0 IS the selector).
  defp stepper?(assigns, uuid) do
    case assigns.selection[uuid] do
      %{available: available} -> available
      nil -> assigns.selection_mode == "quantity"
    end
  end

  # In quantity-first mode an unselected row's stepper reads 0 — zero is
  # the unselected state there, whatever qty_min says.
  defp qty_display_or_zero(assigns, uuid) do
    case qty_display(assigns, uuid) do
      "" -> "0"
      qty -> qty
    end
  end

  # See "qty_commit" — part of each stepper input's id, so bumping it
  # recreates the input and discards rejected garbage.
  defp qty_rev(assigns, uuid), do: assigns.drafts[uuid] || 0

  defp format_qty(%Decimal{} = qty), do: Decimal.to_string(Decimal.normalize(qty), :normal)

  defp selection_count(selection), do: map_size(selection)

  defp confirmable_selection?(selection),
    do: Enum.any?(selection, fn {_uuid, entry} -> entry.available end)

  defp selection_total(selection) do
    selection
    |> Enum.filter(fn {_u, e} -> e.available and e.item.price end)
    |> Enum.reduce(Decimal.new(0), fn {_u, e}, acc ->
      Decimal.add(acc, Decimal.mult(e.item.price, e.qty))
    end)
  end

  defp any_priced?(selection),
    do: Enum.any?(selection, fn {_u, e} -> e.available and e.item.price end)

  defp modal_title(nil), do: gettext("Select items")
  defp modal_title(title), do: title

  # ── Render ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.modal show={true} id={"#{@id}-dialog"} on_close="cancel" max_width="4xl" max_height="85vh">
        <:title>{modal_title(@title)}</:title>

        <div class="flex flex-col gap-3">
          <%!-- Header: search + chips. --%>
          <%!-- phx-submit is load-bearing: a phx-change form WITHOUT it is
          treated by LiveView's client as an external form — Enter would
          run a NATIVE submit (full page navigation) and destroy the modal
          and every pick in it. Routing submit at the same handler makes
          Enter a plain re-search. --%>
          <div class="flex items-center gap-2">
            <form
              id={"#{@id}-search-form"}
              class="flex-1"
              phx-change="browse_search"
              phx-submit="browse_search"
              phx-target={@myself}
            >
              <label class="input flex items-center gap-2 w-full">
                <span class="hero-magnifying-glass w-4 h-4 opacity-60"></span>
                <input
                  id={"#{@id}-search"}
                  type="text"
                  name="search"
                  value={@browse.search}
                  placeholder={gettext("Search items…")}
                  phx-debounce="250"
                  autocomplete="off"
                  class="grow"
                />
              </label>
            </form>
            <.view_toggle
              id={"#{@id}-view-toggle"}
              modes={[
                %{mode: "table", icon: "hero-bars-3", label: gettext("List view")},
                %{mode: "card", icon: "hero-squares-2x2", label: gettext("Card view")}
              ]}
              current={@view}
              target={@myself}
            />
          </div>

          <.category_chips
            :if={@categories != []}
            id={"#{@id}-chips"}
            categories={@categories}
            active_uuid={@browse.category_uuid}
            target={@myself}
          />

          <%!-- The scrollable results region: ONE data path (@browse.items),
          two renderers. Only the active view's branch is server-rendered —
          both hidden in the DOM would duplicate qty-form ids. --%>
          <div id={"#{@id}-scroll"} class="overflow-y-auto min-h-[16rem] max-h-[48vh] pr-1">
            <.item_grid :if={@view == "card"} id={"#{@id}-grid"}>
              <%= if @browse.loading? and @browse.items == [] do %>
                <.grid_skeleton id={"#{@id}-skeleton"} count={8} />
              <% end %>
              <%= for item <- @browse.items do %>
                <.item_card
                  id={"#{@id}-card-#{item.uuid}"}
                  item={item}
                  selected={Map.has_key?(@selection, item.uuid)}
                  clickable={@selection_mode != "quantity"}
                  show_price={@show_prices}
                  show_sku={@show_sku}
                  target={@myself}
                >
                  <:footer>
                    <div :if={stepper?(assigns, item.uuid)} class="p-2 pt-0 flex justify-center">
                      <.qty_stepper
                        id={"#{@id}-qty-#{item.uuid}-r#{qty_rev(assigns, item.uuid)}"}
                        uuid={item.uuid}
                        qty={qty_display_or_zero(assigns, item.uuid)}
                        unit={if(@qty_precision > 0, do: item.uuid && item.unit)}
                        precision={@qty_precision}
                        target={@myself}
                        size="xs"
                      />
                    </div>
                  </:footer>
                </.item_card>
              <% end %>
            </.item_grid>

            <.item_table
              :if={@view == "table" and (@browse.items != [] or @browse.loading?)}
              id={"#{@id}-table"}
              columns={@columns}
            >
              <%= if @browse.loading? and @browse.items == [] do %>
                <tr :for={i <- 1..5} id={"#{@id}-row-skeleton-#{i}"}>
                  <td colspan={length(@columns)}><div class="skeleton h-8 w-full"></div></td>
                </tr>
              <% end %>
              <%= for item <- @browse.items do %>
                <.item_row
                  id={"#{@id}-row-#{item.uuid}"}
                  item={item}
                  columns={@columns}
                  selected={Map.has_key?(@selection, item.uuid)}
                  clickable={@selection_mode != "quantity"}
                  target={@myself}
                >
                  <:qty>
                    <.qty_stepper
                      :if={stepper?(assigns, item.uuid)}
                      id={"#{@id}-qty-#{item.uuid}-r#{qty_rev(assigns, item.uuid)}"}
                      uuid={item.uuid}
                      qty={qty_display_or_zero(assigns, item.uuid)}
                      unit={if(@qty_precision > 0, do: item.unit)}
                      precision={@qty_precision}
                      target={@myself}
                      size="xs"
                    />
                  </:qty>
                </.item_row>
              <% end %>
            </.item_table>

            <div :if={@browse.items == [] and not @browse.loading?} class="text-center py-12">
              <div class="text-4xl mb-3 opacity-40">🔍</div>
              <p class="text-base-content/60">{gettext("No items match your search.")}</p>
            </div>

            <div :if={not @browse.exhausted? and @browse.items != []} class="flex justify-center py-3">
              <button
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="load_more"
                phx-target={@myself}
                disabled={@browse.loading?}
              >
                <span :if={@browse.loading?} class="loading loading-spinner loading-xs"></span>
                {gettext("Load more")}
              </button>
            </div>
          </div>

          <%!-- Selection tray. --%>
          <div :if={@mode != :single or not @immediate} class="border-t border-base-300 pt-3">
            <div class="flex items-center justify-between gap-3">
              <button
                type="button"
                class="btn btn-ghost btn-sm gap-2"
                phx-click="toggle_tray"
                phx-target={@myself}
                disabled={@selection == %{}}
                aria-expanded={@tray_open}
              >
                <span class="hero-shopping-cart w-4 h-4"></span>
                {ngettext("%{count} item", "%{count} items", selection_count(@selection),
                  count: selection_count(@selection)
                )}
                <span :if={any_priced?(@selection)} class="text-base-content/60">
                  · {format_price(selection_total(@selection))}
                </span>
              </button>
              <div class="flex gap-2">
                <button
                  type="button"
                  class="btn btn-ghost btn-sm"
                  phx-click="cancel"
                  phx-target={@myself}
                >
                  {gettext("Cancel")}
                </button>
                <button
                  type="button"
                  class="btn btn-primary btn-sm"
                  phx-click="confirm"
                  phx-target={@myself}
                  disabled={not confirmable_selection?(@selection)}
                >
                  {gettext("Confirm selection")}
                </button>
              </div>
            </div>

            <div :if={@tray_open and @selection != %{}} class="mt-3 max-h-[26vh] overflow-y-auto">
              <div
                :for={
                  {uuid, entry} <-
                    Enum.sort_by(@selection, fn {_u, e} -> e.item.name || "" end)
                }
                id={"#{@id}-tray-#{uuid}"}
                class={[
                  "flex items-center gap-3 py-2 border-b border-base-200 last:border-0",
                  !entry.available && "opacity-60"
                ]}
              >
                <img
                  :if={entry.item.photo_url}
                  src={entry.item.photo_url}
                  alt=""
                  class="w-10 h-10 rounded object-cover bg-base-200"
                  loading="lazy"
                />
                <div
                  :if={!entry.item.photo_url}
                  class="w-10 h-10 rounded bg-base-200 flex items-center justify-center text-base-content/40 font-bold"
                >
                  {String.first(entry.item.name || "?")}
                </div>
                <div class="flex-1 min-w-0">
                  <div class="text-sm font-medium truncate">{entry.item.name}</div>
                  <div class="text-xs text-base-content/60 font-mono">{entry.item.sku}</div>
                  <div :if={!entry.available} class="text-xs text-warning">
                    {gettext("Not available in this selection")}
                  </div>
                </div>
                <.qty_stepper
                  :if={entry.available}
                  id={"#{@id}-tray-qty-#{uuid}-r#{qty_rev(assigns, uuid)}"}
                  uuid={uuid}
                  qty={qty_display(assigns, uuid)}
                  unit={if(@qty_precision > 0, do: entry.item.unit)}
                  precision={@qty_precision}
                  target={@myself}
                  size="xs"
                />
                <span :if={entry.available and entry.item.price} class="text-sm font-semibold w-20 text-right">
                  {format_price(Decimal.mult(entry.item.price, entry.qty))}
                </span>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="remove_pick"
                  phx-value-uuid={uuid}
                  phx-target={@myself}
                  aria-label={gettext("Remove")}
                >
                  <span class="hero-x-mark w-4 h-4"></span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </.modal>
    </div>
    """
  end
end
