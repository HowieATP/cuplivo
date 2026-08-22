/// Model-facing path presentation for workspace tools.
///
/// Canonical wire paths (`@alias/rel/path`) remain the internal identity
/// format (deletion markers, backups, ADR-0022). This file translates
/// between that canonical form and the single vocabulary presented to the
/// model: `/workspace/rel/path`, where `/workspace` is the root of the
/// workspace bound to the current assistant (matches the Linux sandbox
/// shell view; filesystem tools and shell now share one vocabulary).
library;

/// Thrown when a model-supplied path does not use the `/workspace/...` form.
class ModelPathException implements Exception {
  final String message;
  ModelPathException(this.message);

  @override
  String toString() => message;
}

/// Strict input translation: the model must use `/workspace/...`; canonical
/// `@alias/...` paths and arbitrary absolute paths are rejected.
///
/// - `/` is passed through unchanged (engine special case: list mounts).
/// - `/workspace` → `@alias`; `/workspace/rel/path` → `@alias/rel/path`.
/// - External SAF mounts (Android) are addressed as
///   `/workspace/.mounts/<alias>` → `@<alias>` (see ADR-0037). The alias must
///   be a known SAF mount alias; anything else under `.mounts/` is rejected.
/// - Trailing slashes are preserved so the engine's existing validation
///   applies unchanged (read tolerates one, the other tools reject it).
/// - Segment-level validation (traversal, malformed segments) still happens
///   inside the engine against the translated canonical path.
String parseModelPath(
  String raw,
  String alias, {
  Set<String> safAliases = const <String>{},
}) {
  if (raw.trim() != raw) {
    throw ModelPathException(
      'Invalid path: leading/trailing whitespace is not allowed: $raw',
    );
  }
  if (raw.isEmpty) {
    throw ModelPathException('Invalid path: path is required');
  }
  if (raw == '/') return '/';
  if (raw.startsWith('@')) {
    throw ModelPathException(
      'Invalid path: use the /workspace/rel/path form, not $raw',
    );
  }
  if (raw != '/workspace' && !raw.startsWith('/workspace/')) {
    throw ModelPathException(
      'Invalid path: only paths under /workspace are allowed: $raw',
    );
  }
  if (raw == '/workspace') return '@$alias';
  final rest = raw.substring('/workspace/'.length);
  // External SAF mounts live under the reserved .mounts/ guest directory.
  // The path is ONLY interpreted as a mount reference; a literal workspace
  // folder named ".mounts" is shadowed by design (ADR-0037) — same
  // convention as .sandbox/.fetch_cache dotdirs.
  if (rest == '.mounts') {
    throw ModelPathException(
      'Invalid path: name a mount: /workspace/.mounts/<alias>',
    );
  }
  if (rest.startsWith('.mounts/')) {
    final seg = rest.substring('.mounts/'.length);
    final slash = seg.indexOf('/');
    final mountAlias = slash < 0 ? seg : seg.substring(0, slash);
    if (mountAlias.isEmpty) {
      throw ModelPathException(
        'Invalid path: name a mount: /workspace/.mounts/<alias>',
      );
    }
    if (!safAliases.contains(mountAlias)) {
      throw ModelPathException(
        'Invalid path: unknown mount alias: /workspace/.mounts/$mountAlias',
      );
    }
    if (slash < 0) return '@$mountAlias';
    final rel = seg.substring(slash + 1);
    return '@$mountAlias/$rel';
  }
  return '@$alias/$rest';
}

/// Canonical wire path → model-facing `/workspace/...` form.
///
/// Only the bound workspace alias is presented as `/workspace`; SAF mounts
/// present as `/workspace/.mounts/<alias>`; anything else (other mounts,
/// already-presented paths) is returned unchanged.
String presentWirePath(
  String wirePath,
  String alias, {
  Set<String> safAliases = const <String>{},
}) {
  final prefix = '@$alias';
  if (wirePath == prefix) return '/workspace';
  if (wirePath.startsWith('$prefix/')) {
    return '/workspace/${wirePath.substring(prefix.length + 1)}';
  }
  for (final saf in safAliases) {
    final safPrefix = '@$saf';
    if (wirePath == safPrefix) return '/workspace/.mounts/$saf';
    if (wirePath.startsWith('$safPrefix/')) {
      return '/workspace/.mounts/$saf/${wirePath.substring(safPrefix.length + 1)}';
    }
  }
  return wirePath;
}

/// Rewrites tool-definition copy (model-visible text only) to the
/// `/workspace` vocabulary. Tool definitions are static presentation text —
/// no file content flows through here.
String presentDefText(String text) {
  return text
      .replaceAll('@default/', '/workspace/')
      .replaceAll('@default', '/workspace')
      .replaceAll('@alias/rel/path', '/workspace/rel/path')
      .replaceAll('@alias', '/workspace')
      .replaceAll('Mount-relative', 'Workspace-relative')
      .replaceAll('mount-relative', 'workspace-relative');
}

/// Rewrites every string inside a tool-definition map (description /
/// inputSchema) with [presentDefText].
Map<String, dynamic> presentDefMap(Map<String, dynamic> def) {
  Map<String, dynamic> rewrite(Map<String, dynamic> m) => {
    for (final e in m.entries)
      e.key: e.value is Map
          ? rewrite((e.value as Map).cast<String, dynamic>())
          : e.value is String
          ? presentDefText(e.value as String)
          : e.value,
  };
  return rewrite(def);
}
