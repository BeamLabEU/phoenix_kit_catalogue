defmodule PhoenixKitCatalogue.Web.AttributeSetFormLive do
  @moduledoc """
  Create/edit form for attribute SETS (the 2026-08-18 rework): one
  dimension from one vendor — "Ikea colors" — stored as a managed
  entities blueprint whose data records are the values.

  Same event-driven doctrine as the group editor it replaces: the set's
  NAME and KIND save through a small form, while values persist
  immediately per action — add, rename-on-blur, default star, drag
  reorder, delete. Extra fields (price per liter, drying time…) are
  blueprint fields managed here too; every value row then carries an
  input per extra field, saved on blur.

  Editing is primary-language: value labels are entities record titles,
  and their translations ride entities' own multilang mechanisms
  (design doc §UI, follow-up).
  """

  use Phoenix.LiveView

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  import PhoenixKitCatalogue.Web.Helpers, only: [actor_opts: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths

  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    cond do
      not Catalogue.attribute_sets_enabled?() ->
        {:ok,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Attribute sets need the Entities module enabled."
           )
         )
         |> push_navigate(to: Paths.attribute_groups())}

      action == :edit and is_nil(Catalogue.get_attribute_set(params["uuid"])) ->
        {:ok,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute set not found.")
         )
         |> push_navigate(to: Paths.attribute_groups())}

      true ->
        set = if action == :edit, do: Catalogue.get_attribute_set(params["uuid"])

        {:ok,
         socket
         |> assign(
           action: action,
           set: set,
           values: if(set, do: Catalogue.list_attribute_set_values(set), else: []),
           form_data: form_data_from(set),
           draft_generation: %{},
           refocus_key: nil,
           confirm_remove_field: nil,
           return_to: safe_return_to(params["return_to"])
         )
         |> assign_title()}
    end
  end

  defp assign_title(socket) do
    title =
      case {socket.assigns.action, socket.assigns.set} do
        {:new, _} ->
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Attribute Set")

        {:edit, set} ->
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: set.display_name)
      end

    assign(socket, :page_title, title)
  end

  defp form_data_from(nil), do: %{"name" => "", "kind" => "multi"}

  defp form_data_from(set) do
    %{
      "name" => set.display_name,
      "kind" => get_in(set.settings, ["catalogue", "kind"]) || "multi"
    }
  end

  defp safe_return_to(rt) when is_binary(rt) do
    if Routes.local_path?(rt), do: rt
  end

  defp safe_return_to(_), do: nil

  # ── Set form (name + kind) ─────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"set" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :form_data,
       Map.merge(socket.assigns.form_data, Map.take(params, ~w(name kind)))
     )}
  end

  def handle_event("save", %{"set" => params} = all_params, socket) do
    attrs = %{
      name: String.trim(params["name"] || ""),
      kind: params["kind"] || "multi"
    }

    save_set(socket, socket.assigns.action, attrs, save_mode(all_params))
  end

  # ── Values ─────────────────────────────────────────────────────────

  def handle_event("add_value", %{"value" => raw}, socket) do
    text = String.trim(raw)

    with true <- text != "",
         {:ok, _} <-
           Catalogue.create_attribute_set_value(
             socket.assigns.set,
             %{label: text},
             actor_opts(socket)
           ) do
      {:noreply, socket |> clear_draft("value") |> reload_set()}
    else
      false ->
        {:noreply, socket}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to add value.")
         )}
    end
  end

  def handle_event("rename_value", %{"uuid" => uuid, "value" => raw}, socket) do
    text = String.trim(raw)

    with %{} = value <- owned_value(socket, uuid),
         true <- text != "" and text != value.title,
         {:ok, _} <-
           Catalogue.update_attribute_set_value(
             socket.assigns.set,
             value,
             %{label: text},
             actor_opts(socket)
           ) do
      {:noreply, reload_set(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_value", %{"uuid" => uuid}, socket) do
    with %{} = value <- owned_value(socket, uuid),
         {:ok, _} <-
           Catalogue.delete_attribute_set_value(socket.assigns.set, value, actor_opts(socket)) do
      {:noreply, reload_set(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Star click: sets the default; clicking the starred value again
  # clears it (a set is allowed to have no default).
  def handle_event("make_default", %{"uuid" => uuid}, socket) do
    case owned_value(socket, uuid) do
      %{} = value ->
        new_default =
          if current_default(socket.assigns.set) == value.slug, do: nil, else: value.slug

        case Catalogue.update_attribute_set(
               socket.assigns.set,
               %{default_value_slug: new_default},
               actor_opts(socket)
             ) do
          {:ok, _} -> {:noreply, reload_set(socket)}
          {:error, _} -> {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reorder_values", %{"ordered_ids" => ids}, socket) when is_list(ids) do
    Catalogue.reorder_attribute_set_values(socket.assigns.set, Enum.filter(ids, &is_binary/1))
    {:noreply, reload_set(socket)}
  end

  def handle_event("reorder_values", _params, socket), do: {:noreply, socket}

  # ── Per-value extras (saved on blur / checkbox click) ──────────────

  def handle_event(
        "update_value_extra",
        %{"uuid" => uuid, "field" => key, "value" => raw},
        socket
      ) do
    with %{} = value <- owned_value(socket, uuid),
         %{} = field <- extra_field(socket.assigns.set, key) do
      # Unparseable input never reaches the DB — casting failures and
      # entities-side validation failures share one flash, and the
      # reload snaps the input back to the stored value.
      result =
        case cast_extra(field, raw) do
          {:ok, cast} ->
            Catalogue.update_attribute_set_value(
              socket.assigns.set,
              value,
              %{extras: %{key => cast}},
              actor_opts(socket)
            )

          :error ->
            {:error, :invalid_value}
        end

      case result do
        {:ok, _} ->
          {:noreply, reload_set(socket)}

        {:error, _} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Invalid value for %{field}.",
               field: field["label"]
             )
           )
           |> reload_set()}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_value_extra", %{"uuid" => uuid, "field" => key}, socket) do
    with %{} = value <- owned_value(socket, uuid),
         %{} <- extra_field(socket.assigns.set, key) do
      current = (value.data || %{})[key] == true

      handle_event(
        "update_value_extra",
        %{"uuid" => uuid, "field" => key, "value" => to_string(!current)},
        socket
      )
    else
      _ -> {:noreply, socket}
    end
  end

  # ── Extra fields (blueprint fields_definition) ─────────────────────

  def handle_event("add_extra_field", %{"field_label" => label} = params, socket) do
    attrs = %{label: String.trim(label), type: Map.get(params, "field_type", "text")}

    case Catalogue.add_attribute_set_field(socket.assigns.set, attrs, actor_opts(socket)) do
      {:ok, _} ->
        {:noreply, socket |> clear_draft("field") |> reload_set()}

      {:error, :label_required} ->
        {:noreply, socket}

      {:error, :duplicate_key} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "A field with this name already exists.")
         )}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to add field.")
         )}
    end
  end

  def handle_event("request_remove_field", %{"key" => key}, socket) do
    {:noreply, assign(socket, :confirm_remove_field, key)}
  end

  def handle_event("cancel_remove_field", _params, socket) do
    {:noreply, assign(socket, :confirm_remove_field, nil)}
  end

  def handle_event("confirm_remove_field", _params, socket) do
    with key when is_binary(key) <- socket.assigns.confirm_remove_field,
         {:ok, _} <-
           Catalogue.remove_attribute_set_field(socket.assigns.set, key, actor_opts(socket)) do
      {:noreply, socket |> assign(:confirm_remove_field, nil) |> reload_set()}
    else
      _ -> {:noreply, assign(socket, :confirm_remove_field, nil)}
    end
  end

  # ── Save / helpers ─────────────────────────────────────────────────

  defp save_mode(%{"save_action" => "stay"}), do: :stay
  defp save_mode(_params), do: :exit

  defp exit_target(%Phoenix.LiveView.Socket{} = socket), do: exit_target(socket.assigns)
  defp exit_target(assigns), do: assigns[:return_to] || Paths.attribute_groups()

  defp save_set(socket, :new, %{name: ""}, _mode) do
    {:noreply,
     put_flash(
       socket,
       :error,
       Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name is required.")
     )}
  end

  defp save_set(socket, :new, attrs, mode) do
    case Catalogue.create_attribute_set(attrs, actor_opts(socket)) do
      {:ok, set} ->
        target =
          case mode do
            # Stay lands on the created set's edit form — that's where
            # values get added, so it's the natural next step.
            :stay -> Paths.attribute_set_edit(set.uuid)
            :exit -> exit_target(socket)
          end

        {:noreply,
         socket
         |> put_flash(
           :info,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute set created.")
         )
         |> push_navigate(to: target)}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Failed to create the set — is the name unique?"
           )
         )}
    end
  end

  # Same rule as :new — no silent partial save with a cleared name.
  defp save_set(socket, :edit, %{name: ""}, _mode) do
    {:noreply,
     put_flash(
       socket,
       :error,
       Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name is required.")
     )}
  end

  defp save_set(socket, :edit, attrs, mode) do
    case Catalogue.update_attribute_set(socket.assigns.set, attrs, actor_opts(socket)) do
      {:ok, _} ->
        socket =
          put_flash(
            socket,
            :info,
            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute set updated.")
          )

        case mode do
          :stay ->
            {:noreply,
             socket
             |> reload_set()
             |> then(&assign(&1, :form_data, form_data_from(&1.assigns.set)))
             |> assign_title()}

          :exit ->
            {:noreply, push_navigate(socket, to: exit_target(socket))}
        end

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to update the set.")
         )}
    end
  end

  # The set can vanish mid-edit (another admin deleted it) — bail to
  # the listing instead of crashing on nil (panel finding).
  defp reload_set(socket) do
    case Catalogue.get_attribute_set(socket.assigns.set.uuid) do
      nil ->
        socket
        |> put_flash(
          :error,
          Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
            "This set was deleted in another session."
          )
        )
        |> push_navigate(to: Paths.attribute_groups())

      set ->
        socket
        |> assign(:set, set)
        |> assign(:values, Catalogue.list_attribute_set_values(set))
    end
  end

  # Events carry client-forgeable uuids — resolve only within this set.
  defp owned_value(socket, uuid) when is_binary(uuid) do
    Enum.find(socket.assigns.values, &(&1.uuid == uuid))
  end

  defp owned_value(_socket, _), do: nil

  defp extra_field(set, key) do
    Enum.find(set.fields_definition || [], &(&1["key"] == key))
  end

  defp current_default(set), do: get_in(set.settings, ["catalogue", "default_value_slug"])

  defp cast_extra(_field, ""), do: {:ok, nil}

  defp cast_extra(%{"type" => "number"}, raw) do
    case Float.parse(raw) do
      {num, ""} -> {:ok, if(num == trunc(num), do: trunc(num), else: num)}
      _ -> :error
    end
  end

  defp cast_extra(%{"type" => "boolean"}, raw), do: {:ok, raw == "true"}
  defp cast_extra(_field, raw), do: {:ok, raw}

  # Same uncontrolled-draft machinery as the group editor: the add-value
  # and add-field forms carry a generation in their DOM id, so clearing
  # after submit re-mounts a fresh empty node and refocuses it.
  defp clear_draft(socket, key) do
    socket
    |> assign(
      :draft_generation,
      Map.update(socket.assigns.draft_generation, key, 1, &(&1 + 1))
    )
    |> assign(:refocus_key, key)
  end

  defp draft_gen(draft_generation, key), do: Map.get(draft_generation, key, 0)

  defp kind_options do
    [
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Multiple values"), "multi"},
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Fixed value"), "fixed"}
    ]
  end

  defp field_type_options do
    [
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Text"), "text"},
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Number"), "number"},
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Yes / No"), "boolean"},
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Date"), "date"}
    ]
  end

  defp extra_value(value, key), do: (value.data || %{})[key]

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_section={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")}
      page_section_path={Paths.attribute_groups()}
      page_subtitle={
        if @action == :new,
          do:
            Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "A set is one dimension from one vendor — Ikea colors, HomeDepot trims. Items attach any number of sets."
            ),
          else:
            Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "Manage this set's values and extra fields."
            )
      }
      current_path={assigns[:url_path] || Paths.attribute_groups()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col mx-auto max-w-3xl px-4 py-8 gap-6">
        <div class="card bg-base-100 shadow-lg">
          <.form
            id="attribute-set-form"
            for={%{}}
            as={:set}
            action="#"
            phx-change="validate"
            phx-submit="save"
          >
            <div class={["card-body flex flex-col gap-5", @action == :edit && "pb-0"]}>
              <div class="flex flex-col sm:flex-row gap-4">
                <label class="form-control flex-1 min-w-0">
                  <span class="label-text font-medium pb-1">
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
                    <span class="text-error">*</span>
                  </span>
                  <input
                    type="text"
                    name="set[name]"
                    value={@form_data["name"]}
                    placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Ikea colors")}
                    required
                    class="input input-bordered w-full"
                  />
                </label>
                <label class="form-control w-full sm:w-44 shrink-0">
                  <span class="label-text font-medium pb-1">
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Kind")}
                  </span>
                  <.select name="set[kind]" value={@form_data["kind"]} options={kind_options()} />
                </label>
              </div>
              <p :if={@action == :edit} class="text-xs text-base-content/50 -mt-3">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Key: %{key} — stable, referenced by items and orders.",
                  key: @set.name
                )}
              </p>
            </div>
          </.form>

          <%!-- Values + extra fields — :edit only (the set must exist
               first). Discrete events, immediate persistence. --%>
          <div :if={@action == :edit} class="card-body flex flex-col gap-4 pt-4">
            <div class="divider my-0"></div>

            <div class="flex items-center gap-2">
              <.icon name="hero-swatch" class="w-5 h-5 text-base-content/60" />
              <h3 class="font-semibold text-base">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Values")}
              </h3>
            </div>

            <p :if={@values == []} class="text-sm text-base-content/60">
              {Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "No values yet. Add one below — e.g. Oak, White, Anthracite."
              )}
            </p>

            <div
              :if={@values != []}
              id="set-value-rows"
              phx-hook="SortableGrid"
              data-sortable="true"
              data-sortable-event="reorder_values"
              data-sortable-items=".sortable-item"
              data-sortable-handle=".pk-drag-handle"
              class="flex flex-col gap-2"
            >
              <%!-- Raw inputs deliberately, same L029 call as the group
                   editor: compact flex rows, no changeset to wire the
                   kit's feedback wrapper to. --%>
              <div
                :for={value <- @values}
                class="sortable-item rounded-lg border border-base-content/10 bg-base-content/5 p-2 flex flex-wrap items-center gap-2"
                data-id={value.uuid}
              >
                <span class="pk-drag-handle cursor-grab inline-flex items-center text-base-content/40 hover:text-base-content/70">
                  <.icon name="hero-bars-3" class="w-4 h-4" />
                </span>
                <input
                  id={"set-value-label-#{value.uuid}"}
                  type="text"
                  value={value.title}
                  phx-blur="rename_value"
                  phx-value-uuid={value.uuid}
                  class="input input-sm input-bordered bg-base-100 font-medium flex-1 min-w-32"
                />

                <%!-- One compact input per extra field, saved on blur;
                     booleans are a toggle. --%>
                <label
                  :for={field <- @set.fields_definition || []}
                  class="flex items-center gap-1 text-xs text-base-content/60"
                  title={field["label"]}
                >
                  <span class="max-w-20 truncate">{field["label"]}</span>
                  <input
                    :if={field["type"] == "boolean"}
                    type="checkbox"
                    checked={extra_value(value, field["key"]) == true}
                    phx-click="toggle_value_extra"
                    phx-value-uuid={value.uuid}
                    phx-value-field={field["key"]}
                    class="toggle toggle-xs"
                  />
                  <input
                    :if={field["type"] != "boolean"}
                    id={"extra-#{value.uuid}-#{field["key"]}"}
                    type={
                      case field["type"] do
                        "number" -> "number"
                        "date" -> "date"
                        _ -> "text"
                      end
                    }
                    step={field["type"] == "number" && "any"}
                    value={extra_value(value, field["key"])}
                    phx-blur="update_value_extra"
                    phx-value-uuid={value.uuid}
                    phx-value-field={field["key"]}
                    class="input input-xs input-bordered bg-base-100 w-24"
                  />
                </label>

                <.button
                  type="button"
                  phx-click="make_default"
                  phx-value-uuid={value.uuid}
                  variant="ghost"
                  size="xs"
                  class={["px-1", current_default(@set) == value.slug && "text-warning"]}
                  title={
                    if current_default(@set) == value.slug,
                      do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Default value"),
                      else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Make default")
                  }
                >
                  <.icon
                    name={
                      if current_default(@set) == value.slug,
                        do: "hero-star-solid",
                        else: "hero-star"
                    }
                    class="w-4 h-4 phx-click-loading:hidden"
                  />
                  <span class="loading loading-spinner w-4 h-4 hidden phx-click-loading:inline-block">
                  </span>
                </.button>
                <.button
                  type="button"
                  phx-click="delete_value"
                  phx-value-uuid={value.uuid}
                  variant="ghost"
                  size="xs"
                  class="px-1 text-base-content/40 hover:text-error"
                  title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove value")}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4 phx-click-loading:hidden" />
                  <span class="loading loading-spinner w-4 h-4 hidden phx-click-loading:inline-block">
                  </span>
                </.button>
              </div>
            </div>

            <%!-- phx-update="ignore" + generation-bumped id — see the
                 group editor's draft note. --%>
            <form
              id={"add-set-value-form-g#{draft_gen(@draft_generation, "value")}"}
              phx-submit="add_value"
              phx-update="ignore"
              class="flex items-center gap-2"
            >
              <input
                id={"add-set-value-input-g#{draft_gen(@draft_generation, "value")}"}
                type="text"
                name="value"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add value...")}
                class="input input-sm input-bordered flex-1 min-w-0"
                phx-mounted={@refocus_key == "value" && JS.focus()}
              />
              <.button type="submit" variant="outline" size="sm" class="shrink-0">
                <%!-- literal spans, NOT <.icon> — component subtrees
                     inside phx-update="ignore" arrive as data-phx-skip
                     stubs on the id-bump re-mount. --%>
                <span class="hero-plus w-4 h-4 phx-submit-loading:hidden"></span>
                <span class="loading loading-spinner w-4 h-4 hidden phx-submit-loading:inline-block">
                </span>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add")}
              </.button>
            </form>

            <div class="divider my-0"></div>

            <div class="flex items-center gap-2">
              <.icon name="hero-adjustments-horizontal" class="w-5 h-5 text-base-content/60" />
              <h3 class="font-semibold text-base">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Extra fields")}
              </h3>
            </div>
            <p class="text-sm text-base-content/60 -mt-2">
              {Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Extra info every value carries — price per liter, drying time. Each value above gets an input per field."
              )}
            </p>

            <div :if={(@set.fields_definition || []) != []} class="flex flex-wrap gap-2">
              <span
                :for={field <- @set.fields_definition}
                class="badge badge-ghost gap-1.5 py-3"
              >
                {field["label"]}
                <span class="text-base-content/40 text-xs">({field["type"]})</span>
                <button
                  type="button"
                  phx-click="request_remove_field"
                  phx-value-key={field["key"]}
                  class="text-base-content/40 hover:text-error"
                  title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove field")}
                >
                  <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                </button>
              </span>
            </div>

            <form
              id={"add-set-field-form-g#{draft_gen(@draft_generation, "field")}"}
              phx-submit="add_extra_field"
              phx-update="ignore"
              class="flex items-center gap-2"
            >
              <input
                id={"add-set-field-input-g#{draft_gen(@draft_generation, "field")}"}
                type="text"
                name="field_label"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "New field name...")}
                class="input input-sm input-bordered flex-1 min-w-0"
                phx-mounted={@refocus_key == "field" && JS.focus()}
              />
              <div class="w-36 shrink-0">
                <.select
                  name="field_type"
                  value={field_type_options() |> List.first() |> elem(1)}
                  options={field_type_options()}
                  class="select-sm"
                />
              </div>
              <.button type="submit" variant="outline" size="sm" class="shrink-0">
                <span class="hero-plus w-4 h-4 phx-submit-loading:hidden"></span>
                <span class="loading loading-spinner w-4 h-4 hidden phx-submit-loading:inline-block">
                </span>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add")}
              </.button>
            </form>
          </div>
        </div>

        <div class="flex justify-end gap-3">
          <.button navigate={exit_target(assigns)} variant="ghost">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
          </.button>
          <%!-- "Save" keeps class="btn-outline" — composes with the
               default btn-primary (same trap as category_form_live). --%>
          <.button
            form="attribute-set-form"
            type="submit"
            name="save_action"
            value="stay"
            class="btn-outline"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save")}
          </.button>
          <.button
            form="attribute-set-form"
            type="submit"
            name="save_action"
            value="exit"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save & Exit")}
          </.button>
        </div>

        <.confirm_modal
          show={@confirm_remove_field != nil}
          on_confirm="confirm_remove_field"
          on_cancel="cancel_remove_field"
          title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove extra field")}
          title_icon="hero-trash"
          messages={[
            {:warning,
             Gettext.gettext(
               PhoenixKitCatalogue.Gettext,
               "The field disappears from every value. Data already entered is kept but hidden until a field with the same name is re-added."
             )}
          ]}
          confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove")}
          danger={true}
        />
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
