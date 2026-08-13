import 'dart:convert';
import 'dart:math' as math;

/// Shared reasoning payload types + serialization for the generation
/// pipeline. Owned by the GenerationEngine (ADR-0028); the page pipeline
/// (`StreamController`) re-exports these so both surfaces persist and restore
/// the SAME payload format.
///
/// Payload v2 shape (serialized via [serializeReasoningSegmentsWithSplits]):
/// ```
/// {'v': 2, 'segments': [...], 'contentSplits': {offsets, reasoningCounts, toolCounts}}
/// ```

/// Mutable reasoning state for one assistant message.
class ReasoningData {
  String text = '';
  DateTime? startAt;
  DateTime? finishedAt;
  bool expanded = false;
}

/// Reasoning segment data (for interleaved thinking/tool display).
class ReasoningSegmentData {
  String text = '';
  DateTime? startAt;
  DateTime? finishedAt;
  bool expanded = true;
  int toolStartIndex = 0;
}

/// Content-split metadata: at each content offset, how many reasoning
/// segments and tool parts precede it.
class ContentSplitData {
  const ContentSplitData({
    required this.offsets,
    required this.reasoningCounts,
    required this.toolCounts,
  });

  final List<int> offsets;
  final List<int> reasoningCounts;
  final List<int> toolCounts;
}

/// Serializes reasoning segments + content-split boundaries (v2 payload) so
/// the message rendering can rebuild interleaved thinking→content→tool
/// rendering, collapse state, duration and the loading/finished animation
/// flags. Top-level serializer shared by the page streaming pipeline AND the
/// GenerationEngine (single source for the payload format).
String serializeReasoningSegmentsWithSplits(
  List<ReasoningSegmentData> segments, {
  List<int>? contentSplitOffsets,
  List<int>? reasoningCountAtSplit,
  List<int>? toolCountAtSplit,
  dynamic reasoningDetails,
}) {
  final list = segments
      .map(
        (s) => {
          'text': s.text,
          'startAt': s.startAt?.toIso8601String(),
          'finishedAt': s.finishedAt?.toIso8601String(),
          'expanded': s.expanded,
          'toolStartIndex': s.toolStartIndex,
        },
      )
      .toList();

  if (contentSplitOffsets == null &&
      reasoningCountAtSplit == null &&
      toolCountAtSplit == null &&
      reasoningDetails == null) {
    return jsonEncode(list);
  }

  final length = math.min(
    (contentSplitOffsets ?? const <int>[]).length,
    math.min(
      (reasoningCountAtSplit ?? const <int>[]).length,
      (toolCountAtSplit ?? const <int>[]).length,
    ),
  );
  final normalized = ContentSplitData(
    offsets: List<int>.of((contentSplitOffsets ?? const <int>[]).take(length)),
    reasoningCounts: List<int>.of(
      (reasoningCountAtSplit ?? const <int>[]).take(length),
    ),
    toolCounts: List<int>.of((toolCountAtSplit ?? const <int>[]).take(length)),
  );

  return jsonEncode({
    'v': 2,
    'segments': list,
    'contentSplits': {
      'offsets': normalized.offsets,
      'reasoningCounts': normalized.reasoningCounts,
      'toolCounts': normalized.toolCounts,
    },
    if (reasoningDetails != null) 'reasoningDetails': reasoningDetails,
  });
}

/// JSON helpers for the reasoning payload (kept behind one entry point so the
/// hand-rolled encoder/decoder of the page pipeline can be replaced without
/// touching call sites).
String encodeReasoningJson(dynamic obj) => jsonEncode(obj);

dynamic decodeReasoningJson(String json) => jsonDecode(json);

/// Deduplicate raw persisted tool events.
///
/// A completed event (non-empty `content`) supersedes earlier pending entries
/// with the same id (or same name+args when id is empty). First-seen order is
/// preserved.
List<Map<String, dynamic>> dedupeToolEvents(List<Map<String, dynamic>> events) {
  final completedIds = <String>{
    for (final e in events)
      if ((e['id']?.toString() ?? '').trim().isNotEmpty &&
          _hasToolContent(e['content']?.toString()))
        (e['id']?.toString() ?? '').trim(),
  };
  final completedNoIdBases = <String>{
    for (final e in events)
      if ((e['id']?.toString() ?? '').trim().isEmpty &&
          _hasToolContent(e['content']?.toString()))
        _toolDedupeBase(
          e['name']?.toString() ?? '',
          (e['arguments'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{},
        ),
  };
  final indexByKey = <String, int>{};
  final out = <Map<String, dynamic>>[];
  for (final e in events) {
    final id = (e['id']?.toString() ?? '').trim();
    final name = (e['name']?.toString() ?? '');
    final args =
        ((e['arguments'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{});
    if (!_hasToolContent(e['content']?.toString()) &&
        ((id.isNotEmpty && completedIds.contains(id)) ||
            (id.isEmpty &&
                completedNoIdBases.contains(_toolDedupeBase(name, args))))) {
      continue;
    }
    final key = _toolDedupeKey(
      id: id,
      name: name,
      arguments: args,
      content: e['content']?.toString(),
    );
    final normalizedEvent = e.map((k, v) => MapEntry(k.toString(), v));
    final existingIndex = indexByKey[key];
    if (existingIndex != null) {
      if (id.isNotEmpty) out[existingIndex] = normalizedEvent;
      continue;
    }
    indexByKey[key] = out.length;
    out.add(normalizedEvent);
  }
  return out;
}

String _toolDedupeBase(String name, Map<String, dynamic> arguments) {
  return 'name:$name|args:${jsonEncode(arguments)}';
}

bool _hasToolContent(String? content) => content?.trim().isNotEmpty == true;

String _toolDedupeKey({
  required String id,
  required String name,
  required Map<String, dynamic> arguments,
  String? content,
}) {
  final trimmedId = id.trim();
  if (trimmedId.isNotEmpty) return 'id:$trimmedId';

  final base = _toolDedupeBase(name, arguments);
  final trimmedContent = content?.trim();
  if (trimmedContent == null || trimmedContent.isEmpty) return base;
  return '$base|content:$trimmedContent';
}
