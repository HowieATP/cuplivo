/// Thrown when a restore target is an upstream Kelivo v2 backup
/// (`manifest.json` + `database/kelivo.db` payload, no `chats.json`).
///
/// This build cannot import that format — a silent success would restore
/// nothing. The UI catches this type and redirects the user to the
/// kelivo-helper compat page to downgrade the backup first.
class KelivoV2BackupException implements Exception {
  const KelivoV2BackupException();

  @override
  String toString() => 'KelivoV2BackupException';
}
