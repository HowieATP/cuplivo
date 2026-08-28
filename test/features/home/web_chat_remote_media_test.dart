import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:Cuplivo/features/home/webview/web_chat_protocol.dart';
import 'package:Cuplivo/features/home/webview/web_chat_remote_media.dart';

void main() {
  test('accepts an allowlisted image response at the size boundary', () async {
    final client = _FakeClient(
      response: http.StreamedResponse(
        Stream<List<int>>.value(<int>[1, 2, 3, 4]),
        200,
        contentLength: 4,
        headers: const <String, String>{
          'content-type': 'image/png; charset=binary',
        },
      ),
    );
    final loader = WebChatRemoteImageLoader(
      clientFactory: () => client,
      maxBytes: 4,
    );

    final result = await loader.load('http://example.test/image.png');

    expect(result.mime, 'image/png');
    expect(result.bytes, Uint8List.fromList(<int>[1, 2, 3, 4]));
    expect(client.closed, isTrue);
  });

  test(
    'rejects invalid URLs, failures, non-images, and oversized bodies',
    () async {
      Future<void> expectRejected(
        String url,
        http.StreamedResponse response, {
        int maxBytes = 4,
      }) async {
        final loader = WebChatRemoteImageLoader(
          clientFactory: () => _FakeClient(response: response),
          maxBytes: maxBytes,
        );
        await expectLater(
          loader.load(url),
          throwsA(isA<WebChatProtocolException>()),
        );
      }

      await expectRejected(
        'file:///private/image.png',
        http.StreamedResponse(const Stream<List<int>>.empty(), 200),
      );
      await expectRejected(
        'https://example.test/image.png',
        http.StreamedResponse(const Stream<List<int>>.empty(), 404),
      );
      await expectRejected(
        'https://example.test/not-image',
        http.StreamedResponse(
          Stream<List<int>>.value(<int>[1]),
          200,
          headers: const <String, String>{'content-type': 'text/html'},
        ),
      );
      await expectRejected(
        'https://example.test/declared-large.png',
        http.StreamedResponse(
          const Stream<List<int>>.empty(),
          200,
          contentLength: 5,
          headers: const <String, String>{'content-type': 'image/png'},
        ),
      );
      await expectRejected(
        'https://example.test/streamed-large.png',
        http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            <int>[1, 2],
            <int>[3, 4, 5],
          ]),
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        ),
      );
      await expectRejected(
        'https://example.test/empty.png',
        http.StreamedResponse(
          const Stream<List<int>>.empty(),
          200,
          headers: const <String, String>{'content-type': 'image/png'},
        ),
      );
    },
  );

  test('applies one deadline to the complete response body', () async {
    final client = _FakeClient(
      response: http.StreamedResponse(
        Stream<List<int>>.periodic(
          const Duration(milliseconds: 50),
          (_) => <int>[1],
        ).take(1),
        200,
        headers: const <String, String>{'content-type': 'image/png'},
      ),
    );
    final loader = WebChatRemoteImageLoader(
      clientFactory: () => client,
      timeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      loader.load('https://example.test/slow.png'),
      throwsA(isA<TimeoutException>()),
    );
    expect(client.closed, isTrue);
  });
}

class _FakeClient extends http.BaseClient {
  _FakeClient({required this.response});

  final http.StreamedResponse response;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response;

  @override
  void close() {
    closed = true;
  }
}
