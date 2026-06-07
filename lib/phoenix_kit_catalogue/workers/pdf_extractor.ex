defmodule PhoenixKitCatalogue.Workers.PdfExtractor do
  @moduledoc """
  Oban worker that extracts text page-by-page from a PDF using
  `pdfinfo` (page count) + `pdftotext` (per-page text).

  Keyed by `file_uuid` (core's `phoenix_kit_files.uuid`), not the
  per-upload `phoenix_kit_cat_pdfs.uuid` — so two uploads of identical
  content share one extraction job.

  ## Lifecycle

  1. Look up the extraction row by `file_uuid`. If terminal
     (`extracted` / `scanned_no_text` / `failed`), no-op (retry of an
     already-done job, or duplicate enqueue from a content-dedup
     upload).
  2. Resolve the binary via `Storage.retrieve_file/1` — returns a
     temp path. Works whether the file lives on local disk, S3, or
     anything core supports.
  3. Mark `"extracting"`.
  4. `pdfinfo` for page count. Treat parse failures as fatal.
  5. For each page, `pdftotext -layout`, normalize, hash, upsert into
     the per-page content cache, insert a `pdf_pages` row.
  6. Transition to `extracted` (or `scanned_no_text` if all pages
     came back empty). Failures mid-loop transition to `failed`.

  ## Concurrency

  Configured via the host app's Oban queue config. Recommend
  `queue: :catalogue_pdf, limit: 2` so a 1000-page PDF doesn't pin
  CPU or block other queues.

  ## Deduplication

  Re-enqueueing the same content (duplicate-content upload, the self-heal
  `requeue_stuck_extractions/1`, or the per-PDF Retry button) is deduped
  *application-side* in `PdfLibrary.insert_extraction_job/1` — it skips
  the insert when a non-terminal `PdfExtractor` job already exists for the
  `file_uuid`. We deliberately do **not** use Oban's built-in `unique:`
  option: satisfying its compile-time check requires listing every
  incomplete state including `:suspended`, but that enum value is absent
  from the `oban_job_state` enum on hosts that upgraded the Oban *library*
  without running its latest *migration* — the uniqueness query then
  raises `22P02` and kills every enqueue. The app-side guard queries only
  the four states (`available` / `scheduled` / `executing` / `retryable`)
  present in every Oban version. Races are harmless: this worker
  short-circuits on a terminal status and page inserts are upserts.
  """

  use Oban.Worker,
    queue: :catalogue_pdf,
    max_attempts: 3

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.Catalogue.PdfLibrary
  alias PhoenixKitCatalogue.Schemas.{PdfExtraction, PdfPage}

  @terminal_statuses ~w(extracted scanned_no_text failed)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_uuid" => file_uuid}}) do
    repo = PhoenixKit.RepoHelper.repo()

    case repo.get(PdfExtraction, file_uuid) do
      nil ->
        {:cancel, :extraction_not_found}

      %{extraction_status: status} when status in @terminal_statuses ->
        :ok

      %PdfExtraction{} = extraction ->
        run(extraction)
    end
  end

  def perform(_job), do: {:cancel, :missing_file_uuid}

  defp run(%PdfExtraction{file_uuid: file_uuid}) do
    case Storage.retrieve_file(file_uuid) do
      {:ok, temp_path, _file} ->
        try do
          do_extract(file_uuid, temp_path)
        after
          _ = File.rm(temp_path)
        end

      {:error, reason} ->
        message = "could not retrieve file: #{inspect(reason)}"
        _ = PdfLibrary.mark_failed(file_uuid, message)
        {:error, message}
    end
  end

  defp do_extract(file_uuid, file_path) do
    case PdfLibrary.mark_extracting(file_uuid) do
      # A concurrent worker already reached a terminal state for this
      # file — nothing to do (and we must NOT pull it back to extracting).
      {:ok, :superseded} ->
        :ok

      {:ok, _extraction} ->
        run_extraction(file_uuid, file_path)

      {:error, reason} ->
        fail(file_uuid, reason)
    end
  end

  defp run_extraction(file_uuid, file_path) do
    case pdfinfo_page_count(file_path) do
      {:ok, page_count} ->
        {ok_count, failed} = extract_pages(file_uuid, file_path, page_count)
        finalize_with_failures(file_uuid, page_count, ok_count, Enum.reverse(failed))

      {:error, reason} ->
        fail(file_uuid, reason)
    end
  end

  # Every page failed (e.g. `pdftotext` missing, or a wholly unreadable
  # file): fail the job so Oban retries — don't mark an empty document as
  # successfully extracted.
  defp finalize_with_failures(file_uuid, _page_count, 0, [_ | _] = failed) do
    fail(file_uuid, {:all_pages_failed, summarize_failures(failed)})
  end

  # At least one page extracted: keep the usable partial result. A single
  # corrupt page (or a transient per-page hiccup) no longer discards the
  # whole document and burns all retries — we log the unreadable pages and
  # finalize on what we got.
  defp finalize_with_failures(file_uuid, page_count, _ok_count, failed) do
    if failed != [] do
      Logger.warning(
        "PdfExtractor: #{length(failed)} page(s) failed for #{inspect(file_uuid)}; " <>
          "keeping partial extraction (#{summarize_failures(failed)})"
      )
    end

    finalize(file_uuid, page_count)
  end

  defp summarize_failures(failed) do
    failed
    |> Enum.map_join("; ", fn {page, reason} -> "p#{page}: #{inspect_reason(reason)}" end)
    |> String.slice(0, 500)
  end

  defp fail(file_uuid, reason) do
    message = inspect_reason(reason)
    _ = PdfLibrary.mark_failed(file_uuid, message)
    {:error, message}
  end

  defp finalize(file_uuid, page_count) do
    if all_pages_empty?(file_uuid) do
      _ = PdfLibrary.mark_scanned_no_text(file_uuid, page_count)
      :ok
    else
      _ = PdfLibrary.mark_extracted(file_uuid, page_count)
      :ok
    end
  end

  defp all_pages_empty?(file_uuid) do
    repo = PhoenixKit.RepoHelper.repo()

    any_page? =
      from(p in PdfPage, where: p.file_uuid == ^file_uuid, limit: 1)
      |> repo.exists?()

    any_text? =
      from(p in PdfPage,
        join: c in assoc(p, :content),
        where: p.file_uuid == ^file_uuid,
        where: fragment("length(btrim(?)) > 0", c.text),
        limit: 1
      )
      |> repo.exists?()

    any_page? and not any_text?
  end

  defp pdfinfo_page_count(path) do
    case System.cmd("pdfinfo", [path], stderr_to_stdout: true) do
      {output, 0} ->
        parse_page_count(output)

      {raw, _code} ->
        {:error, {:pdfinfo_failed, String.slice(raw || "", 0, 300)}}
    end
  rescue
    e in ErlangError ->
      {:error, {:pdfinfo_failed, "pdfinfo not on PATH: #{Exception.message(e)}"}}
  end

  @doc false
  # Public for testability — internal pure function over `pdfinfo`'s
  # text output. Returns `{:ok, n}` or `{:error, {:pdfinfo_failed, msg}}`.
  def parse_page_count(output) when is_binary(output) do
    Regex.scan(~r/^Pages:\s+(\d+)/m, output)
    |> List.first()
    |> case do
      [_, count_str] ->
        case Integer.parse(count_str) do
          {n, _} when n >= 0 -> {:ok, n}
          _ -> {:error, {:pdfinfo_failed, "couldn't parse page count: #{output}"}}
        end

      _ ->
        {:error, {:pdfinfo_failed, "no Pages: line in pdfinfo output"}}
    end
  end

  # Returns `{succeeded_count, failed}` where `failed` is a list of
  # `{page_number, reason}` in reverse page order. Continues past a failed
  # page instead of halting, so one bad page doesn't discard the rest.
  defp extract_pages(_file_uuid, _path, 0), do: {0, []}

  defp extract_pages(file_uuid, file_path, page_count) do
    Enum.reduce(1..page_count, {0, []}, fn page_number, {ok_count, failed} ->
      case extract_page(file_uuid, file_path, page_number) do
        :ok -> {ok_count + 1, failed}
        {:error, reason} -> {ok_count, [{page_number, reason} | failed]}
      end
    end)
  end

  defp extract_page(file_uuid, file_path, page_number) do
    args = [
      "-layout",
      "-enc",
      "UTF-8",
      "-f",
      Integer.to_string(page_number),
      "-l",
      Integer.to_string(page_number),
      file_path,
      "-"
    ]

    case System.cmd("pdftotext", args, stderr_to_stdout: false) do
      {raw, 0} ->
        text = normalize(raw)

        case PdfLibrary.insert_page(file_uuid, page_number, text) do
          {:ok, _} -> :ok
          {:error, cs} -> {:error, {:insert_page_failed, page_number, cs}}
        end

      {raw, code} ->
        {:error, {:pdftotext_failed, page_number, code, String.slice(raw || "", 0, 200)}}
    end
  rescue
    e in ErlangError ->
      {:error,
       {:pdftotext_failed, page_number, :enoent, "pdftotext not on PATH: #{Exception.message(e)}"}}
  end

  # Normalize page text:
  # - Strip soft-hyphens
  # - Undo line-break hyphenation: "Pre-\nmium" → "Premium"
  # - Replace common ligatures (ﬁ, ﬂ, ﬀ, ﬃ, ﬄ)
  # - Collapse all whitespace runs to a single space
  # - Trim
  @doc false
  # Public for testability — pure-function text normalizer applied to
  # every page's `pdftotext` output before storage.
  def normalize(text) when is_binary(text) do
    text
    |> String.replace("­", "")
    |> ligatures()
    |> then(&Regex.replace(~r/-\n(\w)/u, &1, "\\1"))
    |> then(&Regex.replace(~r/\s+/u, &1, " "))
    |> String.trim()
  end

  def normalize(_), do: ""

  defp ligatures(text) do
    text
    |> String.replace("ﬁ", "fi")
    |> String.replace("ﬂ", "fl")
    |> String.replace("ﬀ", "ff")
    |> String.replace("ﬃ", "ffi")
    |> String.replace("ﬄ", "ffl")
  end

  @doc false
  # Public for testability — collapses internal worker error tuples
  # into the human-readable string stored in `extractions.error_message`
  # and surfaced by the LV's "Extraction failed" alert.
  def inspect_reason({:pdfinfo_failed, msg}), do: "pdfinfo: #{msg}"

  def inspect_reason({:pdftotext_failed, page, code, msg}),
    do: "pdftotext failed on page #{page} (exit #{inspect(code)}): #{msg}"

  def inspect_reason({:insert_page_failed, page, _cs}),
    do: "could not insert page #{page} (DB error)"

  def inspect_reason({:all_pages_failed, summary}),
    do: "all pages failed (#{summary})"

  def inspect_reason(other), do: inspect(other)
end
