# Catalogue module — handover notes (2026-08-14)

Status of the work done by the LAISK loop team on `phoenix_kit_catalogue`, and
what is deliberately **left undone**, so the next maintainer can pick it up
without re-doing the research.

## 1. What shipped (already merged into `main`)

| PR / commit | What |
|---|---|
| #61 (`e5b851e`) | Item photo preview in the picker + product card with gallery (0.15.0) |
| `90129ae` | `photo_click` nil path + two unreachable clauses |
| #58 | Test DB name / pool size from environment |
| #57 | Missing gettext entries for the Export tab |
| #53 | Manual ordering for the catalogues index restored |

Version `0.15.0` raises the floor to **`phoenix_kit ~> 2.3`** (product card uses
`Core.Modal`, `Storage.list_files_in_scope/2` and the `PkDialog` JS hook).

### Consumer contract (important)

The thumbnail/card feature is **opt-in**: `<.item_picker photo_clickable={true}>`.
A host that opts in **must** provide a `handle_info/2` clause (or a catch-all) for
`{:item_picker_photo_click, id, %Item{}}` — the component sends it upward via
`send(self(), …)` from the LiveComponent, i.e. into the parent LiveView process.
Without a clause the click crashes that LiveView. With `photo_clickable: false`
(the default) the thumbnail still renders, just inert, and the event is guarded —
nothing is sent, so existing consumers are unaffected.

## 2. Not done — designed but not implemented

**Product attributes / characteristics (our L028).** Design is complete and
validated with the product owner; implementation was not started.
- Build on the **existing item metadata** (the "Metadata" tab of a catalogue
  item: Weight/Width/Height/Depth/Material/Finish, one string value each, blanks
  dropped on save). This is an evolution of that system, not a replacement —
  nothing existing gets removed.
- Two kinds: **fixed** (single value; shown in the exported product card only)
  and **multi** (several values; one is picked per order line, first is default).
- The *set* of available characteristics is defined on the **product card**; the
  *values* are chosen next to the order line, per item, and only appear after a
  product is picked and only if characteristics are configured for it.
- Values do not affect price for now; price modifiers are a possible future,
  so don't hard-code an assumption either way.
- **Names and values are both translatable**, and each characteristic and value
  must carry a **stable internal key** separate from the translated display text,
  so editing a translation never changes what old orders reference.
- Origin of the itch: catalogues imported from PRO100 contain pseudo-items named
  "Цвет"/"Кантик"/"Толщина" mixed in with real products; staff also add such rows
  by hand. Migrating that legacy data into characteristics is a **separate** task,
  deliberately out of scope of the first implementation.

**Bring the module's forms up to PhoenixKit component standards (our L029).**
Draft only. Use the `phoenixkit-components` skill; prefer the kit's components
over raw daisyUI classes (they wire `phx-feedback`, gettext, prefix-safe links).

## 3. Known issues carried over (P2, non-blocking)

- **Spectator-host staleness**: a host that reassigns `selected_item` while
  rendering its *own* extra copy of the card can show stale content. The
  picker-owned card auto-dismisses on selection change, so this only affects a
  host that renders its own card off the upward message.
- **Locale sourcing**: display strings mix the `locale` parameter (name and
  description translations) with process `Gettext` (field labels). Consistent in
  practice, but two sources of truth.
- **Template indentation**: the L026 flex wrapper left the input block
  under-indented (HEEX-insignificant, formatter-accepted).
- **Pre-existing test failures on `main`** (3, unrelated to the above): two URL
  state tests in `CatalogueDetailLiveTest` (`?q=` / empty `?category=`) and the
  DnD reorder persistence test in `CataloguesLiveTest`.

## 4. Notes on this repo's conventions we had to learn the hard way

- **Gettext is maintained by hand here.** Do not run extract/merge — it would
  drop the existing translations. Add `msgid`/`msgstr` entries manually to
  `default.pot` and all locale `.po` files, and check for duplicate `msgid`s
  (a duplicate breaks the parser).
- The core-pin conformance test enforces the *shape* of the `phoenix_kit`
  requirement (two-segment, no minor narrowing), not a specific version — when
  the floor moves, move the test's floor with it rather than reverting the pin.
- When a host app consumes this module via a `path:` dependency, note the
  minimum version in a comment next to it: reverting to an older hex release
  silently drops `photo_clickable` (undefined attribute → fails builds that treat
  warnings as errors) and the previews quietly disappear.
