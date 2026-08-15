# Folders, categories, and the document model

**Date:** 2026-08-15 · **Status:** agreed direction (product owner via Max)

## The model

A **catalogue is a document** — the long-term goal is that any catalogue can be
rendered to a **PDF**. Everything else falls out of that:

```
Folders          →  the file explorer around the documents (admin-only)
  Catalogues     →  the documents themselves (one catalogue = one future PDF)
    Categories   →  the document's sections/chapters (ordered, translated)
      Items      →  the content inside a section
```

Example from the product owner: a folder for "Estonian stuff", inside it a
folder for "Tables", and inside that the actual catalogues.

A third namesake exists and is unrelated: **media folders** (core storage) —
each item/catalogue has a `files_folder_uuid` home folder for its attachments.
Name collision only; it never interacts with the two hierarchies above.

## Why the two hierarchies are opposites, not duplicates

| | Catalogue folders | Categories |
|---|---|---|
| Metaphor | Shelves / directories | Chapters of a document |
| Scope | Global across the module | Inside one catalogue |
| Translated | No (plain `name`) | Yes (multilang JSONB + AI translate) |
| In exports/imports | Never | Yes — category position drives export order |
| Audience | Admins organizing their workspace | Ships with the product |
| Trash semantics | Catalogues orphan-promote; nothing user-facing changes | Product-data consequences |

The code already encodes the metaphor: `export.ex` walks catalogue → category
*position* → item *position* — chapter order is page order. Folders appear in
no export path.

## Consequences for the UI (when the parked folder work resumes)

1. **The index is a file manager.** The media-library idiom (folder sidebar,
   tree-table, drag-to-file/nest) is the correct reference, and the explorer
   **stops at the catalogue row** — a file explorer does not expand into a
   document; you open it. No mixed view ever shows folder rows and category
   rows together.
2. **The detail page is a document editor.** Presenting categories as a
   collapsible tree is not "folders again" — it is the document's **outline /
   table of contents** (a PDF bookmarks panel). Manual ordering is the primary
   order there because section order is literally page order.
3. **Folders stay untranslated and unexported.** If they ever become visible
   outside the admin, that changes their nature and needs a deliberate
   product decision first.
4. **Uncategorized items** are content before any chapter. Where they land in
   a rendered PDF (front matter vs. implicit first section) is an open product
   question for whenever the PDF export is built — nothing to build now.
5. A future **catalogue → PDF export** is another destination in the existing
   export family that renders chapters; the structure already supports it.

## Status of the parked implementation

The June flatten removed the original inline folder tree; the 2026-08-15
experiments (FolderExplorer sidebar, MediaDragDrop wiring, tree-table view)
were built, verified, then parked by product call pending time to fine-tune.
Reusable pieces live in core (`Core.TreeTable`, FolderExplorer `class` attr);
the module-side integration exists in this repo's history (see the
"Roll the catalogues index back to the flat table" commit and its parents)
and can be revived with a revert plus polish rather than a rebuild.
