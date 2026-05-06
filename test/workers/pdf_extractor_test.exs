defmodule PhoenixKitCatalogue.Workers.PdfExtractorTest do
  @moduledoc """
  Tests for `PhoenixKitCatalogue.Workers.PdfExtractor`.

  Pure-function helpers (`normalize/1`, `parse_page_count/1`,
  `inspect_reason/1`) are covered without DB or Storage stubs; the
  `perform/1` orchestration path requires Storage stubbing + the
  sandbox and is left out of this file (would slot in as part of a
  later integration sweep using the same `:integrations_backend`
  pattern that document_creator pioneered).
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Workers.PdfExtractor

  describe "normalize/1" do
    test "strips soft-hyphens" do
      assert PdfExtractor.normalize("hello­world") == "helloworld"
    end

    test "undoes line-break hyphenation: 'Pre-\\nmium' → 'Premium'" do
      assert PdfExtractor.normalize("Pre-\nmium") == "Premium"
    end

    test "unfolds the five common ligatures (ﬁ ﬂ ﬀ ﬃ ﬄ)" do
      input = "oﬃce, ﬁt, ﬂow, oﬀ, ﬄuent"
      assert PdfExtractor.normalize(input) == "office, fit, flow, off, ffluent"
    end

    test "collapses whitespace runs to a single space" do
      assert PdfExtractor.normalize("a    b\t\nc") == "a b c"
    end

    test "trims leading and trailing whitespace" do
      assert PdfExtractor.normalize("   surrounded   ") == "surrounded"
    end

    test "returns empty string for non-binary input" do
      assert PdfExtractor.normalize(nil) == ""
      assert PdfExtractor.normalize(:atom) == ""
    end

    test "preserves Finnish diacritics + special chars from real catalogue PDFs" do
      input = "Kaasujousi 19,75 €/kpl • Harmaa"
      out = PdfExtractor.normalize(input)
      assert out == input
    end

    test "no-op on already-normalized text" do
      assert PdfExtractor.normalize("plain text") == "plain text"
    end
  end

  describe "parse_page_count/1" do
    test "extracts integer from a typical pdfinfo line" do
      output = """
      Title:          Helahinnasto 2026
      Pages:          172
      Encrypted:      no
      """

      assert PdfExtractor.parse_page_count(output) == {:ok, 172}
    end

    test "accepts page count of 1" do
      assert PdfExtractor.parse_page_count("Pages:  1\n") == {:ok, 1}
    end

    test "accepts page count of 0 (degenerate but legal)" do
      assert PdfExtractor.parse_page_count("Pages:  0\n") == {:ok, 0}
    end

    test "returns error when no Pages: line present" do
      assert {:error, {:pdfinfo_failed, _}} = PdfExtractor.parse_page_count("garbage output")
    end

    test "returns error on empty pdfinfo output" do
      assert {:error, {:pdfinfo_failed, _}} = PdfExtractor.parse_page_count("")
    end

    test "ignores Pages: hidden inside other lines" do
      # Ensure the regex anchor (`^Pages:`) protects against false matches
      # in lines that contain "Pages:" not at the start.
      output = "Some Pages: 999 are mentioned in body\n"
      assert {:error, {:pdfinfo_failed, _}} = PdfExtractor.parse_page_count(output)
    end
  end

  describe "inspect_reason/1" do
    test "formats {:pdfinfo_failed, msg}" do
      assert PdfExtractor.inspect_reason({:pdfinfo_failed, "no Pages: line"}) ==
               "pdfinfo: no Pages: line"
    end

    test "formats {:pdftotext_failed, page, code, msg}" do
      assert PdfExtractor.inspect_reason({:pdftotext_failed, 42, 1, "malformed pdf"}) ==
               "pdftotext failed on page 42 (exit 1): malformed pdf"
    end

    test "formats {:pdftotext_failed, page, atom_code, msg}" do
      assert PdfExtractor.inspect_reason({:pdftotext_failed, 7, :enoent, "not on PATH"}) ==
               "pdftotext failed on page 7 (exit :enoent): not on PATH"
    end

    test "formats {:insert_page_failed, page, _cs}" do
      assert PdfExtractor.inspect_reason({:insert_page_failed, 13, %{}}) ==
               "could not insert page 13 (DB error)"
    end

    test "falls back to inspect/1 for unknown shapes" do
      assert PdfExtractor.inspect_reason({:something_else, 1, 2}) =~ "{:something_else, 1, 2}"
      assert PdfExtractor.inspect_reason(:bare_atom) == ":bare_atom"
    end
  end

  describe "Oban worker definition" do
    test "uses the :catalogue_pdf queue" do
      assert PdfExtractor.__info__(:attributes)
             |> Keyword.get(:behaviour, [])
             |> Enum.member?(Oban.Worker)
    end

    test "max_attempts is 3" do
      # The use Oban.Worker macro stores config; confirm the constant
      # via `new/1` round-trip.
      job_changeset = PdfExtractor.new(%{"file_uuid" => UUIDv7.generate()})
      assert job_changeset.changes.max_attempts == 3
    end

    test "queue is :catalogue_pdf" do
      job_changeset = PdfExtractor.new(%{"file_uuid" => UUIDv7.generate()})
      assert job_changeset.changes.queue == "catalogue_pdf"
    end
  end
end
