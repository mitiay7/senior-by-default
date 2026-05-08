# Zero-Downtime Migrations

The `migration_audit` specialist (Phase 3.6) MUST apply this checklist for every migration. The principle: code and schema are deployed independently, so any single migration must work with both the **previous** and **next** version of the application code running concurrently.

## Forbidden operations (in a single migration)

These break rolling deploys and old replicas. Reject and require expand-contract pattern instead:

| Operation | Why forbidden | Expand-contract pattern |
|---|---|---|
| `DROP COLUMN` | Old code reads it | (1) Stop reading in code, deploy. (2) Migration drops column |
| `DROP TABLE` | Old code reads/writes it | Same as DROP COLUMN |
| `RENAME COLUMN` | Old code uses old name | (1) Add new column. (2) Dual-write app code, deploy. (3) Backfill. (4) Switch readers, deploy. (5) Drop old column |
| `RENAME TABLE` | Same as rename column | Use synonym/view as intermediate |
| `ADD COLUMN ... NOT NULL` (no default) | Existing rows fail | (1) Add nullable. (2) Backfill. (3) Add NOT NULL constraint in separate migration |
| `ALTER COLUMN ... NOT NULL` (existing nullable) | Old data may be NULL | (1) Backfill NULLs to a sentinel/default. (2) Add NOT NULL |
| `ALTER COLUMN TYPE` (narrowing: `VARCHAR(255)` → `VARCHAR(100)`) | Existing data may overflow | (1) Validate all data fits. (2) Add new column with new type. (3) Migrate data. (4) Drop old, rename |
| `ALTER COLUMN TYPE` (incompatible: `INT` → `UUID`) | Cast may fail | Always: add new column, dual-write, migrate, switch, drop |
| `DROP INDEX` (used by old code's hot queries) | Old code's queries become slow → cascading failure | (1) Verify with EXPLAIN that no critical query uses it. (2) Drop in low-traffic window |
| `ADD UNIQUE CONSTRAINT` (existing data may violate) | Migration fails partway | (1) Validate data is unique first. (2) Apply constraint |
| Long-running `UPDATE` in migration | Locks table for minutes | Use batched updates outside migration; or `pt-online-schema-change` (MySQL) / `pg_repack` (Postgres) |
| `CREATE INDEX` without `CONCURRENTLY` (Postgres) | Locks writes | Always `CREATE INDEX CONCURRENTLY` for production-sized tables |

## Allowed in a single migration

These are safe because they're additive and old code ignores them:
- `CREATE TABLE` (new table; nothing reads it yet)
- `ADD COLUMN` (nullable, with or without default)
- `CREATE INDEX CONCURRENTLY` (Postgres) / `ALGORITHM=INPLACE, LOCK=NONE` (MySQL InnoDB online DDL)
- `CREATE INDEX` on small tables (<10K rows) where a brief lock is acceptable
- `ADD CHECK CONSTRAINT NOT VALID` then separate `VALIDATE CONSTRAINT` (Postgres)
- `CREATE OR REPLACE VIEW` / `CREATE OR REPLACE FUNCTION` (idempotent; old code keeps working if signature unchanged)
- `INSERT` / `UPDATE` of seed/reference data (small batches)

## Per-database notes

### PostgreSQL
- `ALTER TABLE` taking `ACCESS EXCLUSIVE LOCK` blocks all reads and writes — fatal for high-traffic tables. Set `lock_timeout = '5s'` in migration to fail fast rather than hang.
- `CREATE INDEX CONCURRENTLY` cannot run inside a transaction. Migration tools must support this (golang-migrate: use `-no-tx-wrap` for that file; sqlx: split file).
- Adding column with `DEFAULT` and `NOT NULL` is fast in PG11+ (metadata-only). Earlier versions: rewrites table.
- `ALTER COLUMN TYPE` may rewrite the entire table; check with `\d+`.

### MySQL
- Online DDL (`ALGORITHM=INPLACE, LOCK=NONE`) supports many alters but not all. Check the [matrix](https://dev.mysql.com/doc/refman/8.0/en/innodb-online-ddl-operations.html) per version.
- For unsupported online DDL, use `pt-online-schema-change` or `gh-ost` for non-blocking schema changes.
- `ADD COLUMN AFTER existing_column` rewrites the table — avoid; let MySQL place at end.

### SQLite
- Almost no ALTER support. Pattern: rename old table, create new with desired schema, copy data, drop old. Acceptable for SQLite use cases (typically embedded, not high-traffic).

## Migration audit specialist checklist

The auditor must mention each item with PASS/FAIL/N-A:

- [ ] No DROP/RENAME without expand-contract precursor
- [ ] No NOT NULL added without backfill + default strategy
- [ ] No type narrowing
- [ ] Indexes on tables >10K rows use CONCURRENTLY (Postgres) or online DDL (MySQL)
- [ ] No `UPDATE` of >100K rows in migration body (suggest separate batched data migration)
- [ ] Migration has `IF NOT EXISTS` guards (idempotent)
- [ ] If migration fails partway, state is recoverable (no orphaned schema between two migrations)
- [ ] Companion application code change works against BOTH pre- and post-migration schema (verified by reasoning about deploy order)
- [ ] Rollback strategy documented (either reverse migration or "roll forward only" with explanation)

Any FAIL → blocking. Suggest the expand-contract pattern from the table above.

## Expand-contract template

For a column rename (most common case requiring expand-contract):

**Migration N (expand)** — additive only:
```sql
ALTER TABLE users ADD COLUMN email_address VARCHAR(255);
-- backfill in app code or separate batched migration
```
**App code change** — dual-write to both `email` (old) and `email_address` (new); read prefers new with fallback to old. Deploy.

**Migration N+1 (backfill verify)**:
```sql
-- Run as data migration, not schema:
UPDATE users SET email_address = email WHERE email_address IS NULL;
-- Verify: SELECT COUNT(*) WHERE email_address IS NULL → must be 0
```

**App code change** — switch reads to new column only; remove old column writes. Deploy.

**Migration N+2 (contract)** — destructive:
```sql
ALTER TABLE users DROP COLUMN email;
```

This pattern requires 3 migrations + 2 deploys for one logical rename. That's the cost of zero-downtime — always cheaper than a 3am incident.

## When zero-downtime can be relaxed

- Maintenance windows announced and accepted by users
- Internal-only tools with low concurrency
- Pre-launch / staging environments
- Single-instance apps (no rolling deploy → no concurrent old-code problem)

In these cases, document the relaxation explicitly in PR description. Don't silently skip the audit.
