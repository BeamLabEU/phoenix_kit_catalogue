defmodule PhoenixKitCatalogue.Export.Source do
  @moduledoc """
  Behaviour for export sources (e.g. PRO100, future sources).

  Each source module defines a key, a human-readable label, the list of
  format options it supports, and a `render/2` function that produces the
  file content for a given format key and export context.

  ## Adding a new source

  1. Create a module that `@behaviour PhoenixKitCatalogue.Export.Source`.
  2. Implement all four callbacks.
  3. Register it in `PhoenixKitCatalogue.Export.sources/0`.
  """

  @doc "Machine key for the source (e.g. `:pro100`)."
  @callback key() :: atom()

  @doc "Human-readable label shown in the UI select."
  @callback label() :: String.t()

  @doc """
  Supported formats as `[{key, label}]` pairs.
  `key` is an atom used when calling `render/2`; `label` is the display string.
  """
  @callback formats() :: [{atom(), String.t()}]

  @doc """
  Renders the export content.

  `format_key` must be one of the atoms from `formats/0`.
  `ctx` is a map with keys: `:items`, `:index`, `:catalogue`, `:category`.

  Returns `{filename, iodata, mime_type}`.
  """
  @callback render(format_key :: atom(), ctx :: map()) ::
              {filename :: String.t(), iodata :: iodata(), mime :: String.t()}
end
