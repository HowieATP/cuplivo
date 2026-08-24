import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/webview/web_chat_protocol.dart';

void main() {
  group('Web chat transfer protocol', () {
    test('round-trips a UTF-8 payload across bounded chunks', () {
      final payload = <String, dynamic>{
        'conversationId': '对话-1',
        'content': List<String>.filled(30, '消息内容').join(),
      };

      final chunks = chunkWebChatEnvelope(
        payload: payload,
        transferId: 'transfer-1',
        maxChunkBytes: 31,
      );

      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(
          utf8.encode(jsonEncode(chunk)).length,
          lessThanOrEqualTo(webChatMaxChunkBytes),
        );
      }
      expect(reassembleWebChatChunks(chunks), payload);
    });

    test('rejects incomplete transfers', () {
      final chunks = chunkWebChatEnvelope(
        payload: <String, dynamic>{
          'value': List<String>.filled(100, 'x').join(),
        },
        transferId: 'transfer-2',
        maxChunkBytes: 16,
      )..removeLast();

      expect(
        () => reassembleWebChatChunks(chunks),
        throwsA(isA<WebChatProtocolException>()),
      );
    });
  });

  group('Web chat action gate', () {
    test('accepts once and rejects duplicates and stale epochs', () {
      final gate = WebChatActionGate(
        renderSessionId: 'session',
        conversationId: 'conversation',
        actionEpoch: 4,
      );
      const valid = WebChatActionRequest(
        requestId: 'request',
        renderSessionId: 'session',
        conversationId: 'conversation',
        actionEpoch: 4,
        action: 'copy',
      );

      expect(gate.accept(valid), isTrue);
      expect(gate.accept(valid), isFalse);
      expect(
        gate.accept(
          const WebChatActionRequest(
            requestId: 'other',
            renderSessionId: 'session',
            conversationId: 'conversation',
            actionEpoch: 3,
            action: 'copy',
          ),
        ),
        isFalse,
      );
    });
  });
}
