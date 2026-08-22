/// Strict guest cwd normalization for the workspace shell tool.
///
/// The model contract says the working directory is `/workspace` or a path
/// under it (relative paths resolve under `/workspace`). Both native bridges
/// (iOS CuplivoLinuxSandboxPlugin / Android LinuxSandboxPlugin) implement the
/// same rule, and this Dart helper keeps the tool layer (and its tests) in
/// sync — see issue #400.
///
/// Returns the normalized guest cwd, or `null` when the value is invalid:
/// - blank input maps to `/workspace`;
/// - an absolute path must be exactly `/workspace` or start with
///   `/workspace/` — `/workspaceX` is NOT a subpath;
/// - relative paths resolve under `/workspace` with `.` / `..` segments
///   normalized, and any traversal that escapes the workspace root
///   (e.g. `../../root`, `/workspace/../etc`) yields `null`;
/// - NUL bytes are rejected.
String? normalizeGuestCwd(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return '/workspace';
  if (trimmed.contains('\u0000')) return null;

  final String relative;
  if (trimmed == '/workspace') {
    return '/workspace';
  } else if (trimmed.startsWith('/workspace/')) {
    relative = trimmed.substring('/workspace/'.length);
  } else if (trimmed.startsWith('/')) {
    // Absolute paths outside /workspace are invalid, including lookalikes
    // such as "/workspaceX".
    return null;
  } else {
    relative = trimmed;
  }

  final segments = <String>[];
  for (final part in relative.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (segments.isEmpty) return null; // escapes /workspace
      segments.removeLast();
    } else {
      segments.add(part);
    }
  }
  return segments.isEmpty ? '/workspace' : '/workspace/${segments.join('/')}';
}
