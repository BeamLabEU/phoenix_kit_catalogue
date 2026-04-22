defmodule PhoenixKitCatalogue.ItemMetadata do
  @moduledoc """
  Global, code-defined list of metadata fields that items can opt into.

  Items store their chosen values in `item.data["meta"]` as a flat map
  keyed by the definition's `:key` — e.g. `%{"color" => "red", "weight_kg" => "5.2"}`.
  Only fields the user has explicitly added to a given item appear in
  that map. The per-item form lets the user pick which fields to attach
  from `definitions/0`.

  The multilang layer owns the top-level `item.data` map (keys like
  `_name`, `_primary_language`, per-language entries) — metadata lives
  strictly under the `"meta"` sub-key so the two don't collide.

  All fields are text inputs for now — typed inputs (decimal / enum /
  etc.) can be reintroduced later by adding a `:type` field to the
  definition shape and dispatching at render + cast time.

  Edit `definitions/0` to add/remove fields. Removing a field from the
  list does **not** wipe stored values — items that already hold a
  value for the removed key will surface it as "Legacy" in the form so
  the data isn't lost; the user can clear it manually.
  """

  @type definition :: %{
          required(:key) => String.t(),
          required(:label) => String.t()
        }

  @doc """
  The global list of metadata definitions. Order here is the order
  used for the "Add metadata" dropdown.

  The `:label` values are translated at call time via
  `PhoenixKitWeb.Gettext` — do not cache the result across locale
  changes. The `:key` is stable (it's the JSONB key) and never
  translated.
  """
  @spec definitions() :: [definition()]
  def definitions do
    [
      %{key: "color", label: Gettext.gettext(PhoenixKitWeb.Gettext, "Color")},
      %{key: "weight", label: Gettext.gettext(PhoenixKitWeb.Gettext, "Weight")},
      %{key: "width", label: Gettext.gettext(PhoenixKitWeb.Gettext, "Width")},
      %{key: "height", label: Gettext.gettext(PhoenixKitWeb.Gettext, "Height")},
      %{key: "depth", label: Gettext.gettext(PhoenixKitWeb.Gettext, "Depth")},
      %{key: "material", label: Gettext.gettext(PhoenixKitWeb.Gettext, "Material")},
      %{key: "finish", label: Gettext.gettext(PhoenixKitWeb.Gettext, "Finish")}
    ]
  end

  @doc "Fetches a single definition by key. Returns `nil` if the key isn't in `definitions/0`."
  @spec definition(String.t()) :: definition() | nil
  def definition(key) when is_binary(key) do
    Enum.find(definitions(), &(&1.key == key))
  end

  @doc """
  Normalizes a raw form value for storage: trims whitespace, collapses
  blanks to `nil` so callers can drop empty entries from the JSONB map.
  """
  @spec cast_value(definition(), term()) :: String.t() | nil
  def cast_value(_def, value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def cast_value(_def, _value), do: nil
end
