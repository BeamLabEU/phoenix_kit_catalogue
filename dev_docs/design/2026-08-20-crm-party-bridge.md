# Catalogue ↔ CRM: live party resolution

**Date:** 2026-08-20
**Status:** implemented, deployed to max-dev, not released
**Implements:** phase 2 of `phoenix_kit_crm/dev_docs/design/crm_v2_parties_suppliers_clients.md`,
extended to manufacturers (which that document left out of scope, §6.6) and
diverging from it on one point (§4.5, see "What we did not do")
**Inputs:** Tymofii Shapovalov's `crm-integrity-review-2026-08-19.md`; two rounds
of external review (Codex, GLM-5.2, Devstral, Grok)

---

## The rule

**CRM owns party identity. The catalogue stores a reference and resolves it at
read time. Nothing is copied.**

"Supplier" and "manufacturer" are roles on a CRM company or contact. A
catalogue reference to either is `{source, uuid}`:

| Reference | Since |
|---|---|
| `cat_item_supplier_info.supplier_uuid` + `supplier_source` | V149 / V151 |
| `cat_items.manufacturer_uuid` + `manufacturer_source` | **V179** |

V179 dropped `phoenix_kit_cat_items_manufacturer_uuid_fkey`. That FK was why an
item's manufacturer could only ever be a local catalogue row: a party's uuid
physically could not go in the column. Manufacturers now work the way suppliers
already did.

## Why the local directory tables still exist

They are not identity any more, but they are not removable either:

- catalogue-standalone installs have no CRM at all;
- `phoenix_kit_cat_manufacturer_suppliers` has hard FKs onto the manufacturer
  row in both directions;
- `logo_url`, notes and catalogue status have no home in CRM.

A linked local row keeps `crm_company_uuid` as a cross-reference. Its job is to
join a party back to those catalogue-owned extras — **not** to cache a name.

## The move that avoided a data migration

`Suppliers.resolve/1` and `Manufacturers.resolve/1` **resolve through the
xref**: given a LOCAL uuid whose row is linked, they return the PARTY. So every
reference that already existed — junction rows, warehouse document columns —
started returning the party's current name the moment its row was linked, with
no stored uuid rewritten.

This is why CRM v2 §4.5's "rewrite `item_supplier_info.supplier_uuid` to the CRM
uuid" step is still not implemented, and should not be: `Catalogue.get_supplier/1`,
which warehouse calls, is a local primary-key lookup, and posted warehouse
documents hold local uuids. Rewriting would split brain across the junction and
every posted purchase order to buy something resolve-through already gives.

## Display

`Item` has no `belongs_to :manufacturer` — preloading an association for a CRM
uuid silently yields `nil`, which would be a blank name at every render site
rather than an error. Instead `Manufacturers.hydrate/1` runs at the query
boundary and stamps a virtual `:manufacturer_name`; the card and table cells
read that. Measured on max-dev: **25 items hydrate in 3 queries**, not 25.

`manufacturer_name_snapshot` and `supplier_name_snapshot` are TOMBSTONES. They
are read only when a reference resolves to nothing (party deleted, CRM
uninstalled, dangling uuid) so a product page can still say what it used to be.
They are never the display source. Do not add a TTL cache in front of the
resolver — that reinvents the staleness this design removed, with invalidation
on top.

## What we did not do, and why

- **No identity copy-down, no "refresh" button, no read-only fields.** The first
  version of this work copied the party's name/website/contact onto the local
  row and locked those fields. It was justified by a miscount (14 preload sites,
  when only 3 places read the name) and it created a staleness window that
  needed a human to close. All of it is gone.
- **No bulk promotion of manufacturers into CRM.** In a catalogue a
  "manufacturer" is usually a *brand*; the brand owner, the legal manufacturer
  and the supplier you buy from are frequently three different companies.
  Linking is a per-row human decision.
- **Unlink does not revoke the party role.** The role's lifecycle is CRM's, and
  the company may hold it independently of whether a catalogue row references it.

## Defects found in review, and fixed

1. **A failed role grant left a stamped xref against a party with no active
   role.** The resolvers key on the active role, so the supplier resolved to
   nothing AND was hidden as "linked" — it vanished from every picker with no
   error anywhere. Grant and stamp are now one transaction; a failed grant fails
   the link. *(Found independently by all three code reviewers.)*
2. **`list_all/1` hid every linked local row** whether or not the party came
   back. With CRM absent — a supported install — linked suppliers disappeared
   outright. It now hides a projection only when its party is genuinely in the
   list.
3. **Link/unlink used stale in-memory state.** Both are now conditioned on the
   xref they believe they are changing and return `:stale` otherwise.
4. **The company picker rendered zero options.** CRM returns `%{label:, value:}`;
   the panel matched `{name, uuid}`, and a comprehension silently drops
   non-matching elements. Found only by opening the page.

## Open questions for the product owner

- **The "documents show the CURRENT supplier name" ruling (review §B1) may be
  legally wrong for invoices.** Most jurisdictions require the name at time of
  issue on an invoice or credit note. Raised by a reviewer; not a preference
  question, so it is recorded here rather than silently implemented either way.
- **Snapshots are the one remaining stored copy.** Kept deliberately as
  degradation insurance, never displayed as authoritative. Say if you want them
  gone entirely.

## If a supplier is ever assignable to a whole catalogue

The read model on the CRM company page (`items_supplied_by/1`,
`items_manufactured_by/1`) resolves the party's own uuid AND any local row that
projects it, and returns `:item_path` so CRM renders a link without assembling
catalogue URLs itself. **A catalogue-level assignment must follow the same two
rules**: match both uuids, and hand back the path. Otherwise a supplier
attached to a whole catalogue would either be invisible on its CRM page, or
appear there with a title that is not clickable.

Practically that means a sibling `catalogues_supplied_by/1` returning
`%{catalogue_uuid, catalogue_name, catalogue_path}`, and a third section on the
tab beside Supplied items and Manufactured items — following the same rule as
those two, that a section appears when the role is held OR when rows reference
the company regardless.

## Follow-ups

1. **Warehouse is CRM-blind** and lives in a different workspace
   (`~/Desktop/Elixir/phoenix_kit_warehouse`). Its picker and its
   `resolve_supplier_name/1` both call the local-only `Catalogue.list_suppliers/0`
   / `get_supplier/1`; the CRM-aware `resolve_supplier/1` and
   `list_all_suppliers/1` are on the facade and unused. Note resolve-through
   means warehouse now shows current party names *without* any change — but it
   still cannot SELECT a CRM party.
2. **Vocabulary** (review §C1): `PartyRole.role`,
   `CompanyMembership.role_in_company`, RBAC `Role` and `crm_user_role_view`
   mean four different things, and RBAC's `Client` gates the customer portal
   independently of CRM's `customer` role.
3. **Billing ↔ CRM convergence** (owner decision B4): `billing_profiles` declares
   its own company/VAT/registration/legal-address block, zero CRM references,
   0 rows — cheap now, expensive later.
4. **An audit task for soft manufacturer references**, mirroring
   `mix phoenix_kit_catalogue.audit_supplier_refs`. Dropping the FK moved
   integrity to the application; nothing reports dangling manufacturer uuids yet.
5. **The ghost column** `cat_items.primary_supplier_uuid` (review §A4).
