defmodule PhoenixKitCatalogue.Catalogue.PdfLibrary do
  @moduledoc """
  PDF library — upload, extract, search.

  Layered on top of core's `phoenix_kit_files` system. The catalogue
  owns only:

    * `phoenix_kit_cat_pdfs` — per-upload row (the user-facing
      "this name in the library"). Soft-delete via
      `status` (`active` / `trashed`).
    * `phoenix_kit_cat_pdf_extractions` — per unique file content
      (one row per `file_uuid`). Holds the worker state machine.
    * `phoenix_kit_cat_pdf_pages` — per-page join.
    * `phoenix_kit_cat_pdf_page_contents` — content-addressed
      page text dedup cache.

  Core handles binary storage, content checksum dedup, multi-bucket
  redundancy, on-disk lifecycle (`Storage.trash_file/1`,
  `PruneTrashJob`).

  Public surface re-exported from `PhoenixKitCatalogue.Catalogue`.
  Activity logging follows the catalogue convention — success-only on
  the context layer.
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Utils.Multilang

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}

  alias PhoenixKitCatalogue.Schemas.{
    Item,
    Pdf,
    PdfExtraction,
    PdfPage,
    PdfPageContent
  }

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── List / read ─────────────────────────────────────────────────────

  @doc """
  Lists PDFs in the library, newest first.

  ## Options

    * `:status` — filter to a status string (`"active"` / `"trashed"`).
      Pass `nil` to include all. Defaults to `"active"`.
    * `:limit` (default 100), `:offset` (default 0)
  """
  @spec list_pdfs(keyword()) :: [Pdf.t()]
  def list_pdfs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    status = Keyword.get(opts, :status, "active")

    Pdf
    |> by_status(status)
    |> order_by([p], desc: p.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> repo().all()
    |> repo().preload(:extraction)
  end

  @doc "Returns the total PDF count, matching the optional status filter."
  @spec count_pdfs(keyword()) :: non_neg_integer()
  def count_pdfs(opts \\ []) do
    status = Keyword.get(opts, :status, "active")

    Pdf
    |> by_status(status)
    |> select([p], count(p.uuid))
    |> repo().one()
    |> Kernel.||(0)
  end

  defp by_status(query, nil), do: query
  defp by_status(query, status), do: where(query, [p], p.status == ^status)

  @doc "Fetches a PDF by UUID. Returns `nil` if not found."
  @spec get_pdf(Ecto.UUID.t()) :: Pdf.t() | nil
  def get_pdf(uuid), do: repo().get(Pdf, uuid)

  @doc "Fetches a PDF by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_pdf!(Ecto.UUID.t()) :: Pdf.t()
  def get_pdf!(uuid), do: repo().get!(Pdf, uuid)

  @doc """
  Returns the extraction state for a PDF (or its `file_uuid`), or
  `nil` if the file has no extraction row yet.
  """
  @spec get_extraction(Pdf.t() | Ecto.UUID.t()) :: PdfExtraction.t() | nil
  def get_extraction(%Pdf{file_uuid: file_uuid}), do: get_extraction(file_uuid)
  def get_extraction(file_uuid) when is_binary(file_uuid), do: repo().get(PdfExtraction, file_uuid)

  # ── Upload ──────────────────────────────────────────────────────────

  @doc """
  Stores an uploaded PDF.

  `tmp_path` is the local file from `consume_uploaded_entry`'s callback.
  `original_filename` is the user's chosen name. `byte_size` is from
  `entry.client_size`.

  Flow:

    1. `Storage.store_file/2` (core) — handles SHA-256 dedup, on-disk
       placement, multi-bucket redundancy. Same content uploaded
       twice (any name) returns the same `file_uuid`.
    2. Upsert the per-file extraction row. If newly created, enqueue
       the worker — otherwise the previous extraction is reused.
    3. Always insert a fresh `phoenix_kit_cat_pdfs` row so each
       upload gets its own per-name entry in the library.
    4. Activity action: `pdf.uploaded`. Metadata flags
       `content_dedup: true` when the file row was a hit.

  Returns `{:ok, pdf}` on success.
  """
  @spec create_pdf_from_upload(String.t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, Pdf.t()} | {:error, term()}
  def create_pdf_from_upload(tmp_path, original_filename, byte_size, opts \\ []) do
    actor_uuid = opts[:actor_uuid]

    with {:ok, file, dedup_kind} <-
           store_via_core(tmp_path, original_filename, byte_size, actor_uuid),
         {:ok, _extraction} <- ensure_extraction(file.uuid),
         {:ok, pdf} <- insert_pdf_row(file, original_filename, byte_size, dedup_kind, opts) do
      PubSub.broadcast(:pdf, pdf.uuid)
      {:ok, pdf}
    end
  end

  # Cross-user content dedup: hash the tmp file ourselves, look it up
  # by `file_checksum`, reuse if a non-trashed row already exists.
  # Otherwise hand off to `Storage.store_file/2` with the actor as
  # `user_uuid` (core requires it NOT NULL).
  defp store_via_core(tmp_path, filename, byte_size, actor_uuid) do
    file_checksum = sha256_file(tmp_path)

    case existing_active_file(file_checksum) do
      %{} = file ->
        {:ok, file, :existing}

      nil ->
        case Storage.store_file(tmp_path,
               filename: filename,
               content_type: "application/pdf",
               size_bytes: byte_size,
               user_uuid: actor_uuid
             ) do
          {:ok, %{} = file} -> {:ok, file, :new}
          {:error, reason} -> {:error, {:storage_failed, reason}}
        end
    end
  end

  defp existing_active_file(file_checksum) do
    case Storage.get_file_by_checksum(file_checksum) do
      %PhoenixKit.Modules.Storage.File{status: status} = file when status != "trashed" -> file
      _ -> nil
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!([], 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp ensure_extraction(file_uuid) do
    case repo().get(PdfExtraction, file_uuid) do
      nil ->
        case %PdfExtraction{}
             |> PdfExtraction.changeset(%{
               file_uuid: file_uuid,
               extraction_status: "pending"
             })
             |> repo().insert() do
          {:ok, extraction} ->
            enqueue_extraction(file_uuid)
            {:ok, extraction}

          {:error, _} = err ->
            err
        end

      extraction ->
        {:ok, extraction}
    end
  end

  defp insert_pdf_row(file, original_filename, byte_size, dedup_kind, opts) do
    ActivityLog.with_log(
      fn ->
        %Pdf{}
        |> Pdf.changeset(%{
          file_uuid: file.uuid,
          original_filename: original_filename,
          byte_size: byte_size
        })
        |> repo().insert()
      end,
      fn pdf ->
        %{
          action: "pdf.uploaded",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "pdf",
          resource_uuid: pdf.uuid,
          metadata: %{
            "original_filename" => pdf.original_filename,
            "byte_size" => byte_size,
            "file_uuid" => file.uuid,
            "content_dedup" => dedup_kind == :existing
          }
        }
      end
    )
  end

  # ── Trash / restore / permanent delete ──────────────────────────────

  @doc """
  Soft-deletes a PDF: flips status to `"trashed"` and records
  `trashed_at`. Underlying file + extraction + page rows untouched
  (other live PDF entries may still reference them).
  """
  @spec trash_pdf(Pdf.t(), keyword()) :: {:ok, Pdf.t()} | {:error, Ecto.Changeset.t()}
  def trash_pdf(%Pdf{} = pdf, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> pdf |> Pdf.trash_changeset() |> repo().update() end,
        fn p ->
          %{
            action: "pdf.trashed",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "pdf",
            resource_uuid: p.uuid,
            metadata: %{"original_filename" => p.original_filename}
          }
        end
      )

    with {:ok, pdf} <- result do
      PubSub.broadcast(:pdf, pdf.uuid)
      {:ok, pdf}
    end
  end

  @doc "Restores a trashed PDF back to active."
  @spec restore_pdf(Pdf.t(), keyword()) :: {:ok, Pdf.t()} | {:error, Ecto.Changeset.t()}
  def restore_pdf(%Pdf{} = pdf, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> pdf |> Pdf.restore_changeset() |> repo().update() end,
        fn p ->
          %{
            action: "pdf.restored",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "pdf",
            resource_uuid: p.uuid,
            metadata: %{"original_filename" => p.original_filename}
          }
        end
      )

    with {:ok, pdf} <- result do
      PubSub.broadcast(:pdf, pdf.uuid)
      {:ok, pdf}
    end
  end

  @doc """
  Permanently removes a `phoenix_kit_cat_pdfs` row.

  When this is the last (active OR trashed) row referencing the
  underlying `file_uuid`, hands the file off to `Storage.trash_file/1`
  so core's daily `PruneTrashJob` deletes the binary, cascading to
  the extraction and page rows.
  """
  @spec permanently_delete_pdf(Pdf.t(), keyword()) ::
          {:ok, Pdf.t()} | {:error, Ecto.Changeset.t()}
  def permanently_delete_pdf(%Pdf{} = pdf, opts \\ []) do
    file_uuid = pdf.file_uuid

    result =
      ActivityLog.with_log(
        fn -> repo().delete(pdf) end,
        fn p ->
          %{
            action: "pdf.deleted",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "pdf",
            resource_uuid: p.uuid,
            metadata: %{
              "original_filename" => p.original_filename,
              "file_uuid" => file_uuid
            }
          }
        end
      )

    with {:ok, deleted} <- result do
      maybe_handoff_underlying_file(file_uuid)
      PubSub.broadcast(:pdf, deleted.uuid)
      {:ok, deleted}
    end
  end

  defp maybe_handoff_underlying_file(file_uuid) do
    refcount =
      repo().one(
        from(p in Pdf, where: p.file_uuid == ^file_uuid, select: count(p.uuid))
      )

    if refcount == 0 do
      case Storage.get_file(file_uuid) do
        nil -> :ok
        file -> Storage.trash_file(file)
      end
    end
  end

  # ── Worker callbacks (file_uuid-keyed) ──────────────────────────────

  @doc false
  @spec mark_extracting(Ecto.UUID.t()) :: {:ok, PdfExtraction.t()} | {:error, term()}
  def mark_extracting(file_uuid) do
    update_extraction(file_uuid, %{extraction_status: "extracting"})
  end

  @doc false
  @spec insert_page(Ecto.UUID.t(), pos_integer(), String.t()) ::
          {:ok, PdfPage.t()} | {:error, Ecto.Changeset.t()}
  def insert_page(file_uuid, page_number, text) when is_integer(page_number) do
    text = text || ""
    content_hash = sha256_hex(text)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    repo().insert_all(
      PdfPageContent,
      [%{content_hash: content_hash, text: text, inserted_at: now}],
      on_conflict: :nothing,
      conflict_target: [:content_hash]
    )

    %PdfPage{}
    |> PdfPage.changeset(%{
      file_uuid: file_uuid,
      page_number: page_number,
      content_hash: content_hash,
      inserted_at: now
    })
    |> repo().insert(
      on_conflict: :nothing,
      conflict_target: [:file_uuid, :page_number]
    )
  end

  @doc false
  @spec mark_extracted(Ecto.UUID.t(), pos_integer()) ::
          {:ok, PdfExtraction.t()} | {:error, term()}
  def mark_extracted(file_uuid, page_count) when is_integer(page_count) do
    update_extraction(file_uuid, %{
      extraction_status: "extracted",
      page_count: page_count,
      extracted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error_message: nil
    })
    |> tap_log_extraction("pdf.extracted", file_uuid, %{"page_count" => page_count})
  end

  @doc false
  @spec mark_scanned_no_text(Ecto.UUID.t(), pos_integer()) ::
          {:ok, PdfExtraction.t()} | {:error, term()}
  def mark_scanned_no_text(file_uuid, page_count) when is_integer(page_count) do
    update_extraction(file_uuid, %{
      extraction_status: "scanned_no_text",
      page_count: page_count,
      extracted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error_message: nil
    })
    |> tap_log_extraction("pdf.scanned_no_text", file_uuid, %{"page_count" => page_count})
  end

  @doc false
  @spec mark_failed(Ecto.UUID.t(), String.t()) ::
          {:ok, PdfExtraction.t()} | {:error, term()}
  def mark_failed(file_uuid, error_message) do
    truncated = error_message |> to_string() |> String.slice(0, 500)

    update_extraction(file_uuid, %{
      extraction_status: "failed",
      error_message: truncated
    })
    |> tap_log_extraction("pdf.extraction_failed", file_uuid, %{"error_message" => truncated})
  end

  defp update_extraction(file_uuid, attrs) do
    case repo().get(PdfExtraction, file_uuid) do
      nil ->
        {:error, :not_found}

      extraction ->
        result =
          extraction
          |> PdfExtraction.status_changeset(attrs)
          |> repo().update()

        with {:ok, _} <- result do
          broadcast_for_file(file_uuid)
          result
        end
    end
  end

  defp broadcast_for_file(file_uuid) do
    repo().all(from p in Pdf, where: p.file_uuid == ^file_uuid, select: p.uuid)
    |> Enum.each(&PubSub.broadcast(:pdf, &1))
  end

  defp tap_log_extraction({:ok, extraction} = res, action, file_uuid, extra_metadata) do
    # Activity row per active/trashed PDF entry pointing at this file —
    # so the audit feed shows the extraction outcome alongside each
    # user-facing upload row.
    pdfs =
      repo().all(
        from(p in Pdf, where: p.file_uuid == ^file_uuid)
      )

    Enum.each(pdfs, fn pdf ->
      ActivityLog.log(%{
        action: action,
        mode: "auto",
        resource_type: "pdf",
        resource_uuid: pdf.uuid,
        metadata:
          Map.merge(
            %{
              "original_filename" => pdf.original_filename,
              "file_uuid" => file_uuid
            },
            extra_metadata
          )
      })
    end)

    _ = extraction
    res
  end

  defp tap_log_extraction(other, _, _, _), do: other

  # ── Search ──────────────────────────────────────────────────────────

  @typedoc "One PDF search hit returned to the UI."
  @type hit :: %{
          pdf: Pdf.t(),
          page_number: pos_integer(),
          snippet: String.t(),
          score: float()
        }

  @typedoc "Per-PDF group returned by `search_pdfs_for_item/2`."
  @type group :: %{
          pdf: Pdf.t(),
          total_matches: non_neg_integer(),
          hits: [hit()]
        }

  @doc """
  Searches the PDF library for any active PDF whose pages match one of
  the item's translated names.

  Returns groups keyed by PDF, each with the **total match count for
  the corpus** plus the first `:per_pdf` hits (default 5). Use
  `more_pdf_matches_for_item/3` to load additional hits within one PDF
  on demand (the "Show more matches" expand action).

  Strategy:

    1. Build the title list from the item's primary name + every
       enabled language's translated name. Drop blanks and duplicates.
    2. Literal `ILIKE ANY` against the deduped page-content table —
       fast and precise. Joined to active `phoenix_kit_cat_pdfs` rows
       via `file_uuid`. Rows are window-ranked per PDF and
       window-counted per PDF in a single SQL pass; the outer query
       caps at `rn <= per_pdf` so the result is bounded by
       `per_pdf × distinct PDFs that match`.
    3. If literal returns nothing, fall back to a `pg_trgm` similarity
       search using the longest title (default threshold 0.4) — same
       grouping shape, best similarity first within each PDF.

  Trashed PDFs are excluded. Groups are ordered newest-PDF-first.

  ## Options

    * `:per_pdf` (default 5) — preview hits returned per PDF.
    * `:similarity_threshold` (default 0.4) — trigram fallback threshold.
  """
  @spec search_pdfs_for_item(Item.t(), keyword()) :: [group()]
  def search_pdfs_for_item(%Item{} = item, opts \\ []) do
    per_pdf = Keyword.get(opts, :per_pdf, 5)
    threshold = Keyword.get(opts, :similarity_threshold, 0.4)
    titles = item_titles(item)

    cond do
      titles == [] ->
        []

      true ->
        case literal_search_grouped(titles, per_pdf) do
          [] -> trigram_search_grouped(longest(titles), threshold, per_pdf)
          groups -> groups
        end
    end
  end

  @doc """
  Loads additional hits for one PDF beyond what the initial grouped
  search returned. Used by the modal's per-PDF "Show more matches"
  expand action.

  Returns a flat list of `hit()` ordered by `page_number ASC` (literal
  search) or `similarity DESC` (when a `:trigram_query` opt is given).

  ## Options

    * `:offset` (default 0)
    * `:limit` (default 50)
    * `:trigram_query` — when set, score by `pg_trgm` similarity
      against this string (matches the trigram fallback's ordering).
  """
  @spec more_pdf_matches_for_item(Item.t(), Ecto.UUID.t(), keyword()) :: [hit()]
  def more_pdf_matches_for_item(%Item{} = item, pdf_uuid, opts \\ []) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)
    trigram_query = Keyword.get(opts, :trigram_query)
    titles = item_titles(item)

    cond do
      titles == [] ->
        []

      trigram_query ->
        trigram_more(pdf_uuid, trigram_query, titles, offset, limit)

      true ->
        literal_more(pdf_uuid, titles, offset, limit)
    end
  end

  @doc false
  def item_titles(%Item{} = item) do
    primary = [item.name]

    translated =
      if Code.ensure_loaded?(Multilang) do
        try do
          Multilang.enabled_languages()
          |> Enum.map(fn lang ->
            (item.data || %{})
            |> Multilang.get_language_data(lang)
            |> Map.get("name")
          end)
        rescue
          _ -> []
        end
      else
        []
      end

    (primary ++ translated)
    |> Enum.map(&normalize_title/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp normalize_title(nil), do: nil
  defp normalize_title(s) when is_binary(s), do: s |> String.trim() |> collapse_ws()
  defp normalize_title(_), do: nil

  defp collapse_ws(s) do
    Regex.replace(~r/\s+/u, s, " ")
  end

  defp longest([]), do: nil
  defp longest(titles), do: Enum.max_by(titles, &String.length/1)

  defp literal_search_grouped(titles, per_pdf) do
    patterns = Enum.map(titles, &("%" <> escape_like(&1) <> "%"))

    # Window-rank within each PDF + window-count to know the total
    # match count up front (so the modal can show "Show N more matches"
    # without a second query). Outer caps at `rn <= per_pdf`.
    ranked =
      from(page in PdfPage,
        join: content in PdfPageContent,
        on: content.content_hash == page.content_hash,
        join: pdf in Pdf,
        on: pdf.file_uuid == page.file_uuid,
        where: pdf.status == "active",
        where: fragment("? ILIKE ANY(?)", content.text, ^patterns),
        select: %{
          pdf_uuid: pdf.uuid,
          page_number: page.page_number,
          text: content.text,
          pdf_inserted_at: pdf.inserted_at,
          total: fragment("COUNT(*) OVER (PARTITION BY ?)", pdf.uuid),
          rn:
            fragment(
              "ROW_NUMBER() OVER (PARTITION BY ? ORDER BY ?)",
              pdf.uuid,
              page.page_number
            )
        }
      )

    rows =
      from(r in subquery(ranked),
        where: r.rn <= ^per_pdf,
        order_by: [desc: r.pdf_inserted_at, asc: r.pdf_uuid, asc: r.page_number]
      )
      |> repo().all()

    rows
    |> assemble_groups(titles, fn row -> row.text end, fn _ -> 1.0 end)
  end

  defp trigram_search_grouped(nil, _threshold, _per_pdf), do: []

  defp trigram_search_grouped(query, threshold, per_pdf) do
    ranked =
      from(page in PdfPage,
        join: content in PdfPageContent,
        on: content.content_hash == page.content_hash,
        join: pdf in Pdf,
        on: pdf.file_uuid == page.file_uuid,
        where: pdf.status == "active",
        where: fragment("similarity(?, ?) > ?", content.text, ^query, ^threshold),
        select: %{
          pdf_uuid: pdf.uuid,
          page_number: page.page_number,
          text: content.text,
          pdf_inserted_at: pdf.inserted_at,
          score: fragment("similarity(?, ?)", content.text, ^query),
          total: fragment("COUNT(*) OVER (PARTITION BY ?)", pdf.uuid),
          rn:
            fragment(
              "ROW_NUMBER() OVER (PARTITION BY ? ORDER BY similarity(?, ?) DESC)",
              pdf.uuid,
              content.text,
              ^query
            )
        }
      )

    rows =
      from(r in subquery(ranked),
        where: r.rn <= ^per_pdf,
        order_by: [desc: r.pdf_inserted_at, asc: r.pdf_uuid, asc: r.rn]
      )
      |> repo().all()

    rows
    |> assemble_groups([query], fn row -> row.text end, fn row -> row.score || 0.0 end)
  end

  # Group consecutive rows by pdf_uuid into the public group shape.
  # Rows are pre-sorted by (pdf_inserted_at DESC, pdf.uuid ASC) so
  # `chunk_by` produces one group per PDF in the correct visual order.
  defp assemble_groups(rows, titles_for_snippet, snippet_text_fn, score_fn) do
    pdfs = bulk_load_pdfs(Enum.map(rows, & &1.pdf_uuid))

    rows
    |> Enum.chunk_by(& &1.pdf_uuid)
    |> Enum.map(fn group_rows ->
      first = List.first(group_rows)
      pdf = Map.fetch!(pdfs, first.pdf_uuid)

      hits =
        Enum.map(group_rows, fn row ->
          %{
            pdf: pdf,
            page_number: row.page_number,
            snippet: snippet_for(snippet_text_fn.(row), titles_for_snippet),
            score: score_fn.(row)
          }
        end)

      %{pdf: pdf, total_matches: first.total, hits: hits}
    end)
  end

  # ── More-within-one-PDF queries (for "Show N more matches" expand) ──

  defp literal_more(pdf_uuid, titles, offset, limit) do
    patterns = Enum.map(titles, &("%" <> escape_like(&1) <> "%"))

    rows =
      from(page in PdfPage,
        join: content in PdfPageContent,
        on: content.content_hash == page.content_hash,
        join: pdf in Pdf,
        on: pdf.file_uuid == page.file_uuid,
        where: pdf.status == "active",
        where: pdf.uuid == ^pdf_uuid,
        where: fragment("? ILIKE ANY(?)", content.text, ^patterns),
        order_by: [asc: page.page_number],
        offset: ^offset,
        limit: ^limit,
        select: %{
          pdf_uuid: pdf.uuid,
          page_number: page.page_number,
          text: content.text
        }
      )
      |> repo().all()

    case rows do
      [] ->
        []

      [first | _] ->
        pdf = repo().get!(Pdf, first.pdf_uuid)

        Enum.map(rows, fn row ->
          %{
            pdf: pdf,
            page_number: row.page_number,
            snippet: snippet_for(row.text, titles),
            score: 1.0
          }
        end)
    end
  end

  defp trigram_more(pdf_uuid, query, _titles, offset, limit) do
    rows =
      from(page in PdfPage,
        join: content in PdfPageContent,
        on: content.content_hash == page.content_hash,
        join: pdf in Pdf,
        on: pdf.file_uuid == page.file_uuid,
        where: pdf.status == "active",
        where: pdf.uuid == ^pdf_uuid,
        where: fragment("similarity(?, ?) > 0", content.text, ^query),
        order_by: [
          desc: fragment("similarity(?, ?)", content.text, ^query),
          asc: page.page_number
        ],
        offset: ^offset,
        limit: ^limit,
        select: %{
          pdf_uuid: pdf.uuid,
          page_number: page.page_number,
          text: content.text,
          score: fragment("similarity(?, ?)", content.text, ^query)
        }
      )
      |> repo().all()

    case rows do
      [] ->
        []

      [first | _] ->
        pdf = repo().get!(Pdf, first.pdf_uuid)

        Enum.map(rows, fn row ->
          %{
            pdf: pdf,
            page_number: row.page_number,
            snippet: snippet_for(row.text, [query]),
            score: row.score || 0.0
          }
        end)
    end
  end

  defp bulk_load_pdfs([]), do: %{}

  defp bulk_load_pdfs(uuids) do
    unique = Enum.uniq(uuids)

    from(p in Pdf, where: p.uuid in ^unique)
    |> repo().all()
    |> Map.new(fn pdf -> {pdf.uuid, pdf} end)
  end

  defp escape_like(s) when is_binary(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp snippet_for(text, titles) when is_binary(text) and is_list(titles) do
    text = collapse_ws(text)
    downcase_text = String.downcase(text)

    case Enum.find_value(titles, fn title ->
           idx = :binary.match(downcase_text, String.downcase(title))
           if idx == :nomatch, do: nil, else: idx
         end) do
      nil ->
        String.slice(text, 0, 200)

      {start, _len} ->
        from = max(start - 60, 0)
        len = min(200, String.length(text) - from)
        String.slice(text, from, len)
    end
  end

  defp snippet_for(_, _), do: ""

  # ── Internal helpers ────────────────────────────────────────────────

  defp sha256_hex(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  @doc """
  Removes `phoenix_kit_cat_pdf_page_contents` rows that no
  `phoenix_kit_cat_pdf_pages` row references anymore. Safe to call
  any time.

  Returns the number of rows removed. Suitable for wiring to a daily
  Oban cron once the corpus is large enough to care.
  """
  @spec prune_orphan_page_contents() :: non_neg_integer()
  def prune_orphan_page_contents do
    referenced = from(p in PdfPage, select: p.content_hash, distinct: true)

    {count, _} =
      repo().delete_all(
        from(c in PdfPageContent, where: c.content_hash not in subquery(referenced))
      )

    count
  end

  defp enqueue_extraction(file_uuid) do
    if Code.ensure_loaded?(PhoenixKitCatalogue.Workers.PdfExtractor) do
      try do
        %{"file_uuid" => file_uuid}
        |> PhoenixKitCatalogue.Workers.PdfExtractor.new()
        |> Oban.insert()
      rescue
        e ->
          Logger.warning("PdfExtractor enqueue failed: #{Exception.message(e)}")
          :error
      end
    else
      :ok
    end
  end
end
