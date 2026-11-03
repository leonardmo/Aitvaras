# AitvarasStore: persistence rules

- **Migrations.** Add new migrations at the end of the chain in
  `Database.swift` as `vN-topic`, with N taken at rebase time. Never edit,
  reorder or rename a migration that is on `main`: installed profiles have
  already run it. Fix schema mistakes with a new migration.
- **UUIDs.** Never write `.uuidString` into raw SQL comparisons or inserts.
  GRDB encodes UUIDs itself, and mixing the two causes silent no-ops and FK
  failures. Use record APIs (`filter(Column(...) == id)`, `insert`, `update`).
  `ragFTS` / `factFTS` key on `.uuidString` text by design.
- **Facts are never deleted by code.** Supersede or invalidate them, and
  quarantine sensitive pipeline facts as `needsReview`. Hard deletion is only
  reachable from an explicit user action.
- **Tests.** Use `Stores(db: try AitvarasDatabase(url: nil))`, an in-memory
  database that runs the full migration chain, so every test exercises new
  migrations. Test migration upgrades by removing a row from
  `grdb_migrations` and reopening, as `migrationImportsLegacyMemoriesIntoFacts`
  does.
- `StateFixtures` (the `--seed-demo-state` persona "Alex") is fictional on
  purpose. Keep it generic: no real university, city, district, people or
  projects, and nothing modeled on the maintainer.
