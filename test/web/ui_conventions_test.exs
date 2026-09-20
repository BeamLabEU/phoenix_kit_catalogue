defmodule PhoenixKitCatalogue.Web.UIConventionsTest do
  @moduledoc """
  The module's UI conventions, checked over the source so a slip fails here
  rather than in front of the owner (2026-09-19: "why a different font?", and
  "Add supplier" beside "Unit Cost"). The conventions themselves:
  `dev_docs/guides/ui-conventions.md`.
  """
  use ExUnit.Case, async: true

  @web_sources Path.wildcard("lib/phoenix_kit_catalogue/web/**/*.ex")
  # Words that keep their capital inside a sentence-case string: names of
  # things, not headings. Acronyms (SKU, PDF) and words with digits (Pro100)
  # are allowed without listing.
  @proper_nouns ~w(Deleted Shopify Entities Incoterm)

  # The strings the code shows — gettext literals in lib/, not the whole
  # catalog (which also holds entries no page uses any more).
  defp ui_strings do
    sources = Enum.map_join(Path.wildcard("lib/**/*.ex"), "\n", &File.read!/1)

    ~r/gettext(?:_noop)?\(\s*(?:PhoenixKitCatalogue\.Gettext,\s*)?"((?:[^"\\]|\\.)+)"/
    |> Regex.scan(sources, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  test "no field is wrapped in daisyUI's .fieldset — it sets 12px and shrinks the label" do
    offenders =
      for file <- @web_sources,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/class="[^"]*\bfieldset(-label|-legend)?\b/,
          do: "#{file}:#{number}"

    assert offenders == []
  end

  test "labels, buttons, headings and tabs are sentence case" do
    offenders =
      for id <- ui_strings(),
          # Sentences carry their own capitals; examples are names as typed.
          not (id =~ ~r/[.?!]$|\. [A-Z]|^e\.g\./),
          [_first | rest] <- [List.flatten(Regex.scan(~r/[A-Za-z][A-Za-z'’]*/, id))],
          Enum.any?(rest, &title_word?/1),
          do: id

    assert offenders == []
  end

  defp title_word?(word) do
    String.match?(word, ~r/^[A-Z][a-z]/) and word not in @proper_nouns and
      word not in ~w(No)
  end

  test "an ellipsis is one character" do
    assert Enum.filter(ui_strings(), &String.contains?(&1, "...")) == []
  end

  test "a select prompt reads — X —, or All … for a filter" do
    prompts =
      for file <- @web_sources,
          [_, text] <-
            Regex.scan(
              ~r/\bprompt=\{\s*(?:Gettext\.)?gettext\(\s*(?:PhoenixKitCatalogue\.Gettext,\s*)?"([^"]+)"/,
              File.read!(file)
            ),
          do: text

    assert prompts != []
    assert Enum.reject(prompts, &(&1 =~ ~r/^— .+ —$|^All /)) == []
  end
end
