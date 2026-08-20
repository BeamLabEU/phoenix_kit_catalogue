# Catalogue ↔ CRM: the party bridge (phase 1)

**Date:** 2026-08-20
**Status:** implemented, deployed to max-dev, not released
**Implements:** phase 2 of `phoenix_kit_crm/dev_docs/design/crm_v2_parties_suppliers_clients.md`,
extended to manufacturers (which that document explicitly left out of scope, §6.6)
**Inputs:** Tymofii Shapovalov's `crm-integrity-review-2026-08-19.md` (read-only audit of
the shared Andi dev DB)

---

## What was decided

CRM is the party master. `supplier` and `manufacturer` are **roles** on a CRM
company or contact. The catalogue's `phoenix_kit_cat_suppliers` and
`phoenix_kit_cat_manufacturers` rows are **not deleted** — they become the
catalogue-side *projection* of a party, cross-referenced by `crm_company_uuid`
(V149 for suppliers, V178 for manufacturers). This is the SAP CVI transition
pattern the CRM v2 document already chose for suppliers.

Two facts force the projection to stay, and they are worth restating because
they are what makes this a *transition* rather than a finished move:

1. Catalogue-standalone installs have no CRM at all.
2. `phoenix_kit_cat_items.manufacturer_uuid` is a **hard FK** onto the local
   manufacturer row, and `belongs_to :manufacturer` is preloaded at ~14 sites
   (item lists, cards, search, import, exports). Item pages render the LOCAL
   row — no display path calls a resolver.

Consequence (2) is why linking copies the party's identity DOWN onto the
projection. A link that left the local name stale would show one name in the
CRM directory and a different one on every product page.

## What was deliberately NOT done

- **The manufacturer FK was not dropped.** Making item→manufacturer a soft
  federated reference (like item→supplier already is) means rewriting ~14
  preload sites onto a resolver path that had never executed against real
  linked data. Both the reviewing panel and the risk profile said: prove the
  projection first, and note the data is tiny enough that the conversion stays
  cheap later. **Do not ship `Manufacturers.resolve/1` as if items federate —
  they still cannot.**
- **No bulk backfill of manufacturers into CRM.** In a catalogue a
  "manufacturer" is usually a *brand*, and the brand owner, the legal
  manufacturer and the supplier you buy from are frequently three different
  companies. Auto-creating a CRM party per manufacturer row would mint false
  identities and make later dedup harder. Linking is a per-row human decision.
  (The supplier backfill task still exists, unchanged, opt-in and dry-run by
  default. It has never been run anywhere.)
- **`item_supplier_info.supplier_uuid` is NOT rewritten to CRM uuids**, despite
  CRM v2 §4.5 calling for it. `Catalogue.get_supplier/1` — which warehouse
  calls — is a local primary-key lookup, and posted warehouse documents carry
  local supplier uuids, so a rewrite splits brain across the junction AND every
  posted purchase order. If it is ever done it needs: uuid + source + snapshot
  rewritten in one transaction, an undo table, a pre-check for two locals
  mapping to one party, compare-and-swap on the expected old value, and an
  idempotent reverse task.

## The rules that hold now

| Rule | Enforced by |
|---|---|
| One party ↔ at most one projection per directory | partial unique indexes on `crm_company_uuid` (V178), both tables |
| A linked row's name/website/contact_info are CRM's | `changeset/2` refuses the edit; `crm_link_changeset/2` is the only write path |
| A linked local never appears twice in a picker | `list_all/1` excludes rows with `crm_company_uuid` set |
| The catalogue never depends on CRM | every call guarded by `Code.ensure_loaded?` + `function_exported?`; no mix dep either way |
| Unlinking does not revoke the role | the company may be a supplier whether or not this row projects it |

A supplier projection and a manufacturer projection MAY point at the same party
— that is the case the shared party table exists for.

## Known sharp edge

The catalogue does not observe CRM writes (that would need a dependency in the
wrong direction), so **a party renamed in CRM leaves the projection — and every
item page — showing the old name until someone presses "Refresh from CRM"**.
This was reproduced deliberately on max-dev. If it becomes a problem the fix is
a CRM-side hook or a periodic reconciliation task, not a live resolver on the
item display path.

## Verified on max-dev (2026-08-20)

Both modules installed, so the CRM branch actually executes — it never had
before anywhere (0 party roles existed in any environment). Confirmed end to
end: link grants the role and copies identity; one party holds both supplier
and manufacturer roles; `get_supplier` / `get_manufacturer` / `resolve_*`
return the party with `source: :crm`; `list_all` shows the party and hides the
projection; a second row linking the same party is refused; an identity edit on
a linked row is refused; unlink restores local editing. Test data was removed
afterwards.

One real bug was caught only by opening the page: CRM's `company_options/0`
returns `%{label:, value:}` maps while the panel matched `{name, uuid}` tuples,
and a comprehension silently drops non-matching elements — the picker rendered
with zero options, no error, nothing in the log.

## Follow-ups, in the order they probably matter

1. **Warehouse is CRM-blind** and lives in a different workspace
   (`~/Desktop/Elixir/phoenix_kit_warehouse`), so it was out of scope here. Its
   picker and its `resolve_supplier_name/1` both call the local-only
   `Catalogue.list_suppliers/0` / `get_supplier/1`; the CRM-aware
   `resolve_supplier/1` and `list_all_suppliers/1` are on the facade and unused.
   Note the review's claim that "the picker is CRM-aware" is false — it is
   uniformly blind, which is *safer* than the asymmetry the review described.
2. **Vocabulary** (review §C1): `PartyRole.role`, `CompanyMembership.role_in_company`,
   RBAC `Role`, and the `crm_user_role_view` table mean four different things,
   and RBAC's `Client` still gates the customer portal independently of CRM's
   `customer` role. Worth closing before more is built on top.
3. **Billing ↔ CRM convergence** (owner decision B4): `billing_profiles`
   declares its own company/VAT/registration/legal-address block with zero CRM
   references and currently 0 rows — cheap now, expensive later.
4. **The ghost column** `cat_items.primary_supplier_uuid` (review §A4): recorded
   as migrated twice, absent from the Andi database, unmapped and unread in
   code. Understand why it never landed before repairing it — and note that if
   suppliers move fully into CRM, its FK is exactly what would have to be
   removed again.
5. **Item-level manufacturer federation** — the FK drop described above.
