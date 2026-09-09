defmodule PhoenixKitCatalogue.Test.FakeExtension do
  @moduledoc """
  Minimal stand-in for a `PhoenixKitCatalogue.Extension` implementer,
  compiled only under `MIX_ENV=test` (see `elixirc_paths/1` in mix.exs).
  Exercises the extension slot end to end without depending on
  `phoenix_kit_ecommerce` — namespace `"fake"`, a single `"note"` field
  that `cast_item/2`/`cast_category/2` require to be a non-blank string.
  """

  use Phoenix.Component

  @behaviour PhoenixKitCatalogue.Extension

  @impl true
  def key, do: "fake"

  @impl true
  def enabled?, do: true

  @impl true
  def item_section(assigns), do: section(assigns, "item")

  @impl true
  def category_section(assigns), do: section(assigns, "category")

  @impl true
  def cast_item(params, current), do: cast(params, current)

  @impl true
  def cast_category(params, current), do: cast(params, current)

  # `id: "status"` deliberately collides with the catalogue's own
  # "status" column id — `PhoenixKitCatalogue.Extensions.columns/1` must
  # namespace it under `key/0` ("fake:status") before it ever reaches
  # `PhoenixKitCatalogue.Web.TableConfig`, so a naive implementation
  # that forgot to namespace would show up here as a collision.
  @impl true
  def item_columns, do: [%{id: "status", label: fn -> "Fake status" end, render: &column/1}]

  @impl true
  def category_columns, do: [%{id: "status", label: fn -> "Fake status" end, render: &column/1}]

  defp column(record) do
    assigns = %{record: record}

    ~H"""
    <span id={"ext-fake-status-#{@record.uuid}"}>fake-status</span>
    """
  end

  defp section(assigns, form_prefix) do
    note =
      assigns
      |> Map.get(:data, %{})
      |> Kernel.||(%{})
      |> Map.get("fake", %{})
      |> Map.get("note", "")

    assigns =
      assigns
      |> Map.new()
      |> Phoenix.Component.assign(:form_prefix, form_prefix)
      |> Phoenix.Component.assign(:note, note)
      |> Phoenix.Component.assign(:error, field_error(assigns[:form], :note))

    ~H"""
    <div id="ext-fake-section">
      <input type="text" name={"#{@form_prefix}[fake][note]"} value={@note} />
      <p :if={@error} class="text-error">{@error}</p>
    </div>
    """
  end

  # Reads an error `Ecto.Changeset.add_error/4`-tagged with
  # `extension: "fake", field: field` off the `:data` field's errors on a
  # `to_form/2`-built form. Mirrors how the LiveView is expected to
  # surface an extension's cast failure (see `PhoenixKitCatalogue.Extensions.absorb/3`).
  defp field_error(%{errors: errors}, field) when is_list(errors) do
    Enum.find_value(errors, fn
      {:data, {msg, opts}} ->
        if Keyword.get(opts, :extension) == "fake" and Keyword.get(opts, :field) == field,
          do: msg

      _ ->
        nil
    end)
  end

  defp field_error(_form, _field), do: nil

  defp cast(params, current) do
    case Map.get(params, "note") do
      note when is_binary(note) and note != "" -> {:ok, Map.put(current, "note", note)}
      _ -> {:error, [note: "can't be blank"]}
    end
  end
end

defmodule PhoenixKitCatalogue.Test.FakeModule do
  @moduledoc """
  Carries `catalogue_extensions/0` so `PhoenixKit.ModuleRegistry.register/1`
  has something to add to the registry in extension-slot tests, mirroring
  how `phoenix_kit_ecommerce` exposes `PhoenixKitEcommerce.catalogue_extensions/0`.
  Not a real `PhoenixKit.Module` — the registry only needs the one callback.
  """

  alias PhoenixKitCatalogue.Test.FakeExtension

  def catalogue_extensions, do: [FakeExtension]
end

defmodule PhoenixKitCatalogue.Test.BrokenColumnsExtension do
  @moduledoc """
  A `PhoenixKitCatalogue.Extension` implementer whose `item_columns/0`
  and `category_columns/0` raise — exercises
  `PhoenixKitCatalogue.Extensions.columns/1`'s resilience contract (a
  raising extension contributes nothing rather than crashing the
  Columns modal or the table render), the same way `contributed_by/1`
  already tolerates a raising `catalogue_extensions/0`.
  """

  @behaviour PhoenixKitCatalogue.Extension

  @impl true
  def key, do: "broken"

  @impl true
  def enabled?, do: true

  @impl true
  def item_columns, do: raise("boom")

  @impl true
  def category_columns, do: raise("boom")
end

defmodule PhoenixKitCatalogue.Test.BrokenColumnsModule do
  @moduledoc "Registry carrier for `BrokenColumnsExtension` (see `FakeModule`)."

  alias PhoenixKitCatalogue.Test.BrokenColumnsExtension

  def catalogue_extensions, do: [BrokenColumnsExtension]
end
