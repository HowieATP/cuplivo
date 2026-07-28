import 'dart:io' show Platform;
import 'package:path/path.dart' as p;

/// Canonicalize a file path for cross-platform equality comparison.
///
/// Used by both [ChatService] orphan cleanup and the storage-space refCount
/// lookup so the two stay in sync. If one diverges, ref counts silently break.
String canonicalizePath(String pth) {
  final normalized = p.normalize(pth);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}
