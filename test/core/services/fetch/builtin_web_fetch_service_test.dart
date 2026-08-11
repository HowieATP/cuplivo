import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/fetch/builtin_web_fetch_service.dart';
import 'package:Cuplivo/core/services/fetch/web_fetch_content.dart';
import 'package:Cuplivo/core/services/fetch/web_fetch_target_guard.dart';

void main() {
  group('Built-in web fetch service', () {
    late HttpServer httpServer;
    late Uri baseUri;

    setUp(() async {
      WebFetchTargetGuard.blockPrivateTargets = false;
      addTearDown(() => WebFetchTargetGuard.blockPrivateTargets = true);
      httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://127.0.0.1:${httpServer.port}');
      httpServer.listen((request) async {
        if (request.uri.path == '/json') {
          request.response.headers.contentType = ContentType.json;
          request.response.write('''
{
  "items": [
    1,
    2
  ]
}
''');
        } else if (request.uri.path == '/unicode') {
          request.response.headers.contentType = ContentType.text;
          request.response.write('😀abc');
        } else if (request.uri.path == '/no-charset.txt') {
          request.response.headers.contentType = ContentType.text;
          request.response.write('你好世界');
        } else if (request.uri.path == '/image.png') {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.write('PNGDATA-no-nul-bytes');
        } else if (request.uri.path == '/stall') {
          request.response.headers.contentType = ContentType.text;
          request.response.write('first-chunk');
          await request.response.flush();
          // Hold the response open past the client's 200 ms timeout; the
          // parked future resumes after the test's tearDown force-closes
          // the server, which dart:io absorbs without an unhandled error.
          await Future<void>.delayed(const Duration(seconds: 1));
        } else if (request.uri.path == '/trickle') {
          // Slow-loris: each chunk arrives well inside the per-chunk window,
          // so only an OVERALL deadline (not per-chunk inactivity) can bound
          // the total duration of a text-mode fetch.
          request.response.headers.contentType = ContentType.text;
          for (var i = 0; i < 20; i++) {
            request.response.write('trickle-');
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await request.response.close();
        } else if (request.uri.path == '/nul-sniff.txt') {
          request.response.headers.contentType = ContentType.text;
          request.response.add(utf8.encode('BIN\u0000DATA'));
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write('''
<!doctype html>
<html>
  <head><script>SCRIPT-NOISE-${List.filled(1000, 'x').join()}</script></head>
  <body>
    <nav>NAV-NOISE-${List.filled(1000, 'y').join()}</nav>
    <main><h1>Useful title</h1><p>${List.filled(6500, 'a').join()}</p></main>
    <footer>FOOTER-NOISE</footer>
  </body>
</html>
''');
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await httpServer.close(force: true);
      BuiltInWebFetchService.textFetchTimeout = const Duration(seconds: 60);
    });

    test(
      'simplifies HTML and limits default output to 5000 characters',
      () async {
        final result = await _callFetch(baseUri.resolve('/html'));
        final text = _resultText(result);

        expect(text, contains('Useful title'));
        expect(text, isNot(contains('SCRIPT-NOISE')));
        expect(text, isNot(contains('NAV-NOISE')));
        expect(text, isNot(contains('FOOTER-NOISE')));
        expect(text, contains('start_index=5000'));
        expect(text.split('\n\n[Content truncated').first, hasLength(5000));
      },
    );

    test('continues a truncated response from start_index', () async {
      final result = await _callFetch(
        baseUri.resolve('/html'),
        arguments: const {'start_index': 5000},
      );
      final text = _resultText(result);

      expect(text, isNotEmpty);
      expect(text, isNot(contains('Content truncated')));
      expect(text, matches(RegExp(r'^a+$')));
    });

    test('requires raw opt-in and still bounds raw HTML', () async {
      final result = await _callFetch(
        baseUri.resolve('/html'),
        arguments: const {'raw': true, 'max_length': 200},
      );
      final text = _resultText(result);

      expect(text, contains('<!doctype html>'));
      expect(text, contains('SCRIPT-NOISE'));
      expect(text.split('\n\n[Content truncated').first.length, 200);
    });

    test('compacts JSON before returning it', () async {
      final result = await _callFetch(baseUri.resolve('/json'));

      expect(_resultText(result), '{"items":[1,2]}');
    });

    test('does not split Unicode surrogate pairs at a boundary', () async {
      final first = await _callFetch(
        baseUri.resolve('/unicode'),
        arguments: const {'max_length': 1},
      );
      final continued = await _callFetch(
        baseUri.resolve('/unicode'),
        arguments: const {'max_length': 3, 'start_index': 2},
      );

      expect(_resultText(first), startsWith('😀'));
      expect(_resultText(first), contains('start_index=2'));
      expect(_resultText(continued), 'abc');
    });

    test('rejects attempts to exceed the hard output limit', () async {
      final result = await _callFetch(
        baseUri.resolve('/html'),
        arguments: const {'max_length': 20001},
      );

      expect(result['isError'], isTrue);
      expect(_resultText(result), contains('Invalid max_length'));
    });

    test('binary content errors with explicit guidance', () async {
      final result = await _callFetch(baseUri.resolve('/image.png'));

      expect(result['isError'], isTrue);
      expect(_resultText(result), contains('binary'));
    });

    test('a NUL byte in the body is sniffed as binary even as text', () async {
      final result = await _callFetch(baseUri.resolve('/nul-sniff.txt'));

      expect(result['isError'], isTrue);
      expect(_resultText(result), contains('binary'));
    });

    test(
      'charset-less UTF-8 pages decode correctly instead of latin-1',
      () async {
        final result = await _callFetch(baseUri.resolve('/no-charset.txt'));

        expect(result['isError'], isFalse);
        expect(_resultText(result), '你好世界');
      },
    );

    test('a stalled text-mode fetch times out instead of hanging', () async {
      BuiltInWebFetchService.textFetchTimeout = const Duration(
        milliseconds: 200,
      );
      final result = await _callFetch(baseUri.resolve('/stall'));

      expect(result['isError'], isTrue);
      expect(_resultText(result), contains('TimeoutException'));
    });

    test(
      'a trickling text-mode fetch is bounded by the overall deadline',
      () async {
        BuiltInWebFetchService.textFetchTimeout = const Duration(
          milliseconds: 250,
        );
        final result = await _callFetch(baseUri.resolve('/trickle'));

        // Each chunk arrives within the window, so the fetch must be cut off
        // by the overall deadline rather than completing the full body.
        expect(result['isError'], isTrue);
        expect(_resultText(result), contains('TimeoutException'));
      },
    );
  });
}

Future<Map<String, dynamic>> _callFetch(
  Uri url, {
  Map<String, dynamic> arguments = const {},
}) async {
  try {
    final request = BuiltInWebFetchRequest.parse({
      'url': url.toString(),
      ...arguments,
    });
    final result = await BuiltInWebFetchService.fetch(request);
    final window = WebFetchContentWindow.fromText(
      result.content!,
      startIndex: request.startIndex,
      maxLength: request.maxLength,
    );
    var text = window.content;
    if (window.truncated) {
      text =
          '$text\n\n[Content truncated: showing characters '
          '${window.startIndex}-${window.endIndex - 1} of '
          '${window.totalLength}. Call web_fetch with '
          'start_index=${window.endIndex} to continue.]';
    }
    return _ok(text);
  } catch (e) {
    return _error(e.toString());
  }
}

Map<String, dynamic> _ok(String text) => {
  'content': [
    {'type': 'text', 'text': text},
  ],
  'isError': false,
};

Map<String, dynamic> _error(String text) => {
  'content': [
    {'type': 'text', 'text': text},
  ],
  'isError': true,
};

String _resultText(Map<String, dynamic> result) {
  final content = result['content'] as List;
  return ((content.single as Map)['text'] as String);
}
