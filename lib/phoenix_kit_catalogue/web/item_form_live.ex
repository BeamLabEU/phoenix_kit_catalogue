defmodule PhoenixKitCatalogue.Web.ItemFormLive do
  @moduledoc "Create/edit form for catalogue items with multilang support."

  use Phoenix.LiveView
  use PhoenixKitAI.Components.AITranslate.Embed

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]

  import PhoenixKitCatalogue.Web.Components,
    only: [
      attachments_files_panel: 1,
      catalogue_rules_picker: 1,
      metadata_editor: 1
    ]

  import PhoenixKitCatalogue.Web.Helpers,
    only: [
      actor_opts: 1,
      assign_ai_translation: 3,
      ai_translate_config: 1
    ]

  import PhoenixKitAI.Components.AITranslate,
    only: [
      ai_multilang_tabs: 1,
      ai_translate_modal: 1
    ]

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Helpers
  alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  alias PhoenixKitCatalogue.Catalogue.Suppliers
  alias PhoenixKitCatalogue.Metadata
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Item

  @translatable_fields ["name", "description"]
  @preserve_fields %{
    # Translatable primaries: submitted only on the primary tab, so a
    # secondary-tab validate/save must re-inject them or :new loses them.
    "name" => :name,
    "description" => :description,
    "sku" => :sku,
    "base_price" => :base_price,
    "markup_percentage" => :markup_percentage,
    "discount_percentage" => :discount_percentage,
    "default_value" => :default_value,
    "default_unit" => :default_unit,
    "unit" => :unit,
    "status" => :status,
    "category_uuid" => :category_uuid,
    "manufacturer_uuid" => :manufacturer_uuid
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
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    case load_item(action, params) do
      {nil, _, _} ->
        {:ok,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item not found."))
         |> push_navigate(to: Paths.index())}

      {item, changeset, catalogue_uuid} ->
        {:ok,
         socket
         |> assign(:return_to, safe_return_to(params["return_to"]))
         |> mount_form(action, item, changeset, catalogue_uuid)}
    end
  end

  defp valid_origin_category(uuid, catalogue_uuid) when is_binary(uuid) and uuid != "" do
    case Catalogue.get_category(uuid) do
      %PhoenixKitCatalogue.Schemas.Category{catalogue_uuid: ^catalogue_uuid, status: "active"} ->
        uuid

      _ ->
        nil
    end
  end

  defp valid_origin_category(_, _), do: nil

  # Only ever navigate to a caller-supplied path after the core local-path
  # guard — return_to is user-influenced input.
  defp safe_return_to(rt) when is_binary(rt) do
    if Routes.local_path?(rt), do: rt
  end

  defp safe_return_to(_), do: nil

  defp load_item(:new, params) do
    catalogue_uuid = params["catalogue_uuid"]

    # "Add Item" carries the level it was clicked from (?category=...) so the
    # form opens with that category already selected. Validated — a forged or
    # stale uuid must not seed a category from another catalogue.
    item = %Item{
      catalogue_uuid: catalogue_uuid,
      category_uuid: valid_origin_category(params["category"], catalogue_uuid)
    }

    {item, Catalogue.change_item(item), catalogue_uuid}
  end

  defp load_item(:edit, params) do
    case Catalogue.get_item(params["uuid"]) do
      nil ->
        Logger.warning("Item not found for edit: #{params["uuid"]}")
        {nil, nil, nil}

      item ->
        item =
          item
          |> PhoenixKit.RepoHelper.repo().preload([:category, :manufacturer])
          |> normalize_display_decimals()

        {item, Catalogue.change_item(item), item.catalogue_uuid}
    end
  end

  # DB-stored decimals keep the column's scale (e.g. DECIMAL(12, 4) gives
  # back `#Decimal<5.0000>` for what the user typed as `5`). Strip the
  # insignificant trailing zeros once at load time so the initial form
  # render shows `5`; user-typed values during validate are left alone.
  defp normalize_display_decimals(%Item{} = item) do
    %{item | default_value: normalize_decimal(item.default_value)}
  end

  defp normalize_decimal(nil), do: nil
  defp normalize_decimal(%Decimal{} = d), do: Decimal.normalize(d)
  defp normalize_decimal(other), do: other

  defp mount_form(socket, action, item, changeset, catalogue_uuid) do
    categories =
      if catalogue_uuid,
        do: Catalogue.list_categories_for_catalogue(catalogue_uuid),
        else: Catalogue.list_all_categories()

    all_categories = if action == :edit, do: Catalogue.list_all_categories(), else: []
    parent_catalogue = load_parent_catalogue(catalogue_uuid)
    kind = catalogue_kind(parent_catalogue)

    # Smart items move between smart catalogues (no category concept);
    # standard items use the existing "pick a category anywhere" flow.
    smart_move_targets =
      if action == :edit and kind == "smart" do
        Catalogue.list_catalogues(kind: :smart) |> Enum.reject(&(&1.uuid == catalogue_uuid))
      else
        []
      end

    socket
    |> assign(
      page_title:
        if(action == :new,
          do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Item"),
          else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: item.name)
        ),
      action: action,
      item: item,
      catalogue_uuid: catalogue_uuid,
      parent_catalogue_name: parent_catalogue && parent_catalogue.name,
      catalogue_kind: kind,
      catalogue_markup: markup_from_catalogue(parent_catalogue),
      catalogue_discount: discount_from_catalogue(parent_catalogue),
      categories: categories,
      manufacturers: Catalogue.list_manufacturers(status: "active"),
      suppliers: Catalogue.list_suppliers(status: "active"),
      all_suppliers: Suppliers.list_all(),
      supplier_infos: load_supplier_infos(action, item),
      supplier_form_open: false,
      supplier_info_draft: %{},
      supplier_history_open: false,
      supplier_history_rows: [],
      supplier_history_name: nil,
      all_categories: all_categories,
      smart_move_targets: smart_move_targets,
      move_target: nil,
      current_tab: :details,
      meta_state: Metadata.build_state(:item, item),
      show_pdf_search: false
    )
    |> Attachments.mount_attachments(item)
    |> Attachments.allow_attachment_upload()
    |> assign_changeset(changeset)
    |> assign_rule_state(item, kind, catalogue_uuid)
    |> mount_multilang()
    |> adjust_multilang_for_item(item)
    |> assign_attribute_state(item, action)
    |> assign_ai_translation("catalogue_item", if(action == :edit, do: item, else: nil))
  end

  # Keeps both :changeset (for <.translatable_field>) and :form (for
  # <.input>/<.select> bindings) in sync — validate and save-error paths
  # go through this helper so they can't drift apart.
  defp assign_changeset(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
  end

  # Smart-catalogue picker state: only populated when the parent
  # catalogue is kind: "smart". For standard catalogues we still assign
  # empty defaults so the render path can reference the keys unconditionally.
  #
  # Note: this runs in `mount/3` and therefore fires twice per page
  # load (HTTP + WebSocket). Moving the data load to `handle_params/3`
  # is tracked as a separate follow-up; here we just make sure the
  # smart branch issues a *single* `list_catalogue_rules/1` query
  # instead of the two it used to (one for the working_rules map and a
  # second for the display order).
  defp assign_rule_state(socket, _item, "smart" = _kind, catalogue_uuid) do
    # Smart-chain guard: a smart catalogue cannot be the referenced
    # target of another smart item (issue #16). The changeset rejects
    # writes; filtering here keeps the picker honest so the user is
    # never offered an option that would fail on save.
    candidates =
      Catalogue.list_catalogues(kind: :standard)
      |> Enum.reject(&(&1.uuid == catalogue_uuid))

    rules =
      case socket.assigns.item do
        %Item{uuid: nil} -> []
        %Item{} = item -> Catalogue.list_catalogue_rules(item)
      end

    existing =
      Map.new(rules, fn rule ->
        to_working_entry({rule.referenced_catalogue_uuid, rule})
      end)

    # Initial display order: existing rules first (by their stored
    # position from `list_catalogue_rules/1`), then the remaining
    # candidates that haven't been turned into rules yet, in
    # catalogue.name order.
    rule_uuids = Enum.map(rules, & &1.referenced_catalogue_uuid)

    rest_uuids =
      candidates
      |> Enum.map(& &1.uuid)
      |> Enum.reject(&(&1 in rule_uuids))

    rule_order = rule_uuids ++ rest_uuids

    assign(socket,
      rule_candidates: candidates,
      working_rules: existing,
      rule_candidate_order: rule_order
    )
  end

  defp assign_rule_state(socket, _item, _kind, _catalogue_uuid) do
    assign(socket, rule_candidates: [], working_rules: %{}, rule_candidate_order: [])
  end

  # Reorders `candidates` to match `rule_candidate_order`. Candidates
  # not in the order list (e.g. catalogues added since mount) are
  # appended at the end. Candidates listed in the order but no longer
  # present are silently dropped.
  defp sort_candidates(candidates, order) when is_list(candidates) and is_list(order) do
    by_uuid = Map.new(candidates, &{&1.uuid, &1})

    ordered =
      order
      |> Enum.flat_map(fn uuid ->
        case Map.fetch(by_uuid, uuid) do
          {:ok, c} -> [c]
          :error -> []
        end
      end)

    leftovers = Enum.reject(candidates, fn c -> c.uuid in order end)

    ordered ++ leftovers
  end

  # Coerce nil units to "percent" on load. Persisted NULL units are a
  # legacy of the earlier "inherit from item.default_unit" behavior;
  # now that the picker no longer inherits, surfacing NULL as "percent"
  # keeps the dropdown honest (what you see is what will be saved).
  defp to_working_entry({uuid, %{value: value, unit: unit}}),
    do: {uuid, %{value: normalize_decimal(value), unit: unit || "percent"}}

  # If the item's embedded primary language differs from the global primary,
  # start on the item's language tab and flag that the global primary needs filling in.
  #
  # Always assigns `needs_primary_translation` and `item_primary_language`
  # — even when multilang is disabled — so the render path can reference
  # them unconditionally without crashing on a missing key.
  # Loads the parent catalogue once so the form can surface markup,
  # discount, kind, and (for smart catalogues) the candidate reference
  # list. Returns nil if the item isn't scoped to a catalogue yet, in
  # which case every derived field is nil and the render path omits
  # kind-specific sections.
  defp load_parent_catalogue(nil), do: nil
  defp load_parent_catalogue(catalogue_uuid), do: Catalogue.get_catalogue(catalogue_uuid)

  defp catalogue_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp catalogue_kind(_), do: "standard"

  defp markup_from_catalogue(%{markup_percentage: markup}), do: markup
  defp markup_from_catalogue(_), do: nil

  defp discount_from_catalogue(%{discount_percentage: discount}), do: discount
  defp discount_from_catalogue(_), do: nil

  defp adjust_multilang_for_item(socket, item) do
    if socket.assigns.multilang_enabled do
      check_item_primary_language(socket, item)
    else
      assign(socket, needs_primary_translation: false, item_primary_language: nil)
    end
  end

  defp check_item_primary_language(socket, item) do
    item_data = item.data || %{}
    item_primary = item_data["_primary_language"]
    global_primary = socket.assigns.primary_language

    if item_primary && item_primary != global_primary do
      global_data = Multilang.get_language_data(item_data, global_primary)
      global_has_data = global_data["_name"] != nil and global_data["_name"] != ""

      assign(socket,
        current_lang: item_primary,
        needs_primary_translation: not global_has_data,
        item_primary_language: item_primary
      )
    else
      assign(socket,
        needs_primary_translation: false,
        item_primary_language: nil
      )
    end
  end

  # "switch_language" is handled by the core `mount_multilang/1` auto hook
  # (default `auto_switch_language: true`) — no clause needed here.

  # AI-translate modal events handled by `use ...AITranslate.Embed`.

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :current_tab, parse_tab(tab))}
  end

  def handle_event("add_meta_field", %{"key" => key}, socket) do
    case Metadata.definition(:item, key) do
      nil ->
        # Unknown key arriving from a stale client — ignore rather than
        # inserting data the save path can't round-trip.
        {:noreply, socket}

      _def ->
        state = socket.assigns.meta_state

        new_state =
          if key in state.attached do
            state
          else
            %{
              attached: state.attached ++ [key],
              values: Map.put_new(state.values, key, "")
            }
          end

        {:noreply, assign(socket, :meta_state, new_state)}
    end
  end

  def handle_event("remove_meta_field", %{"key" => key}, socket) do
    state = socket.assigns.meta_state

    new_state = %{
      attached: Enum.reject(state.attached, &(&1 == key)),
      values: Map.delete(state.values, key)
    }

    {:noreply, assign(socket, :meta_state, new_state)}
  end

  # ── Attachments (featured image modal + inline files dropzone) ──
  # Delegated to `PhoenixKitCatalogue.Attachments`; shared with
  # `CatalogueFormLive` so both forms behave identically.

  def handle_event("open_featured_image_picker", _params, socket),
    do: Attachments.open_featured_image_picker(socket)

  def handle_event("close_media_selector", _params, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: Attachments.cancel_attachment_upload(socket, ref)

  def handle_event("remove_file", %{"uuid" => uuid}, socket),
    do: Attachments.trash_file(socket, uuid)

  def handle_event("clear_featured_image", _params, socket),
    do: Attachments.clear_featured_image(socket)

  def handle_event("open_pdf_search", _params, socket),
    do: {:noreply, assign(socket, :show_pdf_search, true)}

  def handle_event("validate", params, socket) do
    socket =
      socket
      |> absorb_meta_params(params)
      |> absorb_attribute_selection(params)

    item_params = Map.get(params, "item", %{})

    item_params =
      merge_translatable_params(item_params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.item
      |> Catalogue.change_item(item_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("save", params, socket) do
    socket =
      socket
      |> absorb_meta_params(params)
      |> absorb_attribute_selection(params)

    item_params = Map.get(params, "item", %{})

    item_params =
      item_params
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )
      |> Metadata.inject_into_data(socket.assigns.meta_state, :item)
      |> Attachments.inject_attachment_data(socket)

    save_item(socket, socket.assigns.action, item_params, save_mode(params))
  end

  # ── Smart-catalogue rule picker events ──────────────────────────
  # All four events mutate `socket.assigns.working_rules`; actual
  # persistence happens during save via `put_catalogue_rules/3`.

  def handle_event("toggle_catalogue_rule", %{"uuid" => uuid}, socket) do
    rules = socket.assigns.working_rules

    working_rules =
      if Map.has_key?(rules, uuid) do
        Map.delete(rules, uuid)
      else
        # Unit is always explicit per rule — it does not inherit from the
        # item's default_unit. Value is left nil so it can still inherit
        # via the "Inherit: N" placeholder flow.
        Map.put(rules, uuid, %{value: nil, unit: "percent"})
      end

    {:noreply, assign(socket, :working_rules, working_rules)}
  end

  def handle_event("set_catalogue_rule_value", %{"uuid" => uuid, "value" => raw}, socket) do
    rules = socket.assigns.working_rules

    case Map.get(rules, uuid) do
      nil ->
        {:noreply, socket}

      entry ->
        new_value = parse_decimal_or_nil(raw)
        working_rules = Map.put(rules, uuid, %{entry | value: new_value})
        {:noreply, assign(socket, :working_rules, working_rules)}
    end
  end

  def handle_event("set_catalogue_rule_unit", %{"uuid" => uuid, "unit" => unit}, socket) do
    rules = socket.assigns.working_rules

    case Map.get(rules, uuid) do
      nil ->
        {:noreply, socket}

      entry ->
        new_unit = if unit in ["", nil], do: nil, else: unit
        working_rules = Map.put(rules, uuid, %{entry | unit: new_unit})
        {:noreply, assign(socket, :working_rules, working_rules)}
    end
  end

  def handle_event("clear_catalogue_rules", _params, socket) do
    {:noreply, assign(socket, :working_rules, %{})}
  end

  def handle_event("reorder_catalogue_rules", %{"ordered_ids" => ordered_ids}, socket)
      when is_list(ordered_ids) do
    # Build the new candidate order: incoming UUIDs first (deduped),
    # then any candidates the DOM didn't surface (defensive — keeps
    # rows from disappearing if the client only sent a partial list).
    # Use the shared `dedupe_keep_last/1` so a stale-DOM duplicate
    # surfaces the *latest* drop position, matching the catalogue /
    # category / item reorder paths.
    current = socket.assigns.rule_candidate_order
    incoming = Helpers.dedupe_keep_last(ordered_ids)
    rest = Enum.reject(current, &(&1 in incoming))
    {:noreply, assign(socket, :rule_candidate_order, incoming ++ rest)}
  end

  def handle_event("select_move_target", params, socket) do
    # Accept the UUID under either key depending on which select fired —
    # standard forms use `category_uuid`, smart forms use `catalogue_uuid`.
    uuid = params["category_uuid"] || params["catalogue_uuid"]
    target = if uuid in [nil, ""], do: nil, else: uuid
    {:noreply, assign(socket, :move_target, target)}
  end

  def handle_event("move_item", _params, socket) do
    target = socket.assigns.move_target

    if target do
      perform_move(socket, target)
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_add_supplier", _params, socket) do
    {:noreply, assign(socket, supplier_form_open: true, supplier_info_draft: %{})}
  end

  def handle_event("cancel_add_supplier", _params, socket) do
    {:noreply, assign(socket, supplier_form_open: false, supplier_info_draft: %{})}
  end

  def handle_event("supplier_info_field_change", params, socket) do
    draft = socket.assigns.supplier_info_draft
    si_params = Map.get(params, "supplier_info", %{})
    {:noreply, assign(socket, supplier_info_draft: Map.merge(draft, si_params))}
  end

  def handle_event("save_supplier_info", _params, socket) do
    item = socket.assigns.item
    draft = socket.assigns.supplier_info_draft
    all_suppliers = socket.assigns.all_suppliers

    supplier_uuid = Map.get(draft, "supplier_uuid", "")

    if supplier_uuid == "" do
      {:noreply,
       put_flash(
         socket,
         :error,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Please select a supplier.")
       )}
    else
      selected = Enum.find(all_suppliers, &(&1.uuid == supplier_uuid))
      snapshot = selected && selected.name
      # The dropdown mixes local and CRM suppliers; persist the source of the
      # chosen entry — a CRM party stored as "local" would misroute the
      # resolver and the audit task.
      source = if selected, do: Atom.to_string(selected.source), else: "local"

      attrs = %{
        "item_uuid" => item.uuid,
        "supplier_uuid" => supplier_uuid,
        "supplier_source" => source,
        "supplier_name_snapshot" => snapshot,
        "supplier_sku" => Map.get(draft, "supplier_sku"),
        "unit_cost" => Map.get(draft, "unit_cost"),
        "currency" => Map.get(draft, "currency"),
        "lead_time_days" => Map.get(draft, "lead_time_days"),
        "min_order_qty" => Map.get(draft, "min_order_qty")
      }

      case ItemSupplierInfos.create(attrs, actor_opts(socket)) do
        {:ok, _info} ->
          {:noreply,
           socket
           |> assign(
             supplier_infos: ItemSupplierInfos.list_for_item(item.uuid),
             supplier_form_open: false,
             supplier_info_draft: %{}
           )
           |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier added."))}

        {:error, _changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to add supplier.")
           )}
      end
    end
  end

  def handle_event("set_primary_supplier", %{"uuid" => uuid}, socket) do
    item = socket.assigns.item

    case ItemSupplierInfos.get(uuid) do
      nil ->
        {:noreply, socket}

      info ->
        case ItemSupplierInfos.set_primary(info, actor_opts(socket)) do
          {:ok, _} ->
            {:noreply, assign(socket, supplier_infos: ItemSupplierInfos.list_for_item(item.uuid))}

          {:error, _} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to set primary supplier.")
             )}
        end
    end
  end

  def handle_event("open_supplier_history", %{"uuid" => uuid}, socket) do
    case ItemSupplierInfos.get(uuid) do
      nil ->
        {:noreply, socket}

      info ->
        rows = ItemSupplierInfos.history_for_pair(info.item_uuid, info.supplier_uuid)
        name = supplier_display_name(info, socket.assigns.all_suppliers)

        {:noreply,
         assign(socket,
           supplier_history_open: true,
           supplier_history_rows: rows,
           supplier_history_name: name
         )}
    end
  end

  def handle_event("close_supplier_history", _params, socket) do
    {:noreply,
     assign(socket,
       supplier_history_open: false,
       supplier_history_rows: [],
       supplier_history_name: nil
     )}
  end

  def handle_event("delete_supplier_info", %{"uuid" => uuid}, socket) do
    item = socket.assigns.item

    case ItemSupplierInfos.get(uuid) do
      nil ->
        {:noreply, socket}

      info ->
        case ItemSupplierInfos.delete(info, actor_opts(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(supplier_infos: ItemSupplierInfos.list_for_item(item.uuid))
             |> put_flash(
               :info,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier removed.")
             )}

          {:error, _} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to remove supplier.")
             )}
        end
    end
  end

  # ── Attribute sets (staged; applied on save) ─────────────────────────
  #
  # The picker select sits INSIDE the main form (nested forms are
  # invalid), so it carries its own phx-change — which takes precedence
  # over the form's "validate" for this input — and its name is ignored
  # by the save params.

  def handle_event("attach_set", %{"attach_set_uuid" => set_uuid}, socket) do
    staged = socket.assigns.staged_set_uuids

    valid? =
      is_binary(set_uuid) and set_uuid != "" and
        set_uuid not in staged and
        Enum.any?(socket.assigns.available_sets, &(&1.uuid == set_uuid))

    if valid? do
      {:noreply,
       socket
       |> assign(:staged_set_uuids, staged ++ [set_uuid])
       |> assign_set_previews()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("detach_set", %{"uuid" => set_uuid}, socket) do
    {:noreply,
     socket
     |> assign(:staged_set_uuids, List.delete(socket.assigns.staged_set_uuids, set_uuid))
     |> assign(:staged_selections, Map.delete(socket.assigns.staged_selections, set_uuid))
     |> assign_set_previews()}
  end

  def handle_event("reorder_staged_sets", %{"ordered_ids" => ids}, socket) when is_list(ids) do
    staged = socket.assigns.staged_set_uuids
    # Only reorder what is actually staged — the client list is forgeable.
    reordered = Enum.filter(ids, &(&1 in staged))

    if Enum.sort(reordered) == Enum.sort(staged) do
      {:noreply, assign(socket, :staged_set_uuids, reordered)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reorder_staged_sets", _params, socket), do: {:noreply, socket}

  # The boss's two modes (2026-08-19): checking values narrows what the
  # set says about THIS item — one check is "this exact object", several
  # are "the options it comes in", none is "the whole set applies". The
  # count IS the mode; nothing else is tracked.
  # phx-value-key, NOT phx-value-value: a click payload on an input
  # includes the element's own value attribute under "value" (a bare
  # checkbox submits "on"), which would clobber the param.
  def handle_event("toggle_value_selection", %{"set" => set_uuid, "key" => key}, socket) do
    with true <- set_uuid in socket.assigns.staged_set_uuids,
         %{values: values} <- socket.assigns.set_previews[set_uuid],
         true <- Enum.any?(values, &(&1.key == key)) do
      selections = socket.assigns.staged_selections
      current = Map.get(selections, set_uuid, MapSet.new())

      current =
        if MapSet.member?(current, key),
          do: MapSet.delete(current, key),
          else: MapSet.put(current, key)

      {:noreply, assign(socket, :staged_selections, Map.put(selections, set_uuid, current))}
    else
      _ -> {:noreply, socket}
    end
  end

  defp parse_tab("metadata"), do: :metadata
  defp parse_tab("files"), do: :files
  defp parse_tab(_), do: :details

  defp absorb_meta_params(socket, params) do
    assign(socket, :meta_state, Metadata.absorb_params(socket.assigns.meta_state, params))
  end

  defp load_supplier_infos(:edit, %Item{uuid: uuid}) when not is_nil(uuid),
    do: ItemSupplierInfos.list_for_item(uuid)

  defp load_supplier_infos(_action, _item), do: []

  defp supplier_display_name(info, all_suppliers) do
    case Enum.find(all_suppliers, &(&1.uuid == info.supplier_uuid)) do
      nil -> info.supplier_name_snapshot || info.supplier_uuid
      s -> s.name
    end
  end

  # ── Attachments handle_info (delegated to Attachments module) ────

  # {:ai_translation, ...} events folded into the form by `use ...AITranslate.Embed`.
  @impl true
  def handle_info({:media_selected, file_uuids}, socket),
    do: Attachments.handle_media_selected(socket, file_uuids)

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  def handle_info({:pdf_search_modal_closed}, socket),
    do: {:noreply, assign(socket, :show_pdf_search, false)}

  # Catch-all so stray monitor signals or unrelated PubSub traffic
  # can't crash the form mid-edit.
  def handle_info(msg, socket) do
    Logger.debug("ItemFormLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Routes on the parent catalogue's kind: smart items move across
  # catalogues (categories don't apply), standard items move between
  # categories (the catalogue is derived from the target category).
  defp perform_move(socket, target) do
    result =
      case socket.assigns.catalogue_kind do
        "smart" ->
          Catalogue.move_item_to_catalogue(socket.assigns.item, target, actor_opts(socket))

        _ ->
          Catalogue.move_item_to_category(socket.assigns.item, target, actor_opts(socket))
      end

    case result do
      {:ok, item} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item moved."))
         |> push_navigate(to: redirect_target(socket, item))}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move item.")
         )}
    end
  end

  # actor_opts/1 imported from PhoenixKitCatalogue.Web.Helpers

  defp save_item(socket, :new, params, mode) do
    params = Map.put_new(params, "catalogue_uuid", socket.assigns.catalogue_uuid)

    with {:ok, item} <- Catalogue.create_item(params, actor_opts(socket)),
         {:ok, _rules} <- maybe_put_rules(socket, item),
         :ok <- Attachments.maybe_rename_pending_folder(socket, item) do
      apply_attribute_assignment(socket, item)

      # "Save" (stay) on a new item lands on its edit form — the record
      # exists now, so staying means continuing to edit it. The original
      # return_to rides along so the eventual exit still goes home.
      target =
        case mode do
          :stay -> Paths.item_edit(item.uuid) <> return_to_suffix(socket)
          :exit -> redirect_target(socket, item)
        end

      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item created."))
       |> push_navigate(to: target)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, changeset)}

      {:error, {:duplicate_referenced_catalogue, _uuid}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Each catalogue can only appear once in the rules list."
           )
         )}
    end
  end

  defp save_item(socket, :edit, params, mode) do
    # If item had a different primary language, rekey data to global primary on save
    params =
      if socket.assigns[:needs_primary_translation] && params["data"] do
        global_primary = socket.assigns.primary_language
        rekeyed = Multilang.rekey_primary(params["data"], global_primary)
        Map.put(params, "data", rekeyed)
      else
        params
      end

    with {:ok, item} <- Catalogue.update_item(socket.assigns.item, params, actor_opts(socket)),
         {:ok, _rules} <- maybe_put_rules(socket, item) do
      apply_attribute_assignment(socket, item)

      socket =
        put_flash(socket, :info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item updated."))

      case mode do
        :stay -> {:noreply, refresh_after_edit(socket, item)}
        :exit -> {:noreply, push_navigate(socket, to: redirect_target(socket, item))}
      end
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, changeset)}

      {:error, {:duplicate_referenced_catalogue, _uuid}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Each catalogue can only appear once in the rules list."
           )
         )}
    end
  end

  # Only persist rules when the parent catalogue is smart. On standard
  # catalogues the picker is never rendered, `working_rules` stays `%{}`,
  # and we skip the context call entirely.
  defp maybe_put_rules(socket, item) do
    case socket.assigns.catalogue_kind do
      "smart" ->
        rules =
          working_rules_to_specs(
            socket.assigns.working_rules,
            socket.assigns.rule_candidate_order
          )

        Catalogue.put_catalogue_rules(item, rules, actor_opts(socket))

      _ ->
        {:ok, :skipped}
    end
  end

  # Walks the user-defined display order and emits one spec per active
  # rule, with `position` reflecting the visible row index. UUIDs in
  # `working_rules` that aren't in the order list (defensive — should
  # never happen) get appended at the end so we never silently drop a
  # rule the user toggled on.
  defp working_rules_to_specs(working_rules, candidate_order) do
    ordered =
      candidate_order
      |> Enum.filter(&Map.has_key?(working_rules, &1))

    leftovers =
      working_rules
      |> Map.keys()
      |> Enum.reject(&(&1 in ordered))

    (ordered ++ leftovers)
    |> Enum.with_index()
    |> Enum.map(fn {uuid, idx} ->
      %{value: v, unit: u} = Map.fetch!(working_rules, uuid)
      %{referenced_catalogue_uuid: uuid, value: v, unit: u, position: idx}
    end)
  end

  # Accepts the blur-event string, returns a Decimal or nil (for blank /
  # unparseable). Lets the user clear the field to revert to "inherit
  # from item default".
  defp parse_decimal_or_nil(""), do: nil
  defp parse_decimal_or_nil(nil), do: nil

  defp parse_decimal_or_nil(s) when is_binary(s) do
    case Decimal.parse(s) do
      {decimal, ""} -> decimal
      {decimal, _rest} -> decimal
      :error -> nil
    end
  end

  # The clicked submit button ships its name/value with the form params.
  # Anything other than the explicit "stay" (absent, forged, or stale)
  # falls back to the exit behavior — same as before the split.
  defp save_mode(%{"save_action" => "stay"}), do: :stay
  defp save_mode(_params), do: :exit

  # ── Attribute group selection ───────────────────────────────────

  # {label, value} pairs for the kit <.select> (L029 conversion): the
  # dynamic suffixes ("(CRM)" for external suppliers, "(archived)" for
  # groups kept readable on items that hold them) move out of option
  # markup into the label strings.
  defp supplier_options(suppliers) do
    Enum.map(suppliers, fn s ->
      label = if s.source != :local, do: "#{s.name} (CRM)", else: s.name
      {label, s.uuid}
    end)
  end

  defp attribute_group_options_for_select(groups) do
    Enum.map(groups, fn group ->
      label =
        if group.status == "archived" do
          "#{group.name} (#{Gettext.gettext(PhoenixKitCatalogue.Gettext, "archived")})"
        else
          group.name
        end

      {label, group.uuid}
    end)
  end

  # The Attributes tab's group select submits with the main form (name
  # "attribute_group_uuid", outside the item[...] namespace). Track the
  # selection in assigns so the read-only preview follows it live.
  defp absorb_attribute_selection(socket, params) do
    case Map.fetch(params, "attribute_group_uuid") do
      {:ok, raw} ->
        selected = if raw in [nil, ""], do: nil, else: raw

        if selected != socket.assigns.selected_attribute_group_uuid do
          socket
          |> assign(:selected_attribute_group_uuid, selected)
          |> assign_attribute_preview(selected)
        else
          socket
        end

      :error ->
        socket
    end
  end

  defp assign_attribute_state(socket, item, action) do
    socket = assign_attribute_sets_state(socket, item, action)

    if socket.assigns.sets_enabled do
      # Sets ARE the attribute system — the legacy group surface
      # doesn't load or render at all ("we shouldn't have legacy",
      # boss direction 2026-08-18). The stored assignment rows sit
      # untouched until the cutover drop migration.
      socket
      |> assign(:selected_attribute_group_uuid, nil)
      |> assign(:attribute_group_options, [])
      |> assign(:attribute_preview, nil)
    else
      assign_legacy_attribute_state(socket, item, action)
    end
  end

  defp assign_legacy_attribute_state(socket, item, action) do
    selected =
      if action == :edit and item.uuid,
        do: Catalogue.get_item_attribute_group_uuid(item.uuid),
        else: nil

    groups = Catalogue.list_attribute_groups(status: "active")

    # The stale-select rule: an archived group the item already holds
    # stays in the options (and keeps rendering) — it just can't be
    # newly chosen once deselected.
    groups =
      if selected && not Enum.any?(groups, &(&1.uuid == selected)) do
        case Catalogue.get_attribute_group(selected) do
          nil -> groups
          archived -> groups ++ [archived]
        end
      else
        groups
      end

    socket
    |> assign(:selected_attribute_group_uuid, selected)
    |> assign(:attribute_group_options, Catalogue.localize(groups, preview_lang(socket)))
    |> assign_attribute_preview(selected)
  end

  # SETS (2026-08-18 rework): the staged multi-set selection. Same
  # applied-on-save semantics as the legacy group select — attach/detach
  # /reorder live in assigns until the item saves, so Cancel abandons
  # everything and :new items work identically.
  defp assign_attribute_sets_state(socket, item, action) do
    if Catalogue.attribute_sets_enabled?() do
      attachments =
        if action == :edit and item.uuid,
          do: Catalogue.list_attribute_set_attachments(item.uuid),
          else: []

      socket =
        socket
        |> assign(:sets_enabled, true)
        |> assign(:available_sets, Catalogue.list_attribute_sets(lang: preview_lang(socket)))
        |> assign(:staged_set_uuids, Enum.map(attachments, & &1.set_uuid))
        |> assign_set_previews()

      # Per-set value selection (boss's two modes, 2026-08-19): the
      # checked value KEYS per set, staged like everything else on this
      # tab. Hydrated AFTER previews so stored slugs intersect with the
      # set's CURRENT values — a value deleted after being ticked must
      # not ghost the mode hint into a state the user can't untick
      # (panel finding).
      selections =
        Map.new(attachments, fn a ->
          {a.set_uuid, stored_selection(a, socket.assigns.set_previews[a.set_uuid])}
        end)

      socket
      |> assign(:staged_selections, selections)
    else
      socket
      |> assign(:sets_enabled, false)
      |> assign(:available_sets, [])
      |> assign(:staged_set_uuids, [])
      |> assign(:staged_selections, %{})
      |> assign(:set_previews, %{})
    end
  end

  defp assign_set_previews(socket) do
    previews =
      Map.new(socket.assigns.staged_set_uuids, fn uuid ->
        {uuid, Catalogue.resolve_attribute_set(uuid, lang: preview_lang(socket))}
      end)

    assign(socket, :set_previews, previews)
  end

  defp stored_selection(attachment, preview) do
    valid =
      case preview do
        %{values: values} -> MapSet.new(values, & &1.key)
        _ -> MapSet.new()
      end

    case attachment.data["selected_value_slugs"] do
      list when is_list(list) ->
        list |> Enum.filter(&(is_binary(&1) and &1 in valid)) |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp selection_for(assigns, set_uuid) do
    Map.get(assigns.staged_selections, set_uuid, MapSet.new())
  end

  # First image-type extra with a value — the chip's swatch thumbnail.
  defp value_thumb(preview, value) do
    preview[:fields]
    |> List.wrap()
    |> Enum.filter(&(&1.type == "image"))
    |> Enum.find_value(fn field ->
      case value.extras[field.key] do
        uuid when is_binary(uuid) and uuid != "" -> uuid
        _ -> nil
      end
    end)
  end

  # Non-media extras as a tooltip ("Price per liter: 12.5 · Finish:
  # Gloss") — nil when the value carries none, so no empty title attr.
  defp value_extras_summary(preview, value) do
    summary =
      preview[:fields]
      |> List.wrap()
      |> Enum.reject(&(&1.type in ["image", "video"]))
      |> Enum.map(fn field ->
        case value.extras[field.key] do
          nil -> nil
          "" -> nil
          v -> "#{field.label}: #{v}"
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    if summary == "", do: nil, else: summary
  end

  defp staged_set_name(assigns, uuid) do
    case Enum.find(assigns.available_sets, &(&1.uuid == uuid)) do
      %{display_name: name} -> name
      _ -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unknown set")
    end
  end

  defp attachable_set_options(assigns) do
    assigns.available_sets
    |> Enum.reject(&(&1.uuid in assigns.staged_set_uuids))
    |> Enum.map(&{&1.display_name, &1.uuid})
  end

  # The Attributes tab badge: staged sets once the rework is live,
  # falling back to the legacy group's attribute count.
  defp attribute_tab_count(assigns) do
    cond do
      assigns.sets_enabled and assigns.staged_set_uuids != [] ->
        length(assigns.staged_set_uuids)

      match?(%{}, assigns.attribute_preview) ->
        length(assigns.attribute_preview.attributes)

      true ->
        nil
    end
  end

  defp assign_attribute_preview(socket, selected) do
    assign(socket, :attribute_preview, Catalogue.resolved_group(selected, preview_lang(socket)))
  end

  defp preview_lang(socket) do
    socket.assigns[:current_locale] || socket.assigns[:primary_language] || "en"
  end

  # Persisting the assignment is best-effort alongside the item save:
  # the select only offers valid groups, so a rejected value can only be
  # a forged payload — skip it rather than fail the save.
  defp apply_attribute_assignment(socket, item) do
    # With sets live the legacy select never renders, so the loaded-nil
    # selection must NOT be written back — it would clear the item's
    # stored legacy assignment, which stays frozen until cutover.
    unless socket.assigns[:sets_enabled] do
      case Catalogue.set_item_attribute_group(
             item,
             socket.assigns.selected_attribute_group_uuid,
             actor_opts(socket)
           ) do
        {:error, reason} ->
          Logger.warning("ItemFormLive attribute assignment skipped: #{inspect(reason)}")
          :ok

        _ ->
          :ok
      end
    end

    apply_attribute_sets(socket, item)
  end

  # Diffs the staged set selection against the stored attachments —
  # same best-effort doctrine as the group assignment above: the picker
  # only offers real sets, so a failure here (set deleted mid-edit) is
  # logged and skipped, never fails the item save.
  defp apply_attribute_sets(socket, item) do
    if socket.assigns[:sets_enabled] do
      staged = socket.assigns.staged_set_uuids
      current = Enum.map(Catalogue.list_attribute_set_attachments(item.uuid), & &1.set_uuid)

      Enum.each(current -- staged, fn uuid ->
        Catalogue.detach_attribute_set(item.uuid, uuid, actor_opts(socket))
      end)

      Enum.each(staged -- current, &attach_staged_set(socket, item.uuid, &1))

      Catalogue.reorder_attribute_sets(item.uuid, staged, actor_opts(socket))

      # Selections write AFTER attach so new attachments exist; the
      # context validates keys against the set's current values.
      Enum.each(staged, fn set_uuid ->
        slugs =
          socket.assigns.staged_selections
          |> Map.get(set_uuid, MapSet.new())
          |> MapSet.to_list()

        Catalogue.set_attribute_set_selection(item.uuid, set_uuid, slugs, actor_opts(socket))
      end)
    end

    :ok
  end

  defp attach_staged_set(socket, item_uuid, set_uuid) do
    case Catalogue.attach_attribute_set(item_uuid, set_uuid, actor_opts(socket)) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("ItemFormLive set attach skipped: #{inspect(reason)}")
    end
  end

  defp return_to_suffix(socket) do
    case socket.assigns[:return_to] do
      nil -> ""
      rt -> "?" <> URI.encode_query([{"return_to", rt}])
    end
  end

  # In-place refresh after a stay-save: no remount, so the current tab,
  # language, scroll position, and live attachment state all survive.
  # meta_state and working_rules were just persisted verbatim, so they
  # stay as-is; only the item-derived assigns need re-deriving. A
  # successful save keys data to the global primary, so the imported-
  # language warning clears.
  defp refresh_after_edit(socket, item) do
    item =
      item
      |> PhoenixKit.RepoHelper.repo().preload([:category, :manufacturer])
      |> normalize_display_decimals()

    socket
    |> assign(:item, item)
    |> assign(
      :page_title,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: item.name)
    )
    |> assign(:needs_primary_translation, false)
    |> assign_changeset(Catalogue.change_item(item))
  end

  defp redirect_target(socket, item) do
    cond do
      socket.assigns[:return_to] ->
        socket.assigns.return_to

      item.catalogue_uuid ->
        Paths.catalogue_detail(item.catalogue_uuid)

      socket.assigns.catalogue_uuid ->
        Paths.catalogue_detail(socket.assigns.catalogue_uuid)

      true ->
        Paths.index()
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :lang_data,
        get_lang_data(assigns.changeset, assigns.current_lang, assigns.multilang_enabled)
      )

    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_section={@parent_catalogue_name}
      page_section_path={@catalogue_uuid && Paths.catalogue_detail(@catalogue_uuid)}
      page_subtitle={
        if @action == :new,
          do:
            Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "Add a new product or material to the catalogue."
            ),
          else:
            Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "Update item details, pricing, and classification."
            )
      }
      current_path={assigns[:url_path] || (if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index())}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col mx-auto max-w-2xl px-4 py-8 gap-6">

      <%!-- PDF search button — visible on edit only. Opens a modal that
           searches the PDF library for any page mentioning the item's
           translated names. --%>
      <div :if={@action == :edit} class="flex items-center justify-between bg-base-200 rounded-lg p-3 gap-3">
        <div class="text-sm">
          <div class="font-medium">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Find this item in PDFs")}
          </div>
          <div class="text-xs text-base-content/60">
            {Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "Searches the entire PDF library for the item's name across all enabled languages."
            )}
          </div>
        </div>
        <.button type="button" phx-click="open_pdf_search" size="sm">
          <.icon name="hero-magnifying-glass" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search PDFs")}
        </.button>
      </div>

      <.live_component
        :if={@action == :edit}
        module={PhoenixKitCatalogue.Web.Components.PdfSearchModal}
        id="pdf-search-modal"
        item={@item}
        show={@show_pdf_search}
      />

      <%!-- Primary language warning --%>
      <div :if={@needs_primary_translation} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
        <div>
          <p class="text-sm font-medium">
            {Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "This item was imported in %{lang}. Please fill in the %{primary} translation and save to set it as the primary language.",
              lang: lang_name(@language_tabs, @item_primary_language),
              primary: lang_name(@language_tabs, @primary_language)
            )}
          </p>
        </div>
      </div>

      <%!-- Tab strip — persists across tab switches; each panel stays in
           the DOM (toggled by `hidden`) so the multilang wrapper and
           any user input don't lose state when flipping tabs. --%>
      <div role="tablist" class="tabs tabs-border">
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="details"
          class={"tab #{if @current_tab == :details, do: "tab-active"}"}
        >
          <.icon name="hero-document-text" class="w-4 h-4 mr-1" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Details")}
        </button>
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="metadata"
          class={"tab #{if @current_tab == :metadata, do: "tab-active"}"}
        >
          <.icon name="hero-swatch" class="w-4 h-4 mr-1" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")}
          <span :if={attribute_tab_count(assigns)} class="badge badge-sm badge-ghost ml-2">
            {attribute_tab_count(assigns)}
          </span>
        </button>
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="files"
          class={"tab #{if @current_tab == :files, do: "tab-active"}"}
        >
          <.icon name="hero-paper-clip" class="w-4 h-4 mr-1" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Photos and Files")}
        </button>
      </div>

      <%!-- Media selector — single instance, reconfigured per click
           via @media_selector_target. Scoped to this item's folder
           so browse and new uploads never spill into other items. --%>
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="item-form-media-selector"
        show={@show_media_selector}
        mode={@media_selection_mode}
        file_type_filter={@media_filter}
        lock_file_type
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select Featured Image")}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={@files_folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
        <div class={"card bg-base-100 shadow-lg #{if @current_tab != :details, do: "hidden"}"}>
          <%!-- Bundled tabs + AI row (phoenix_kit_ai's canonical placement). --%>
          <.ai_multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            ai_translate={ai_translate_config(assigns)}
          />

          <%!-- Only translatable fields live inside the wrapper. When the
               user switches languages, the wrapper's ID changes and
               morphdom remounts its children — so we keep the scope as
               small as possible (name + description), not the whole
               form. Everything else renders as a sibling below. --%>
          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="card-body flex flex-col gap-5 pb-0"
          >
            <:skeleton>
              <%!-- Name --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-20"></div>
                <div class="skeleton h-12 w-full"></div>
              </div>
              <%!-- Description --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-28"></div>
                <div class="skeleton h-24 w-full"></div>
              </div>
            </:skeleton>
            <div class="card-body flex flex-col gap-5 pb-0">
              <.translatable_field
                field_name="name"
                form_prefix="item"
                changeset={@changeset}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Oak Panel 18mm")}
                required
                class="w-full"
              />

              <.translatable_field
                field_name="description"
                form_prefix="item"
                changeset={@changeset}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
                type="textarea"
                placeholder={
                  Gettext.gettext(
                    PhoenixKitCatalogue.Gettext,
                    "Product specifications, dimensions, materials..."
                  )
                }
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <%!-- Pricing & identification — hidden for smart catalogues,
                   whose items are priced entirely by the rules picker below. --%>
            <div :if={@catalogue_kind != "smart"} class="flex flex-col gap-5">
              <div class="divider my-0"></div>

              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-4 w-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z"
                  />
                </svg>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pricing & Identification")}
              </h2>

              <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <.input
                  field={@form[:sku]}
                  type="text"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")}
                  class="font-mono"
                  placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., KF-001")}
                />
                <div class="fieldset">
                  <.input
                    field={@form[:base_price]}
                    type="number"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Base Price")}
                    step="0.01"
                    min="0"
                    placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "0.00")}
                  />
                  <span class="fieldset-label text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Cost/purchase price before catalogue markup."
                    )}
                  </span>
                </div>
                <.select
                  field={@form[:unit]}
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit")}
                  class="transition-colors focus-within:select-primary"
                  options={[
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Piece"), "piece"},
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "m² (square meter)"), "m2"},
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Running meter"), "running_meter"}
                  ]}
                />
                <div class="fieldset">
                  <.input
                    field={@form[:markup_percentage]}
                    type="number"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Markup Override (%)")}
                    step="0.01"
                    min="0"
                    placeholder={
                      if @catalogue_markup,
                        do:
                          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inherit: %{markup}%",
                            markup: Decimal.to_string(@catalogue_markup, :normal)
                          ),
                        else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inherit catalogue markup")
                    }
                  />
                  <span class="fieldset-label text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Leave blank to inherit the catalogue's markup. Set (including 0) to override just this item."
                    )}
                  </span>
                </div>
                <div class="fieldset">
                  <.input
                    field={@form[:discount_percentage]}
                    type="number"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discount Override (%)")}
                    step="0.01"
                    min="0"
                    max="100"
                    placeholder={
                      if @catalogue_discount,
                        do:
                          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inherit: %{discount}%",
                            discount: Decimal.to_string(@catalogue_discount, :normal)
                          ),
                        else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inherit catalogue discount")
                    }
                  />
                  <span class="fieldset-label text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Leave blank to inherit the catalogue's discount. Set (including 0) to override just this item."
                    )}
                  </span>
                </div>
              </div>
            </div>

            <%!-- Smart-catalogue rules (only for kind: "smart") --%>
            <div :if={@catalogue_kind == "smart"} class="flex flex-col gap-4">
              <div class="divider my-0"></div>
              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <.icon name="hero-link" class="w-4 h-4" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue Rules")}
              </h2>
              <p class="text-sm text-base-content/60 -mt-2">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Pick which catalogues this item applies to and set a value + unit per catalogue. Rows left blank inherit the defaults below."
                )}
              </p>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="fieldset">
                  <.input
                    field={@form[:default_value]}
                    type="number"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Default Value")}
                    step="0.0001"
                    min="0"
                    placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., 5")}
                  />
                  <span class="fieldset-label text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Used for any selected catalogue that doesn't have its own value. If no catalogues are selected, this is the item's standalone fee (e.g. $50 flat)."
                    )}
                  </span>
                </div>
                <div class="fieldset">
                  <.select
                    field={@form[:default_unit]}
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Default Unit")}
                    class="transition-colors focus-within:select-primary"
                    options={[
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Percent (%)"), "percent"},
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Flat amount"), "flat"}
                    ]}
                  />
                  <span class="fieldset-label text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Used for any selected catalogue that doesn't have its own unit."
                    )}
                  </span>
                </div>
              </div>

              <.catalogue_rules_picker
                catalogues={sort_candidates(@rule_candidates, @rule_candidate_order)}
                rules={@working_rules}
                item_default_value={Ecto.Changeset.get_field(@changeset, :default_value)}
                on_reorder={if length(@rule_candidates) > 1, do: "reorder_catalogue_rules"}
              />
            </div>

            <%!-- Classification — available for both standard and smart
                   items. Smart items use category/manufacturer purely for
                   organization; the rule-based pricing is unaffected. --%>
            <div class="flex flex-col gap-5">
              <div class="divider my-0"></div>

              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-4 w-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"
                  />
                </svg>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Classification")}
              </h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <.select
                  field={@form[:category_uuid]}
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category")}
                  class="transition-colors focus-within:select-primary"
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- No category --")}
                  options={Enum.map(@categories, &{&1.name, &1.uuid})}
                />
                <.select
                  field={@form[:manufacturer_uuid]}
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer")}
                  class="transition-colors focus-within:select-primary"
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- No manufacturer --")}
                  options={Enum.map(@manufacturers, &{&1.name, &1.uuid})}
                />
              </div>
            </div>

            <%!-- Suppliers card — junction-based supplier-info table.
                 Only rendered for existing items (new items need a UUID first). --%>
            <div :if={@action == :edit} class="flex flex-col gap-4">
              <div class="divider my-0"></div>
              <div class="flex items-center justify-between gap-2">
                <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                  <.icon name="hero-building-storefront" class="w-4 h-4" />
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Suppliers")}
                </h2>
                <.button type="button" phx-click="open_add_supplier" size="sm">
                  <.icon name="hero-plus" class="w-4 h-4" />
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add Supplier")}
                </.button>
              </div>

              <%!-- Add/edit supplier-info inline form --%>
              <div :if={@supplier_form_open} class="card bg-base-200 p-4">
                <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                  <div class="fieldset md:col-span-2">
                    <.select
                      name="supplier_info[supplier_uuid]"
                      value={@supplier_info_draft["supplier_uuid"]}
                      label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier")}
                      prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select supplier --")}
                      options={supplier_options(@all_suppliers)}
                      phx-change="supplier_info_field_change"
                      class="w-full"
                    />
                  </div>
                  <.input
                    type="text"
                    name="supplier_info[supplier_sku]"
                    value={@supplier_info_draft["supplier_sku"]}
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier SKU")}
                    phx-change="supplier_info_field_change"
                    class="w-full font-mono"
                    placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., ABC-001")}
                  />
                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit Cost")}</span>
                    </label>
                    <%!-- Deliberately raw (L029): the kit input wraps each
                         field in its own feedback div, which would break the
                         daisyUI join grouping of these two inputs. --%>
                    <div class="join">
                      <input
                        type="number"
                        name="supplier_info[unit_cost]"
                        value={@supplier_info_draft["unit_cost"]}
                        phx-change="supplier_info_field_change"
                        step="0.0001"
                        min="0"
                        class="input join-item flex-1"
                        placeholder="0.00"
                      />
                      <input
                        type="text"
                        name="supplier_info[currency]"
                        value={@supplier_info_draft["currency"]}
                        phx-change="supplier_info_field_change"
                        class="input join-item w-16 font-mono uppercase"
                        placeholder="EUR"
                        maxlength="3"
                      />
                    </div>
                  </div>
                  <.input
                    type="number"
                    name="supplier_info[lead_time_days]"
                    value={@supplier_info_draft["lead_time_days"]}
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Lead Time (days)")}
                    phx-change="supplier_info_field_change"
                    min="0"
                    class="w-full"
                  />
                  <.input
                    type="number"
                    name="supplier_info[min_order_qty]"
                    value={@supplier_info_draft["min_order_qty"]}
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Min. Order Qty")}
                    phx-change="supplier_info_field_change"
                    step="0.0001"
                    min="0"
                    class="w-full"
                  />
                </div>
                <div class="flex gap-2 mt-3 justify-end">
                  <.button type="button" phx-click="cancel_add_supplier" variant="ghost" size="sm">
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
                  </.button>
                  <.button type="button" phx-click="save_supplier_info" size="sm">
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save")}
                  </.button>
                </div>
              </div>

              <%!-- Supplier-info rows --%>
              <div :if={@supplier_infos == []} class="text-sm text-base-content/50 italic py-2">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No suppliers linked yet.")}
              </div>

              <div :if={@supplier_infos != []} class="overflow-x-auto">
                <table class="table table-sm w-full">
                  <thead>
                    <tr>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier")}</th>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")}</th>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit Cost")}</th>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Lead (d)")}</th>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "MOQ")}</th>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Primary")}</th>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "History")}</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for info <- @supplier_infos do %>
                      <tr class={if info.is_primary, do: "bg-primary/5", else: ""}>
                        <td class="font-medium">
                          {supplier_display_name(info, @all_suppliers)}
                        </td>
                        <td class="font-mono text-xs">{info.supplier_sku || "—"}</td>
                        <td>
                          <%= if info.unit_cost do %>
                            {Decimal.to_string(info.unit_cost, :normal)} {info.currency || ""}
                          <% else %>
                            —
                          <% end %>
                        </td>
                        <td>{info.lead_time_days || "—"}</td>
                        <td>
                          <%= if info.min_order_qty do %>
                            {Decimal.to_string(info.min_order_qty, :normal)}
                          <% else %>
                            —
                          <% end %>
                        </td>
                        <td>
                          <span :if={info.is_primary} class="badge badge-sm badge-primary">
                            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Primary")}
                          </span>
                          <.button
                            :if={not info.is_primary}
                            type="button"
                            phx-click="set_primary_supplier"
                            phx-value-uuid={info.uuid}
                            variant="ghost"
                            size="xs"
                          >
                            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Make primary")}
                          </.button>
                        </td>
                        <td>
                          <.button
                            type="button"
                            phx-click="open_supplier_history"
                            phx-value-uuid={info.uuid}
                            variant="ghost"
                            size="xs"
                            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price History")}
                          >
                            <.icon name="hero-chevron-down" class="w-3 h-3" />
                          </.button>
                        </td>
                        <td>
                          <.button
                            type="button"
                            phx-click="delete_supplier_info"
                            phx-value-uuid={info.uuid}
                            data-confirm={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove this supplier link?")}
                            variant="ghost"
                            size="xs"
                            class="text-error"
                          >
                            <.icon name="hero-trash" class="w-3 h-3" />
                          </.button>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>

            <%!-- Supplier price-history modal — read-only, compact. Shows closed
                 revision rows for the selected item/supplier pair. --%>
            <dialog :if={@supplier_history_open} open class="modal">
              <div class="modal-box max-w-lg">
                <h3 class="font-bold text-lg mb-4">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price History")}
                  <span :if={@supplier_history_name} class="font-normal text-base-content/60 ml-1">
                    — {@supplier_history_name}
                  </span>
                </h3>
                <div :if={@supplier_history_rows == []} class="text-sm text-base-content/50 italic py-2">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No price history.")}
                </div>
                <div :if={@supplier_history_rows != []} class="overflow-x-auto">
                  <table class="table table-xs w-full">
                    <thead>
                      <tr>
                        <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit Cost")}</th>
                        <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Currency")}</th>
                        <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Valid From")}</th>
                        <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Valid To")}</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for row <- @supplier_history_rows do %>
                        <tr class={if is_nil(row.valid_to), do: "font-medium", else: "text-base-content/60"}>
                          <td class="tabular-nums">
                            <%= if row.unit_cost do %>
                              {Decimal.to_string(row.unit_cost, :normal)}
                            <% else %>
                              —
                            <% end %>
                          </td>
                          <td>{row.currency || "—"}</td>
                          <td>{if row.valid_from, do: Date.to_string(row.valid_from), else: "—"}</td>
                          <td>
                            <%= if is_nil(row.valid_to) do %>
                              <span class="badge badge-xs badge-primary">
                                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Current")}
                              </span>
                            <% else %>
                              {Date.to_string(row.valid_to)}
                            <% end %>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
                <div class="modal-action">
                  <button type="button" phx-click="close_supplier_history" class="btn btn-sm">
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Close")}
                  </button>
                </div>
              </div>
              <div class="modal-backdrop" phx-click="close_supplier_history"></div>
            </dialog>

            <div class="fieldset">
              <.select
                field={@form[:status]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                class="transition-colors focus-within:select-primary"
                options={[
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active"), "active"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive"), "inactive"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discontinued"), "discontinued"}
                ]}
              />
              <span class="fieldset-label text-base-content/50 mt-1">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Discontinued items are kept for reference but hidden from active listings."
                )}
              </span>
            </div>
          </div>
        </div>

        <%!-- Attributes tab — the reusable attribute-group system. The
             select submits with the main form (assignment persists on
             save); the preview follows the selection live via validate.
             The legacy hand-typed metadata survives underneath in a
             collapsed editor, rendered ONLY when this item actually has
             old values — never deleted, so a host's AI (or a human) can
             read them, build groups, and clear them at their own pace. --%>
        <div class={"flex flex-col gap-4 #{if @current_tab != :metadata, do: "hidden"}"}>
          <%!-- Attribute SETS (2026-08-18 rework) — the primary picker
               once entities is enabled. Staged in assigns, applied on
               save; the select carries its own phx-change (nested forms
               are invalid — this whole tab lives inside the main form). --%>
          <div :if={@sets_enabled} class="card bg-base-100 shadow-lg">
            <div class="card-body flex flex-col gap-4">
              <div class="flex items-center justify-between gap-4">
                <div class="flex flex-col gap-0.5 min-w-0">
                  <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                    <.icon name="hero-swatch" class="w-4 h-4" />
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute sets")}
                  </h2>
                  <p class="text-xs text-base-content/50">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Attach any number of sets — Ikea colors, HomeDepot trims. Applied when you save."
                    )}
                  </p>
                </div>
                <.link navigate={Paths.attribute_groups()} class="btn btn-ghost btn-xs shrink-0">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manage sets")}
                </.link>
              </div>

              <div
                :if={@staged_set_uuids != []}
                id="staged-set-rows"
                phx-hook="SortableGrid"
                data-sortable="true"
                data-sortable-event="reorder_staged_sets"
                data-sortable-items=".sortable-item"
                data-sortable-handle=".pk-drag-handle"
                class="flex flex-col gap-2"
              >
                <div
                  :for={uuid <- @staged_set_uuids}
                  class="sortable-item rounded-lg border border-base-content/10 bg-base-content/5 p-3 flex flex-col gap-2"
                  data-id={uuid}
                >
                  <% preview = @set_previews[uuid] %>
                  <div class="flex items-center gap-2">
                    <span class="pk-drag-handle cursor-grab inline-flex items-center text-base-content/40 hover:text-base-content/70">
                      <.icon name="hero-bars-3" class="w-4 h-4" />
                    </span>
                    <span class="font-medium text-sm flex-1 min-w-0 truncate">
                      {(preview && preview.name) || staged_set_name(assigns, uuid)}
                    </span>
                    <span :if={preview} class="badge badge-sm badge-ghost shrink-0">
                      {if preview.kind == :fixed,
                        do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Fixed value"),
                        else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Multiple values")}
                    </span>
                    <span :if={is_nil(preview)} class="badge badge-sm badge-warning shrink-0">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "unavailable")}
                    </span>
                    <button
                      type="button"
                      phx-click="detach_set"
                      phx-value-uuid={uuid}
                      class="btn btn-ghost btn-xs px-1 text-base-content/40 hover:text-error shrink-0"
                      title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Detach set")}
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                  <%!-- Value chips are CHECKBOXES (boss's two modes):
                       tick one — this exact item; tick several — the
                       options it comes in; tick none — the whole set
                       applies. The checkboxes carry no name, so the
                       main form never submits them; selection is
                       staged and applied on save. Swatch thumbnails
                       and an extras tooltip surface the set's data. --%>
                  <div :if={preview} class="flex flex-col gap-1.5 pl-6">
                    <div class="flex flex-wrap items-center gap-1.5">
                      <%!-- The highlight is PURE CSS off :checked (has-[]
                           variant) so ticking feels instant — no server
                           round trip gates the visual. The checkbox's
                           form attribute points at a non-existent id,
                           disassociating it from the surrounding item
                           form: without that, every tick ALSO bubbled a
                           change event into the form's phx-change and
                           ran the full validate cycle (the actual lag).
                           phx-click still stages the selection server-
                           side for save; the patch re-asserts checked,
                           so a rejected toggle snaps back. --%>
                      <label
                        :for={value <- preview.values}
                        class="flex items-center gap-1.5 rounded-full border border-base-content/20 bg-base-100 hover:border-base-content/40 has-[:checked]:border-primary has-[:checked]:bg-primary/10 pl-1.5 pr-2.5 py-0.5 cursor-pointer select-none transition-colors"
                        title={value_extras_summary(preview, value)}
                      >
                        <input
                          type="checkbox"
                          form="__detached-from-item-form__"
                          checked={MapSet.member?(selection_for(assigns, uuid), value.key)}
                          phx-click="toggle_value_selection"
                          phx-value-set={uuid}
                          phx-value-key={value.key}
                          class="checkbox checkbox-xs"
                        />
                        <img
                          :if={value_thumb(preview, value)}
                          src={URLSigner.signed_url(value_thumb(preview, value), "thumbnail")}
                          alt=""
                          class="w-5 h-5 rounded object-cover"
                        />
                        <.icon
                          :if={preview.default == value.key}
                          name="hero-star-solid"
                          class="w-3 h-3 text-warning shrink-0"
                        />
                        <span class="text-sm">{value.label}</span>
                      </label>
                      <span :if={preview.values == []} class="text-xs text-base-content/40">
                        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No values defined yet.")}
                      </span>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- id carries the staged count: after a pick the select
                   re-mounts fresh (a focused select is never patched, so
                   without this it would keep showing the picked option). --%>
              <.select
                :if={attachable_set_options(assigns) != []}
                id={"attach-set-select-#{length(@staged_set_uuids)}"}
                name="attach_set_uuid"
                value={nil}
                phx-change="attach_set"
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attach a set...")}
                options={attachable_set_options(assigns)}
                class="w-full"
              />
              <p
                :if={@available_sets == []}
                class="text-sm text-base-content/50"
              >
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "No sets exist yet — create one under Manage sets."
                )}
              </p>
            </div>
          </div>

          <%!-- Legacy attribute group — only on hosts WITHOUT the
               entities module; with sets live the legacy surface is
               gone entirely (assignments auto-migrated). --%>
          <div :if={!@sets_enabled} class="card bg-base-100 shadow-lg">
            <div class="card-body flex flex-col gap-4">
              <div class="flex items-center justify-between gap-4">
                <div class="flex flex-col gap-0.5 min-w-0">
                  <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                    <.icon name="hero-swatch" class="w-4 h-4" />
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute group")}
                  </h2>
                  <p class="text-xs text-base-content/50">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Pick a group to give this item its options — colors, trims, surfaces. Applied when you save."
                    )}
                  </p>
                </div>
                <.link
                  navigate={Paths.attribute_groups()}
                  class="btn btn-ghost btn-xs shrink-0"
                >
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manage groups")}
                </.link>
              </div>

              <.select
                name="attribute_group_uuid"
                value={@selected_attribute_group_uuid}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "— No attribute group —")}
                options={attribute_group_options_for_select(@attribute_group_options)}
                class="w-full transition-colors focus-within:select-primary"
              />

              <%!-- Read-only preview of what the item inherits. Label in
                   its own fixed column so long value lists wrap under the
                   chips, not under the label; the default is marked with
                   the same star the group editor uses. --%>
              <%!-- Two-column grid: the label column is `auto`, sized by the
                   LONGEST attribute name — no fixed-width void after short
                   names, and every row stays aligned. --%>
              <div
                :if={@attribute_preview}
                class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-3 items-start"
              >
                <%= for attribute <- @attribute_preview.attributes do %>
                  <span class="text-sm font-medium pt-0.5 max-w-48 truncate" title={attribute.name}>{attribute.name}</span>
                  <div class="flex flex-wrap items-center gap-1.5 min-w-0">
                    <span
                      :for={value <- attribute.values}
                      class="badge badge-sm badge-ghost gap-1"
                    >
                      <.icon
                        :if={value.default?}
                        name="hero-star-solid"
                        class="w-3 h-3 text-warning shrink-0"
                      />
                      {value.value}
                    </span>
                    <span
                      :if={attribute.values == []}
                      class="text-xs text-base-content/40"
                    >
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No values defined yet.")}
                    </span>
                  </div>
                <% end %>
                <p
                  :if={@attribute_preview.attributes == []}
                  class="text-sm text-base-content/50 col-span-2"
                >
                  {Gettext.gettext(
                    PhoenixKitCatalogue.Gettext,
                    "This group has no attributes yet."
                  )}
                </p>
              </div>
            </div>
          </div>

          <%!-- Legacy metadata — global field list, values in
               `item.data["meta"]`. Collapsed and only rendered when old
               values exist; the inputs stay inside the main form so
               editing and clearing them still works exactly as before. --%>
          <details :if={@meta_state.attached != []} class="card bg-base-100 shadow-lg">
            <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2 select-none">
              <.icon name="hero-tag" class="w-4 h-4 text-base-content/60" />
              <h3 class="font-semibold text-base">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "View old values (%{count})",
                  count: length(@meta_state.attached)
                )}
              </h3>
              <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
            </summary>
            <.metadata_editor
              resource_type={:item}
              state={@meta_state}
              id_prefix="item"
              description={
                Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Hand-typed metadata from before attribute groups. Kept so nothing is lost — move what matters into a group, then clear these."
                )
              }
            />
          </details>
        </div>

        <%!-- Featured image — on the Files tab, matching the catalogue
             form (deliberate consistency call, 2026-08-15). Opens the
             scoped picker in single+image mode; the picker both browses
             this item's images and accepts new uploads (which get
             dropped into the item's folder automatically). --%>
        <div class={"mb-4 #{if @current_tab != :files, do: "hidden"}"}>
          <.attachments_files_panel
            uploads={@uploads}
            files_state={@files_state}
            featured_image_uuid={@featured_image_uuid}
            featured_image_file={@featured_image_file}
            featured_subtitle={
              Gettext.gettext(PhoenixKitCatalogue.Gettext, "Shown in lists and detail views.")
            }
            files_hint={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Spec sheets, drawings, photos. Any file type is accepted."
              )
            }
            remove_confirm={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Remove this file from the item? If it's not attached to any other item, it will be moved to trash (admins can restore)."
              )
            }
            remove_title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove from item")}
          />
        </div>

        <%!-- Actions — sit outside the tab panels so Save works from
             any tab; the form element wraps them all. Both saves are
             disabled while uploads are mid-flight so we don't race
             the post-upload `handle_progress` write against the save
             path (would drop the just-uploaded file from the
             resource). "Save" keeps you on the form (it's also the
             Enter-key submitter, being first in the DOM); "Save &
             Exit" returns to where the form was opened from. --%>
        <div class="flex justify-end gap-3 pt-2">
          <.button
            navigate={
              @return_to ||
                if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index()
            }
            variant="ghost"
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
          </.button>
          <.button
            type="submit"
            name="save_action"
            value="stay"
            class="btn-outline"
            disabled={@uploads.attachment_files.entries != []}
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save")}
          </.button>
          <.button
            type="submit"
            name="save_action"
            value="exit"
            disabled={@uploads.attachment_files.entries != []}
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {if @uploads.attachment_files.entries != [],
              do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Waiting for uploads..."),
              else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save & Exit")}
          </.button>
        </div>
      </.form>

      <%!-- AI translate modal — rendered OUTSIDE the form (its endpoint/
           prompt selectors are their own <form>; nested forms are invalid). --%>
      <.ai_translate_modal ai_translate={ai_translate_config(assigns)} />

      <%!-- Move — collapsed by default. Standard items move to a
           category anywhere; smart items move across smart catalogues
           (no category). Each block only renders when its own target
           list is non-empty so we never show an empty-dropdown dead
           end; the outer <details> only renders when at least one
           branch is available. --%>
      <details
        :if={
          @action == :edit &&
            ((@catalogue_kind != "smart" && @all_categories != []) ||
               (@catalogue_kind == "smart" && @smart_move_targets != []))
        }
        class="card bg-base-100 shadow-lg"
      >
        <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2 select-none">
          <.icon name="hero-arrows-right-left" class="w-4 h-4 text-base-content/60" />
          <h3 class="font-semibold text-base">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}</h3>
          <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
        </summary>

        <div class="card-body pt-0 space-y-6">
          <%!-- Standard items: move to any category --%>
          <div :if={@catalogue_kind != "smart" && @all_categories != []} class="flex flex-col gap-3">
            <div>
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to Another Category")}</p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move this item to a category in any catalogue.")}
              </p>
            </div>
            <div class="flex items-end gap-3">
              <div class="fieldset flex-1">
                <.select
                  name="category_uuid"
                  id="item-move-category"
                  value={@move_target}
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select category --")}
                  options={Enum.map(@all_categories, &{&1.name, &1.uuid})}
                  class="select-sm transition-colors focus-within:select-primary"
                  phx-change="select_move_target"
                />
              </div>
              <.button
                type="button"
                phx-click="move_item"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving...")}
                disabled={is_nil(@move_target)}
                variant="outline"
                size="sm"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
              </.button>
            </div>
          </div>

          <%!-- Smart items: move to a different smart catalogue --%>
          <div :if={@catalogue_kind == "smart" && @smart_move_targets != []} class="flex flex-col gap-3">
            <div>
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to Another Smart Catalogue")}</p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Move this item into a different smart catalogue. Its catalogue rules stay attached."
                )}
              </p>
            </div>
            <div class="flex items-end gap-3">
              <div class="fieldset flex-1">
                <.select
                  name="catalogue_uuid"
                  id="item-move-smart-catalogue"
                  value={@move_target}
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select catalogue --")}
                  options={Enum.map(@smart_move_targets, &{&1.name, &1.uuid})}
                  class="select-sm transition-colors focus-within:select-primary"
                  phx-change="select_move_target"
                />
              </div>
              <.button
                type="button"
                phx-click="move_item"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving...")}
                disabled={is_nil(@move_target)}
                variant="outline"
                size="sm"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
              </.button>
            </div>
          </div>
        </div>
      </details>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp lang_name(language_tabs, code) do
    case Enum.find(language_tabs, &(&1.code == code)) do
      %{name: name} -> name
      _ -> code
    end
  end
end
