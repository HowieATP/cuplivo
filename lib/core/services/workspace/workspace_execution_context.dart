import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/assistant.dart';
import '../../models/conversation.dart';
import '../../models/workspace.dart';
import '../../providers/workspace_provider.dart';

class WorkspacePathException implements Exception {
  const WorkspacePathException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Stable error code surfaced when project AGENTS.md instructions cannot be
/// loaded safely for a generation request.
const String workspaceAgentsMdLoadErrorCode = 'workspace_agents_md_load_failed';

class WorkspaceAgentsMdLoadException implements Exception {
  const WorkspaceAgentsMdLoadException(this.message);

  final String message;

  @override
  String toString() => workspaceAgentsMdLoadErrorCode;
}

/// Immutable workspace state captured for one model generation.
class WorkspaceExecutionContext {
  const WorkspaceExecutionContext({
    required this.workspace,
    required this.workingDirectory,
  });

  final Workspace workspace;
  final String workingDirectory;

  static WorkspaceExecutionContext? resolve({
    required Assistant? assistant,
    required Conversation? conversation,
    required WorkspaceProvider workspaces,
  }) {
    if (assistant == null || !assistant.workspaceEnabled) return null;
    final workspaceId = assistant.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return null;
    final workspace = workspaces.getById(workspaceId);
    if (workspace == null) return null;
    final configured = effectiveWorkspaceDirectory(
      assistant: assistant,
      conversation: conversation,
      workspaceId: workspaceId,
    );
    return WorkspaceExecutionContext(
      workspace: workspace,
      workingDirectory: configured,
    );
  }
}

String effectiveWorkspaceDirectory({
  required Assistant assistant,
  required Conversation? conversation,
  required String workspaceId,
}) {
  return normalizeWorkspaceDirectory(
    conversation?.workspaceDirectoryOverrides[workspaceId] ??
        assistant.workspaceDefaultDirectories[workspaceId] ??
        '/workspace',
  );
}

/// Normalizes a saved directory to the portable guest `/workspace/...` form.
/// Relative input is interpreted from the workspace root.
String normalizeWorkspaceDirectory(String raw) {
  return resolveWorkspaceGuestPath(
    raw,
    baseDirectory: '/workspace',
    allowMountListingRoot: false,
  );
}

/// Resolves a model path using standard cwd semantics without allowing it to
/// escape the bound workspace.
String resolveWorkspaceGuestPath(
  String raw, {
  required String baseDirectory,
  bool allowMountListingRoot = true,
  bool preserveTrailingSlash = false,
}) {
  if (raw.trim() != raw) {
    throw WorkspacePathException(
      'Leading or trailing whitespace is not allowed: $raw',
    );
  }
  if (raw.isEmpty) {
    throw const WorkspacePathException('Path is required.');
  }
  if (raw.contains(r'\')) {
    throw const WorkspacePathException(
      'Backslashes are not allowed in workspace paths.',
    );
  }
  if (allowMountListingRoot && raw == '/') return '/';
  final hasTrailingSlash =
      preserveTrailingSlash && raw.length > 1 && raw.endsWith('/');
  final input = hasTrailingSlash ? raw.substring(0, raw.length - 1) : raw;
  if (RegExp(r'^[A-Za-z]:').hasMatch(input)) {
    throw WorkspacePathException(
      'Host absolute paths are not allowed in a workspace: $raw',
    );
  }
  if (input.startsWith('@')) {
    throw WorkspacePathException(
      'Use /workspace/rel/path instead of a mount alias: $raw',
    );
  }

  final base = _workspaceSegments(baseDirectory, allowRelative: false);
  final List<String> segments;
  if (input == '/workspace') {
    segments = <String>[];
  } else if (input.startsWith('/workspace/')) {
    segments = <String>[];
    _appendNormalized(segments, input.substring('/workspace/'.length), raw);
  } else if (input.startsWith('/')) {
    throw WorkspacePathException(
      'Only absolute paths under /workspace are allowed: $raw',
    );
  } else {
    segments = List<String>.of(base);
    _appendNormalized(segments, input, raw);
  }

  final resolved = segments.isEmpty
      ? '/workspace'
      : '/workspace/${segments.join('/')}';
  return hasTrailingSlash ? '$resolved/' : resolved;
}

List<String> _workspaceSegments(String raw, {required bool allowRelative}) {
  if (raw == '/workspace') return <String>[];
  if (!raw.startsWith('/workspace/')) {
    if (!allowRelative) {
      throw WorkspacePathException('Invalid workspace directory: $raw');
    }
    final out = <String>[];
    _appendNormalized(out, raw, raw);
    return out;
  }
  final out = <String>[];
  _appendNormalized(out, raw.substring('/workspace/'.length), raw);
  return out;
}

void _appendNormalized(List<String> target, String relative, String original) {
  final parts = relative.split('/');
  for (var i = 0; i < parts.length; i++) {
    final segment = parts[i];
    if (segment.isEmpty) {
      throw WorkspacePathException(
        'Empty path segment is not allowed: $original',
      );
    }
    if (segment == '.') continue;
    if (segment == '..') {
      if (target.isEmpty) {
        throw WorkspacePathException(
          'Path escapes the workspace root: $original',
        );
      }
      target.removeLast();
      continue;
    }
    if (segment.endsWith(' ') ||
        segment.endsWith('.') ||
        RegExp(r'^\.+$').hasMatch(segment) ||
        segment.contains(':') ||
        segment.contains('\u0000')) {
      throw WorkspacePathException('Unsafe workspace path segment: $original');
    }
    target.add(segment);
  }
}

/// Ensures the configured working directory exists and returns its host path.
Future<String> ensureWorkspaceWorkingDirectory({
  required WorkspaceExecutionContext context,
  required WorkspaceProvider workspaces,
}) async {
  final hostRoot = workspaces.hostPathFor(context.workspace);
  if (hostRoot == null || hostRoot.isEmpty) {
    throw const WorkspacePathException('Workspace host path is not ready.');
  }
  return ensureWorkspaceDirectoryAtHostRoot(
    workspace: context.workspace,
    hostRoot: hostRoot,
    workingDirectory: context.workingDirectory,
  );
}

Future<String> ensureWorkspaceDirectoryAtHostRoot({
  required Workspace workspace,
  required String hostRoot,
  required String workingDirectory,
}) async {
  final segments = _workspaceSegments(workingDirectory, allowRelative: false);
  final root = Directory(hostRoot);
  if (!await root.exists()) {
    if (workspace.readOnly) {
      throw const WorkspacePathException(
        'The workspace root is missing and the workspace is read-only.',
      );
    }
    try {
      await root.create(recursive: true);
    } on FileSystemException catch (error) {
      throw WorkspacePathException(
        'Unable to create the workspace root: ${error.message}',
      );
    }
  }

  final canonicalRoot = await _resolveDirectoryLinks(
    root,
    description: 'workspace root',
  );
  var current = canonicalRoot;
  for (final segment in segments) {
    current = p.join(current, segment);
    var type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const WorkspacePathException(
        'Symbolic links are not allowed in workspace working directories.',
      );
    }
    if (type == FileSystemEntityType.notFound) {
      if (workspace.readOnly) {
        throw const WorkspacePathException(
          'The working directory is missing and the workspace is read-only.',
        );
      }
      try {
        // Create one level at a time so an existing link cannot be traversed
        // by a recursive mkdir before it has been checked.
        await Directory(current).create();
      } on FileSystemException catch (error) {
        throw WorkspacePathException(
          'Unable to create the workspace working directory: '
          '${error.message}',
        );
      }
      type = await FileSystemEntity.type(current, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw const WorkspacePathException(
        'The workspace working directory contains a non-directory entry.',
      );
    }
  }

  final target = Directory(current);
  final canonicalTarget = await _resolveDirectoryLinks(
    target,
    description: 'workspace working directory',
  );
  if (!p.equals(canonicalRoot, canonicalTarget) &&
      !p.isWithin(canonicalRoot, canonicalTarget)) {
    throw const WorkspacePathException(
      'The workspace working directory escapes the workspace root.',
    );
  }
  return canonicalTarget;
}

/// Loads all project-level AGENTS.md files from [context.workingDirectory]
/// upward through the workspace root, closest directory first.
///
/// The returned prompt uses guest paths only. AGENTS.md files must resolve to
/// regular files inside the workspace root; this prevents a project symlink
/// from causing unrelated host data to be sent to the model provider.
Future<String?> loadWorkspaceAgentsMdInstructions({
  required WorkspaceExecutionContext context,
  required WorkspaceProvider workspaces,
}) async {
  try {
    final hostRoot = workspaces.hostPathFor(context.workspace);
    if (hostRoot == null || hostRoot.isEmpty) {
      throw const WorkspaceAgentsMdLoadException(
        'Workspace host path is not ready.',
      );
    }

    final canonicalRoot = await _resolveDirectoryLinks(
      Directory(hostRoot),
      description: 'workspace root',
    );
    final segments = _workspaceSegments(
      context.workingDirectory,
      allowRelative: false,
    );
    final workingDirectory = Directory(
      p.joinAll(<String>[canonicalRoot, ...segments]),
    );
    if (await FileSystemEntity.type(workingDirectory.path) !=
        FileSystemEntityType.directory) {
      throw const WorkspaceAgentsMdLoadException(
        'The workspace working directory no longer exists.',
      );
    }
    final canonicalWorkingDirectory = await _resolveDirectoryLinks(
      workingDirectory,
      description: 'workspace working directory',
    );
    if (!p.equals(canonicalRoot, canonicalWorkingDirectory) &&
        !p.isWithin(canonicalRoot, canonicalWorkingDirectory)) {
      throw const WorkspaceAgentsMdLoadException(
        'The workspace working directory escapes the workspace root.',
      );
    }

    final instructions = <String>[];
    var current = canonicalWorkingDirectory;
    while (true) {
      final candidatePath = p.join(current, 'AGENTS.md');
      final candidateType = await FileSystemEntity.type(
        candidatePath,
        followLinks: false,
      );
      if (candidateType != FileSystemEntityType.notFound) {
        if (candidateType != FileSystemEntityType.file &&
            candidateType != FileSystemEntityType.link) {
          throw WorkspaceAgentsMdLoadException(
            'AGENTS.md is not a file: ${_guestDirectoryPath(canonicalRoot, current)}',
          );
        }

        final file = File(candidatePath);
        final canonicalFile = p.normalize(await file.resolveSymbolicLinks());
        if (!p.isWithin(canonicalRoot, canonicalFile) ||
            await FileSystemEntity.type(canonicalFile, followLinks: false) !=
                FileSystemEntityType.file) {
          throw WorkspaceAgentsMdLoadException(
            'AGENTS.md resolves outside the workspace root: '
            '${_guestDirectoryPath(canonicalRoot, current)}',
          );
        }

        final content = await file.readAsString();
        instructions.add(
          'Instructions from: '
          '${_guestDirectoryPath(canonicalRoot, current)}/AGENTS.md\n$content',
        );
      }

      if (p.equals(current, canonicalRoot)) break;
      final parent = p.dirname(current);
      if (!p.equals(parent, canonicalRoot) &&
          !p.isWithin(canonicalRoot, parent)) {
        throw const WorkspaceAgentsMdLoadException(
          'Instruction discovery escaped the workspace root.',
        );
      }
      current = parent;
    }

    return instructions.isEmpty ? null : instructions.join('\n\n');
  } on WorkspaceAgentsMdLoadException {
    rethrow;
  } on WorkspacePathException catch (error) {
    throw WorkspaceAgentsMdLoadException(
      'Unable to resolve the workspace for AGENTS.md loading: '
      '${error.message}',
    );
  } on FileSystemException catch (error) {
    throw WorkspaceAgentsMdLoadException(
      'Unable to load workspace AGENTS.md instructions: ${error.message}',
    );
  }
}

String _guestDirectoryPath(String canonicalRoot, String directory) {
  final relative = p.relative(directory, from: canonicalRoot);
  if (relative == '.' || relative.isEmpty) return '/workspace';
  return '/workspace/${relative.replaceAll('\\', '/')}';
}

Future<String> _resolveDirectoryLinks(
  Directory directory, {
  required String description,
}) async {
  try {
    return p.normalize(await directory.resolveSymbolicLinks());
  } on FileSystemException catch (error) {
    throw WorkspacePathException(
      'Unable to resolve the $description: ${error.message}',
    );
  }
}
