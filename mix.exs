defmodule PhoenixKitCatalogue.MixProject do
  use Mix.Project

  @version "0.14.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_catalogue"

  def project do
    [
      app: :phoenix_kit_catalogue,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Elixir 1.19 mix test requires explicit filters to know which test
      # files to load and which to ignore. Without this it warns about
      # `test/support/*.ex` not matching either filter and skips running
      # the support modules through its loader, which means
      # `test_helper.exs` runs before they're available.
      test_load_filters: [~r/_test\.exs$/],
      test_ignore_filters: [~r{^test/support/}],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Catalogue module for PhoenixKit — manufacturers, suppliers, and product catalogues.",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitCatalogue",
      source_url: @source_url,
      docs: docs(),
      aliases: aliases(),
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitCatalogue\.Test\./,
          PhoenixKitCatalogue.DataCase,
          PhoenixKitCatalogue.LiveCase,
          PhoenixKitCatalogue.ActivityLogAssertions,
          # NimbleCSV-generated parser modules — macro-defined CSV
          # readers from the `nimble_csv` dep, not production code
          # we own. Their internal branches are NimbleCSV's contract
          # to test, not ours.
          PhoenixKitCatalogue.Import.CommaParser,
          PhoenixKitCatalogue.Import.SemicolonParser,
          PhoenixKitCatalogue.Import.TabParser
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset => the published pin, so
  # mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # 1.7.231 is the floor: that release ships
      # `PhoenixKitWeb.Live.UrlState`, which 3 LiveView files in this
      # module `use`. Anything below it resolves a core with no such
      # module, and the failure surfaces in the consumer's build.
      pk_dep(:phoenix_kit, "~> 2.0"),
      pk_dep(:phoenix_kit_ai, "~> 0.18"),
      {:phoenix_live_view, "~> 1.1"},
      {:xlsx_reader, "~> 0.8"},
      # Used directly by the CSV import parser (NimbleCSV.define/2). Declared
      # explicitly rather than relying on the transitive pull through
      # :phoenix_kit, so the import pipeline doesn't silently break if core
      # ever drops it.
      {:nimble_csv, "~> 1.2"},
      # Same reasoning for the PRO100 estimate-template parser. xmerl (OTP) was
      # tried first and rejects the file: the export declares no encoding and
      # carries Estonian and Cyrillic text, so xmerl fails on the first "ö".
      # Saxy decodes UTF-8 natively and resolves no external entities, which
      # matters for a file that arrives from outside.
      {:saxy, "~> 1.6"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Test-only: LazyHtml parses rendered HTML so Phoenix.LiveViewTest
      # can assert on LiveView output in `live/2` and friends.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # `priv` is not optional here, though it looked it for a long time. It
      # carries the gettext catalogues — a Hex consumer without them gets the
      # English msgid for every string, which is the bug #9 and #17 fixed in
      # phoenix_kit_manufacturing and phoenix_kit_warehouse — AND
      # `priv/static/pdfjs/`, the vendored viewer that `Paths.pdf_viewer/1`
      # points an iframe at. Both documented delivery routes for those assets
      # (the host's `Plug.Static` mount and core's `PdfViewerController`
      # fallback) read them out of the installed package, so with `priv`
      # unshipped neither could work and the PDF viewer was broken for every
      # consumer installing from Hex.
      files: ~w(lib priv guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitCatalogue",
      # Tags in this repo are v-prefixed, not bare version numbers — a bare ref
      # points at a tag that does not exist and 404s every HexDocs source link.
      source_ref: "v#{@version}",
      extras: [
        "guides/smart_catalogues.md": [title: "Smart Catalogues"]
      ],
      groups_for_extras: [
        Guides: ~r"guides/.+\.md"
      ]
    ]
  end
end
