import 'dart:convert';
import 'dart:math';

const int webChatProtocolVersion = 2;
const String webChatAssetVersion = 'web-chat-v5';
const int webChatMaxChunkBytes = 128 * 1024;
const int webChatMaxChunkPayloadBytes = 95 * 1024;

class WebChatProtocolException implements Exception {
  const WebChatProtocolException(this.message);

  final String message;

  @override
  String toString() => 'WebChatProtocolException: $message';
}

class WebChatActionRequest {
  const WebChatActionRequest({
    required this.requestId,
    required this.renderSessionId,
    required this.conversationId,
    required this.actionEpoch,
    required this.action,
    this.messageId,
    this.payload = const <String, dynamic>{},
  });

  final String requestId;
  final String renderSessionId;
  final String conversationId;
  final int actionEpoch;
  final String action;
  final String? messageId;
  final Map<String, dynamic> payload;

  factory WebChatActionRequest.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'];
    final request = WebChatActionRequest(
      requestId: json['requestId']?.toString() ?? '',
      renderSessionId: json['renderSessionId']?.toString() ?? '',
      conversationId: json['conversationId']?.toString() ?? '',
      actionEpoch: (json['actionEpoch'] as num?)?.toInt() ?? -1,
      action: json['action']?.toString() ?? '',
      messageId: json['messageId']?.toString(),
      payload: payload is Map
          ? payload.map((key, value) => MapEntry(key.toString(), value))
          : const <String, dynamic>{},
    );
    if (request.requestId.isEmpty ||
        request.renderSessionId.isEmpty ||
        request.conversationId.isEmpty ||
        request.action.isEmpty) {
      throw const WebChatProtocolException('malformed action request');
    }
    return request;
  }
}

enum WebChatReasoningKind { single, segment }

class WebChatReasoningTarget {
  const WebChatReasoningTarget({
    required this.kind,
    required this.index,
    required this.expanded,
  });

  final WebChatReasoningKind kind;
  final int index;
  final bool expanded;

  factory WebChatReasoningTarget.fromPayload(Map<String, dynamic> payload) {
    final kind = switch (payload['kind']) {
      'single' => WebChatReasoningKind.single,
      'segment' => WebChatReasoningKind.segment,
      _ => throw const WebChatProtocolException(
        'unsupported reasoning target kind',
      ),
    };
    final rawIndex = payload['index'];
    final rawExpanded = payload['expanded'];
    if (rawIndex is! num ||
        !rawIndex.isFinite ||
        rawIndex != rawIndex.toInt() ||
        rawIndex.toInt() < 0 ||
        (kind == WebChatReasoningKind.single && rawIndex.toInt() != 0) ||
        rawExpanded is! bool) {
      throw const WebChatProtocolException('malformed reasoning target');
    }
    return WebChatReasoningTarget(
      kind: kind,
      index: rawIndex.toInt(),
      expanded: rawExpanded,
    );
  }
}

class WebChatActionGate {
  WebChatActionGate({
    required this.renderSessionId,
    required this.conversationId,
    required this.actionEpoch,
  });

  final String renderSessionId;
  final String conversationId;
  final int actionEpoch;
  final Set<String> _handledRequestIds = <String>{};

  bool accept(WebChatActionRequest request) {
    if (request.renderSessionId != renderSessionId ||
        request.conversationId != conversationId ||
        request.actionEpoch != actionEpoch) {
      return false;
    }
    return _handledRequestIds.add(request.requestId);
  }
}

List<Map<String, dynamic>> chunkWebChatEnvelope({
  required Map<String, dynamic> payload,
  required String transferId,
  int maxChunkBytes = webChatMaxChunkPayloadBytes,
}) {
  if (maxChunkBytes <= 0) {
    throw const WebChatProtocolException('maxChunkBytes must be positive');
  }
  final bytes = utf8.encode(jsonEncode(payload));
  final total = max(1, (bytes.length / maxChunkBytes).ceil());
  return <Map<String, dynamic>>[
    for (var index = 0; index < total; index++)
      <String, dynamic>{
        'type': 'transferChunk',
        'protocolVersion': webChatProtocolVersion,
        'transferId': transferId,
        'index': index,
        'total': total,
        'data': base64Encode(
          bytes.sublist(
            index * maxChunkBytes,
            min(bytes.length, (index + 1) * maxChunkBytes),
          ),
        ),
      },
  ];
}

Map<String, dynamic> reassembleWebChatChunks(
  List<Map<String, dynamic>> chunks,
) {
  if (chunks.isEmpty) {
    throw const WebChatProtocolException('empty transfer');
  }
  final sorted = List<Map<String, dynamic>>.of(chunks)
    ..sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));
  final transferId = sorted.first['transferId'];
  final total = sorted.first['total'];
  if (total is! int || total != sorted.length) {
    throw const WebChatProtocolException('incomplete transfer');
  }
  final bytes = <int>[];
  for (var index = 0; index < sorted.length; index++) {
    final chunk = sorted[index];
    if (chunk['transferId'] != transferId ||
        chunk['total'] != total ||
        chunk['index'] != index) {
      throw const WebChatProtocolException('invalid transfer sequence');
    }
    bytes.addAll(base64Decode(chunk['data'] as String));
  }
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw const WebChatProtocolException('transfer payload is not an object');
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}
