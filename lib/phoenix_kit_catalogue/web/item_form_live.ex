defmodule PhoenixKitCatalogue.Web.ItemFormLive do
  @moduledoc "Create/edit form for catalogue items with multilang support."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitCatalogue.Web.Components, only: [catalogue_rules_picker: 1]

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Item

  @translatable_fields ["name", "description"]
  @preserve_fields %{
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

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    case load_item(action, params) do
      {nil, _, _} ->
        {:ok,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Item not found."))
         |> push_navigate(to: Paths.index())}

      {item, changeset, catalogue_uuid} ->
        {:ok, mount_form(socket, action, item, changeset, catalogue_uuid)}
    end
  end

  defp load_item(:new, params) do
    catalogue_uuid = params["catalogue_uuid"]
    item = %Item{catalogue_uuid: catalogue_uuid}
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
          do: Gettext.gettext(PhoenixKitWeb.Gettext, "New Item"),
          else: Gettext.gettext(PhoenixKitWeb.Gettext, "Edit %{name}", name: item.name)
        ),
      action: action,
      item: item,
      catalogue_uuid: catalogue_uuid,
      catalogue_kind: kind,
      catalogue_markup: markup_from_catalogue(parent_catalogue),
      catalogue_discount: discount_from_catalogue(parent_catalogue),
      categories: categories,
      manufacturers: Catalogue.list_manufacturers(status: "active"),
      all_categories: all_categories,
      smart_move_targets: smart_move_targets,
      move_target: nil
    )
    |> assign_changeset(changeset)
    |> assign_rule_state(item, kind, catalogue_uuid)
    |> mount_multilang()
    |> adjust_multilang_for_item(item)
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
  defp assign_rule_state(socket, _item, "smart" = _kind, catalogue_uuid) do
    candidates = Catalogue.list_catalogues() |> Enum.reject(&(&1.uuid == catalogue_uuid))

    existing =
      case socket.assigns.item do
        %Item{uuid: nil} -> %{}
        %Item{} = item -> Catalogue.catalogue_rule_map(item) |> Map.new(&to_working_entry/1)
      end

    assign(socket,
      rule_candidates: candidates,
      working_rules: existing
    )
  end

  defp assign_rule_state(socket, _item, _kind, _catalogue_uuid) do
    assign(socket, rule_candidates: [], working_rules: %{})
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

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"item" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.item
      |> Catalogue.change_item(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("save", %{"item" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    save_item(socket, socket.assigns.action, params)
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
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Item moved."))
         |> push_navigate(to: redirect_target(socket, item))}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to move item.")
         )}
    end
  end

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  defp save_item(socket, :new, params) do
    params = Map.put_new(params, "catalogue_uuid", socket.assigns.catalogue_uuid)

    with {:ok, item} <- Catalogue.create_item(params, actor_opts(socket)),
         {:ok, _rules} <- maybe_put_rules(socket, item) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Item created."))
       |> push_navigate(to: redirect_target(socket, item))}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, changeset)}

      {:error, {:duplicate_referenced_catalogue, _uuid}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitWeb.Gettext,
             "Each catalogue can only appear once in the rules list."
           )
         )}
    end
  end

  defp save_item(socket, :edit, params) do
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
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Item updated."))
       |> push_navigate(to: redirect_target(socket, item))}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, changeset)}

      {:error, {:duplicate_referenced_catalogue, _uuid}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitWeb.Gettext,
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
        rules = working_rules_to_specs(socket.assigns.working_rules)
        Catalogue.put_catalogue_rules(item, rules, actor_opts(socket))

      _ ->
        {:ok, :skipped}
    end
  end

  defp working_rules_to_specs(working_rules) do
    working_rules
    |> Enum.with_index()
    |> Enum.map(fn {{uuid, %{value: v, unit: u}}, idx} ->
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

  defp redirect_target(socket, item) do
    cond do
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
    <div class="flex flex-col mx-auto max-w-2xl px-4 py-8 gap-6">
      <%!-- Header --%>
      <.admin_page_header
        back={if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index()}
        title={@page_title}
        subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Add a new product or material to the catalogue."), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Update item details, pricing, and classification.")}
      />

      <%!-- Primary language warning --%>
      <div :if={@needs_primary_translation} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
        <div>
          <p class="text-sm font-medium">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "This item was imported in %{lang}. Please fill in the %{primary} translation and save to set it as the primary language.", lang: lang_name(@language_tabs, @item_primary_language), primary: lang_name(@language_tabs, @primary_language))}
          </p>
        </div>
      </div>

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-lg">
          <.multilang_tabs multilang_enabled={@multilang_enabled} language_tabs={@language_tabs} current_lang={@current_lang} />

          <%!-- Only translatable fields live inside the wrapper. When the
               user switches languages, the wrapper's ID changes and
               morphdom remounts its children — so we keep the scope as
               small as possible (name + description), not the whole
               form. Everything else renders as a sibling below. --%>
          <.multilang_fields_wrapper multilang_enabled={@multilang_enabled} current_lang={@current_lang} skeleton_class="card-body flex flex-col gap-5 pb-0">
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
                field_name="name" form_prefix="item" changeset={@changeset}
                schema_field={:name} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label={Gettext.gettext(PhoenixKitWeb.Gettext, "Name")} placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "e.g., Oak Panel 18mm")} required
                class="w-full"
              />

              <.translatable_field
                field_name="description" form_prefix="item" changeset={@changeset}
                schema_field={:description} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label={Gettext.gettext(PhoenixKitWeb.Gettext, "Description")} type="textarea"
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Product specifications, dimensions, materials...")}
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
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z" />
                  </svg>
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Pricing & Identification")}
                </h2>

                <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                  <.input
                    field={@form[:sku]}
                    type="text"
                    label={Gettext.gettext(PhoenixKitWeb.Gettext, "SKU")}
                    class="font-mono"
                    placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "e.g., KF-001")}
                  />
                  <div class="form-control">
                    <.input
                      field={@form[:base_price]}
                      type="number"
                      label={Gettext.gettext(PhoenixKitWeb.Gettext, "Base Price")}
                      step="0.01"
                      min="0"
                      placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "0.00")}
                    />
                    <span class="label-text-alt text-base-content/50 mt-1">{Gettext.gettext(PhoenixKitWeb.Gettext, "Cost/purchase price before catalogue markup.")}</span>
                  </div>
                  <.select
                    field={@form[:unit]}
                    label={Gettext.gettext(PhoenixKitWeb.Gettext, "Unit")}
                    class="transition-colors focus-within:select-primary"
                    options={[
                      {Gettext.gettext(PhoenixKitWeb.Gettext, "Piece"), "piece"},
                      {Gettext.gettext(PhoenixKitWeb.Gettext, "m² (square meter)"), "m2"},
                      {Gettext.gettext(PhoenixKitWeb.Gettext, "Running meter"), "running_meter"}
                    ]}
                  />
                  <div class="form-control">
                    <.input
                      field={@form[:markup_percentage]}
                      type="number"
                      label={Gettext.gettext(PhoenixKitWeb.Gettext, "Markup Override (%)")}
                      step="0.01"
                      min="0"
                      placeholder={
                        if @catalogue_markup,
                          do: Gettext.gettext(PhoenixKitWeb.Gettext, "Inherit: %{markup}%", markup: Decimal.to_string(@catalogue_markup, :normal)),
                          else: Gettext.gettext(PhoenixKitWeb.Gettext, "Inherit catalogue markup")
                      }
                    />
                    <span class="label-text-alt text-base-content/50 mt-1">
                      {Gettext.gettext(PhoenixKitWeb.Gettext, "Leave blank to inherit the catalogue's markup. Set (including 0) to override just this item.")}
                    </span>
                  </div>
                  <div class="form-control">
                    <.input
                      field={@form[:discount_percentage]}
                      type="number"
                      label={Gettext.gettext(PhoenixKitWeb.Gettext, "Discount Override (%)")}
                      step="0.01"
                      min="0"
                      max="100"
                      placeholder={
                        if @catalogue_discount,
                          do: Gettext.gettext(PhoenixKitWeb.Gettext, "Inherit: %{discount}%", discount: Decimal.to_string(@catalogue_discount, :normal)),
                          else: Gettext.gettext(PhoenixKitWeb.Gettext, "Inherit catalogue discount")
                      }
                    />
                    <span class="label-text-alt text-base-content/50 mt-1">
                      {Gettext.gettext(PhoenixKitWeb.Gettext, "Leave blank to inherit the catalogue's discount. Set (including 0) to override just this item.")}
                    </span>
                  </div>
                </div>
              </div>

              <%!-- Smart-catalogue rules (only for kind: "smart") --%>
              <div :if={@catalogue_kind == "smart"} class="flex flex-col gap-4">
                <div class="divider my-0"></div>
                <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                  <.icon name="hero-link" class="w-4 h-4" />
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue Rules")}
                </h2>
                <p class="text-sm text-base-content/60 -mt-2">
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Pick which catalogues this item applies to and set a value + unit per catalogue. Rows left blank inherit the defaults below.")}
                </p>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div class="form-control">
                    <.input
                      field={@form[:default_value]}
                      type="number"
                      label={Gettext.gettext(PhoenixKitWeb.Gettext, "Default Value")}
                      step="0.0001"
                      min="0"
                      placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "e.g., 5")}
                    />
                    <span class="label-text-alt text-base-content/50 mt-1">
                      {Gettext.gettext(PhoenixKitWeb.Gettext, "Used for any selected catalogue that doesn't have its own value. If no catalogues are selected, this is the item's standalone fee (e.g. $50 flat).")}
                    </span>
                  </div>
                  <div class="form-control">
                    <.select
                      field={@form[:default_unit]}
                      label={Gettext.gettext(PhoenixKitWeb.Gettext, "Default Unit")}
                      class="transition-colors focus-within:select-primary"
                      options={[
                        {Gettext.gettext(PhoenixKitWeb.Gettext, "Percent (%)"), "percent"},
                        {Gettext.gettext(PhoenixKitWeb.Gettext, "Flat amount"), "flat"}
                      ]}
                    />
                    <span class="label-text-alt text-base-content/50 mt-1">
                      {Gettext.gettext(PhoenixKitWeb.Gettext, "Used for any selected catalogue that doesn't have its own unit.")}
                    </span>
                  </div>
                </div>

                <.catalogue_rules_picker
                  catalogues={@rule_candidates}
                  rules={@working_rules}
                  item_default_value={Ecto.Changeset.get_field(@changeset, :default_value)}
                />
              </div>

              <%!-- Classification — hidden for smart catalogues, whose items
                   don't belong to a category/manufacturer in the usual sense. --%>
              <div :if={@catalogue_kind != "smart"} class="flex flex-col gap-5">
                <div class="divider my-0"></div>

                <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10" />
                  </svg>
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Classification")}
                </h2>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <.select
                    field={@form[:category_uuid]}
                    label={Gettext.gettext(PhoenixKitWeb.Gettext, "Category")}
                    class="transition-colors focus-within:select-primary"
                    prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "-- No category --")}
                    options={Enum.map(@categories, &{&1.name, &1.uuid})}
                  />
                  <.select
                    field={@form[:manufacturer_uuid]}
                    label={Gettext.gettext(PhoenixKitWeb.Gettext, "Manufacturer")}
                    class="transition-colors focus-within:select-primary"
                    prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "-- No manufacturer --")}
                    options={Enum.map(@manufacturers, &{&1.name, &1.uuid})}
                  />
                </div>
              </div>

              <div class="form-control">
                <.select
                  field={@form[:status]}
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}
                  class="transition-colors focus-within:select-primary"
                  options={[
                    {Gettext.gettext(PhoenixKitWeb.Gettext, "Active"), "active"},
                    {Gettext.gettext(PhoenixKitWeb.Gettext, "Inactive"), "inactive"},
                    {Gettext.gettext(PhoenixKitWeb.Gettext, "Discontinued"), "discontinued"}
                  ]}
                />
                <span class="label-text-alt text-base-content/50 mt-1">{Gettext.gettext(PhoenixKitWeb.Gettext, "Discontinued items are kept for reference but hidden from active listings.")}</span>
              </div>

              <%!-- Actions --%>
              <div class="divider my-0"></div>

              <div class="flex justify-end gap-3">
                <.link navigate={if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index()} class="btn btn-ghost">{Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}</.link>
                <button
                  type="submit"
                  class="btn btn-primary phx-submit-loading:opacity-75"
                  phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Saving...")}
                >{if @action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Create Item"), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Save Changes")}</button>
              </div>
          </div>
        </div>
      </.form>

      <%!-- Move — standard items move to a category anywhere; smart
           items move across smart catalogues (no category). Each card
           only renders when its own target list is non-empty so we
           never show an empty-dropdown dead end. --%>
      <div :if={@action == :edit && @catalogue_kind != "smart" && @all_categories != []} class="card bg-base-100 shadow-lg">
        <div class="card-body flex flex-col gap-3">
          <h3 class="text-sm font-semibold text-base-content/80">{Gettext.gettext(PhoenixKitWeb.Gettext, "Move to Another Category")}</h3>
          <p class="text-xs text-base-content/50">{Gettext.gettext(PhoenixKitWeb.Gettext, "Move this item to a category in any catalogue.")}</p>
          <div class="flex items-end gap-3">
            <div class="form-control flex-1">
              <.select
                name="category_uuid"
                id="item-move-category"
                value={@move_target}
                prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "-- Select category --")}
                options={Enum.map(@all_categories, &{&1.name, &1.uuid})}
                class="select-sm transition-colors focus-within:select-primary"
                phx-change="select_move_target"
              />
            </div>
            <button
              type="button"
              phx-click="move_item"
              disabled={is_nil(@move_target)}
              class="btn btn-sm btn-outline"
            >
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Move")}
            </button>
          </div>
        </div>
      </div>

      <div :if={@action == :edit && @catalogue_kind == "smart" && @smart_move_targets != []} class="card bg-base-100 shadow-lg">
        <div class="card-body flex flex-col gap-3">
          <h3 class="text-sm font-semibold text-base-content/80">{Gettext.gettext(PhoenixKitWeb.Gettext, "Move to Another Smart Catalogue")}</h3>
          <p class="text-xs text-base-content/50">{Gettext.gettext(PhoenixKitWeb.Gettext, "Move this item into a different smart catalogue. Its catalogue rules stay attached.")}</p>
          <div class="flex items-end gap-3">
            <div class="form-control flex-1">
              <.select
                name="catalogue_uuid"
                id="item-move-smart-catalogue"
                value={@move_target}
                prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "-- Select catalogue --")}
                options={Enum.map(@smart_move_targets, &{&1.name, &1.uuid})}
                class="select-sm transition-colors focus-within:select-primary"
                phx-change="select_move_target"
              />
            </div>
            <button
              type="button"
              phx-click="move_item"
              disabled={is_nil(@move_target)}
              class="btn btn-sm btn-outline"
            >
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Move")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp lang_name(language_tabs, code) do
    case Enum.find(language_tabs, &(&1.code == code)) do
      %{name: name} -> name
      _ -> code
    end
  end
end
