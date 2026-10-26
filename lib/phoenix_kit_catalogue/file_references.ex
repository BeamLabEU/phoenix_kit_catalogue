defmodule PhoenixKitCatalogue.FileReferences do
  @moduledoc """
  The places in this module's tables that point at a stored file, for the
  orphan-file check of core's storage (`PhoenixKit.Module.file_references/0`).

  A file one of these rows names is in use and must never be read as an orphan:
  core would queue it for `DeleteOrphanedFileJob`. Each pair is a table and the
  condition "this table does not reference the file"; core leaves the pair out
  when the table does not exist.

  Moved here verbatim from core's `PhoenixKit.Modules.Storage`, which keeps its
  own copy for module versions that predate the callback. A table of this
  module that holds a file reference belongs in this list: while this module
  supplies one, core's copy of its tables steps aside.
  """

  import Ecto.Query, only: [dynamic: 2]

  @spec pairs() :: [{String.t(), Ecto.Query.dynamic_expr()}]
  def pairs do
    [
      # The catalogue module (phoenix_kit_catalogue) stores its image
      # references inside the JSONB `data` column rather than dedicated
      # columns — a plain join would miss them entirely, and a
      # live catalogue item, category, or catalogue-record image would
      # look orphaned and get queued for deletion by DeleteOrphanedFileJob.
      #
      # `media_order` is expanded into its elements and matched by equality,
      # never tested per file with `data->'media_order' @> …`: `@>` against
      # the file can't be hashed, so Postgres ran it for every file × every
      # row, unpacking each row's whole `data` every time — 8 s for 3k files
      # and 700 items on a live shop, on every media page load and folder
      # click. Expanded, the rows are read once and hash-anti-joined (0.15 s).
      # The CASE keeps a non-array `media_order` from raising, and only a
      # top-level string element matches — the same answer `@>` gave. The
      # single-file check (`file_orphaned?/1`, run by DeleteOrphanedFileJob)
      # pays for this: it expands every row too, ~5 ms instead of ~2.6 ms at
      # 700 items — a background job, against 8 s on every media page.
      {"phoenix_kit_cat_items",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_items ci WHERE ci.data->>'featured_image_uuid' = ?::text) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_items ci CROSS JOIN LATERAL jsonb_array_elements_text(CASE WHEN jsonb_typeof(ci.data->'media_order') = 'array' THEN ci.data->'media_order' ELSE '[]'::jsonb END) AS mo(file_uuid) WHERE mo.file_uuid = ?::text) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_items ci WHERE ci.data->'ecommerce'->>'file_uuid' = ?::text)",
           f.uuid,
           f.uuid,
           f.uuid
         )
       )},
      {"phoenix_kit_cat_categories",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_categories cc WHERE cc.data->>'featured_image_uuid' = ?::text) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_categories cc CROSS JOIN LATERAL jsonb_array_elements_text(CASE WHEN jsonb_typeof(cc.data->'media_order') = 'array' THEN cc.data->'media_order' ELSE '[]'::jsonb END) AS mo(file_uuid) WHERE mo.file_uuid = ?::text) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_categories cc WHERE cc.data->'ecommerce'->>'image_uuid' = ?::text)",
           f.uuid,
           f.uuid,
           f.uuid
         )
       )},
      {"phoenix_kit_cat_catalogues",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_catalogues ct WHERE ct.data->>'featured_image_uuid' = ?::text) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_catalogues ct CROSS JOIN LATERAL jsonb_array_elements_text(CASE WHEN jsonb_typeof(ct.data->'media_order') = 'array' THEN ct.data->'media_order' ELSE '[]'::jsonb END) AS mo(file_uuid) WHERE mo.file_uuid = ?::text)",
           f.uuid,
           f.uuid
         )
       )},
      # Unlike the three JSONB-backed tables above, cat_pdfs references its
      # source file through a plain NOT NULL `file_uuid` FK with
      # ON DELETE RESTRICT — the same shape as phoenix_kit_post_media. Missing
      # this entry would let DeleteOrphanedFileJob delete the physical file
      # data for a PDF still in active use, then crash on the FK-RESTRICT
      # violation while deleting the phoenix_kit_files row, leaving a
      # dangling record and a broken PDF.
      {"phoenix_kit_cat_pdfs",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_pdfs cp WHERE cp.file_uuid = ?)",
           f.uuid
         )
       )}
    ]
  end
end
