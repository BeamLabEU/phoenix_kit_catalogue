## 0.1.2 - 2026-03-27

### Changed
- Bump Elixir requirement from ~> 1.15 to ~> 1.18 (align with sibling modules)
- Bump ex_doc from ~> 0.34 to ~> 0.39
- Update AGENTS.md: reorganize commands, add critical conventions, commit message rules, external dependencies section, and PR docs templates

## 0.1.1 - 2026-03-25

### Changed
- Remove all migration references — database and migrations are managed by the parent `phoenix_kit` project
- Add "Database & Migrations" section to README and AGENTS.md explaining where DB lives
- Remove `test.setup` and `test.reset` mix aliases (no longer needed)
- Remove test-only migration file and migration runner from test helper

## 0.1.0 - 2026-03-25

### Added
- Extract Catalogue module from PhoenixKit into standalone `phoenix_kit_catalogue` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add `Catalogue`, `Category`, `Item`, `Manufacturer`, `Supplier`, and `ManufacturerSupplier` schemas with UUIDv7 primary keys
- Add `PhoenixKitCatalogue.Catalogue` context with full CRUD for all schemas
- Add soft-delete system with cascading trash/restore for catalogues, categories, and items
- Add move operations for categories (between catalogues) and items (between categories)
- Add multilingual support for translatable fields via PhoenixKit's multilang system
- Add admin LiveViews: catalogues, categories, items, manufacturers, suppliers with forms
- Add centralized `Paths` module for route generation
- Add `css_sources/0` for Tailwind CSS scanning support
- Add behaviour compliance and catalogue context test suites
