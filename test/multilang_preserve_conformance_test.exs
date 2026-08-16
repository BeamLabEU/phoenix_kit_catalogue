defmodule PhoenixKitCatalogue.MultilangPreserveConformanceTest do
  @moduledoc """
  Source-scan pin for the 2026-08-16 "name it in all languages right
  away" bug: on a secondary language tab, a form submits only
  `lang_<field>` — the PRIMARY columns are absent from params, so every
  `merge_translatable_params/4` call site must pass `preserve_fields`
  covering the form's translatable primaries, or a validate fired from
  a secondary tab rebuilds the changeset without them and a :new record
  loses the primary text.

  Multilang enablement is DB-settings-backed, which is why this is a
  source pin rather than a LiveView test: the LiveView path can't be
  driven without seeding the Languages module. The runtime mechanism
  (`do_preserve_primary_fields/4`) lives in core and is covered there.
  """
  use ExUnit.Case, async: true

  @forms %{
    "lib/phoenix_kit_catalogue/web/attribute_group_form_live.ex" => ~w(name),
    "lib/phoenix_kit_catalogue/web/category_form_live.ex" => ~w(name description),
    "lib/phoenix_kit_catalogue/web/catalogue_form_live.ex" => ~w(name description),
    "lib/phoenix_kit_catalogue/web/item_form_live.ex" => ~w(name description)
  }

  for {path, fields} <- @forms do
    test "#{path} preserves its translatable primaries across language switches" do
      source = File.read!(unquote(path))

      merge_calls = length(Regex.scan(~r/merge_translatable_params\(/, source))
      preserve_passes = length(Regex.scan(~r/preserve_fields: @preserve_fields/, source))

      assert merge_calls > 0, "expected merge_translatable_params call sites"

      assert preserve_passes == merge_calls,
             "every merge_translatable_params call must pass " <>
               "preserve_fields: @preserve_fields (#{preserve_passes}/#{merge_calls})"

      for field <- unquote(fields) do
        assert source =~ ~s("#{field}" => :#{field}),
               "@preserve_fields must cover the translatable primary #{inspect(field)}"
      end
    end
  end
end
