# ADR 0001: Cross-module supplier references

**Status:** Accepted  
**Date:** 2026-07-14  
**Context:** V149 migration + catalogue supplier-info wave

---

## Decision

Supplier references in `phoenix_kit_cat_item_supplier_info` are **soft UUID + source + snapshot**
rather than hard foreign keys.

### Intra-module FKs (hard, enforced in DDL)

Relationships within a module (e.g. `item_uuid → cat_items`) use hard foreign keys with
`ON DELETE CASCADE`. DDL enforces referential integrity; Ecto adds a
`foreign_key_constraint/2` call to produce readable error messages.

### Cross-module references (soft UUID + source tag + name snapshot)

References that cross module boundaries — e.g. `supplier_uuid` in
`phoenix_kit_cat_item_supplier_info` pointing at a potential CRM entity — are stored as:

1. `supplier_uuid UUID NOT NULL` — the referenced entity's UUID (no FK constraint)
2. `supplier_source VARCHAR(20) NOT NULL` — discriminator: `'local'`, `'crm_company'`, `'crm_contact'`
3. `supplier_name_snapshot VARCHAR(255)` — the supplier's name at write time

**Why no FK?** The referenced entity may live in another module's schema (CRM), in a future
schema, or may be an entity the current module cannot know about at DDL time. Hard FK constraints
between modules create coupling that prevents independent module deployment and version upgrades.

**Why a source tag?** The resolver (`Suppliers.resolve/1`) must know which subsystem to query
without a round-trip. The tag is cheap to store and eliminates ambiguity.

**Why a snapshot?** Suppliers can be renamed or deleted. The snapshot preserves the display name
at transaction time so historical rows remain human-readable without joining to a potentially
absent entity.

### Guarded soft-dep for code

CRM lookups in `Catalogue.Suppliers` use runtime guards:

```elixir
Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
  function_exported?(PhoenixKitCRM.PartyRoles, :get_supplier, 1)
```

This keeps the catalogue module compilable and runnable without the CRM module — CRM is a
soft dependency that enriches the supplier list when present.

---

## Consistency audit rule

When writing a new cross-module reference:

1. Store UUID + source discriminator + name snapshot.
2. Do NOT add a DDL foreign key.
3. Add a `foreign_key_constraint/2` only for intra-module FKs.
4. Gate any code-level CRM/cross-module call behind `Code.ensure_loaded?` + `function_exported?`.
5. Run `mix phoenix_kit_catalogue.audit_supplier_refs` after bulk imports to report unresolvable UUIDs.
