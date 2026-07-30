# Deletion Recovery: Two-Table Split (deleted_records + deletion_markers)

Split deletion tracking into two Drift tables with disjoint responsibilities:
`deleted_records` (`DeletedRecordRows`) holds recoverable payloads (JSON bundles)
for local restore, subject to a 10 MB user-configurable cap; `deletion_markers`
(`DeletionMarkerRows`) holds id-only tombstones for sync/backup, with an `origin`
column ('local'/'remote') to avoid echo, subject to a unified 5000-row FIFO cap.
A single-table variant discriminated by `recoveryJson IS NULL` was rejected
because backup exclusion would silently make local trash unrecoverable after
overwrite restore, and the NULL flag conflates "no payload (remote marker)"
with "never wrote payload" semantics. A three-table variant was also considered
and collapsed into the two-table design because tombstones and remote markers
are structurally identical (id + type + timestamp, no payload) and a single
`origin` column cleanly prevents sync echo without doubling the table count.

## Considered Options

1. **One table, `recoveryJson IS NULL` flag** (original draft) — rejected: backup
   exclusion rule makes local trash unrecoverable after overwrite restore; NULL
   double-semantics.
2. **One table, explicit `kind` column** — rejected: 12 of 13 write sites are
   single-entity call sites where `kind` is redundant; forces artificial `switch`
   branches in read/backup paths that today iterate homogeneous lists.
3. **Three tables** (deleted_records + remote_deletion_markers + deletion_tombstones)
   — collapsed: tombstones and remote markers are structurally identical; `origin`
   column on one table achieves echo avoidance with one fewer table.
4. **Two tables** (accepted): `deleted_records` (payload, 10 MB cap, not backed up)
   + `deletion_markers` (id only, origin column, 5000-row FIFO, exported as
   deleted.json).

## Consequences

- Backup export gets structural exclusion for free — export never queries
  `deleted_records` or `deletion_markers`, so no per-column allowlist or
  SharedPreferences skip-list is needed.
- `deleted.json` is a new optional file in both LAN sync round-2 zip and backup
  zip. Absent in old-format payloads → receiver treats as "no deletions
  declared" (backward compatible, no protocol field bump).
- Schema version bumps from 9 to 10; migration uses `Migrator.createTable`
  (precedent at `from < 2`).