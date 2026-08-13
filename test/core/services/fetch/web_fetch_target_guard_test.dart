import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:Cuplivo/core/services/fetch/builtin_web_fetch_service.dart';
import 'package:Cuplivo/core/services/fetch/readable_web_fetch_service.dart';
import 'package:Cuplivo/core/services/fetch/web_fetch_target_guard.dart';

void main() {
  group('WebFetchTargetGuard', () {
    setUp(() {
      WebFetchTargetGuard.blockPrivateTargets = true;
    });

    tearDown(() {
      WebFetchTargetGuard.blockPrivateTargets = true;
    });

    test('literal loopback and localhost are blocked', () {
      for (final host in [
        '127.0.0.1',
        '127.8.8.8',
        'localhost',
        '10.0.0.5',
        '172.16.0.1',
        '192.168.1.1',
        '169.254.169.254',
        '100.64.0.1',
        '0.0.0.0',
        '[::1]',
        '[fe80::1]',
        '[fc00::1]',
      ]) {
        final reason = WebFetchTargetGuard.literalBlockReason(
          Uri.parse('http://$host/path'),
        );
        expect(reason, isNotNull, reason: 'expected $host to be blocked');
      }
    });

    test('public hosts are allowed', () {
      for (final host in [
        'example.com',
        '8.8.8.8',
        '1.1.1.1',
        '93.184.216.34',
        '[2606:4700:4700::1111]',
      ]) {
        final reason = WebFetchTargetGuard.literalBlockReason(
          Uri.parse('https://$host/path'),
        );
        expect(reason, isNull, reason: 'expected $host to be allowed');
      }
    });

    test('IPv4-mapped IPv6 loopback is blocked', () {
      final reason = WebFetchTargetGuard.literalBlockReason(
        Uri.parse('http://[::ffff:127.0.0.1]/path'),
      );
      expect(reason, isNotNull);
    });

    test('guard disabled allows loopback (test escape hatch)', () {
      WebFetchTargetGuard.blockPrivateTargets = false;
      expect(
        WebFetchTargetGuard.literalBlockReason(
          Uri.parse('http://127.0.0.1:8080/path'),
        ),
        isNull,
      );
    });

    test('resolvedBlockReason does not hit DNS for literal IPs', () async {
      final reason = await WebFetchTargetGuard.resolvedBlockReason(
        Uri.parse('http://127.0.0.1/path'),
      );
      expect(reason, isNull); // literal path is handled by literalBlockReason
    });
  });

  group('built-in fetch SSRF blocking', () {
    late HttpServer httpServer;
    late Uri baseUri;

    setUp(() async {
      WebFetchTargetGuard.blockPrivateTargets = true;
      httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri.parse('http://127.0.0.1:${httpServer.port}');
      httpServer.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('secret internal data');
        await request.response.close();
      });
    });

    tearDown(() async {
      WebFetchTargetGuard.blockPrivateTargets = true;
      await httpServer.close(force: true);
    });

    test('text-mode fetch rejects loopback target', () async {
      final result = await _callFetch(baseUri.resolve('/secret'));
      expect(result['isError'], isTrue);
      expect(_resultText(result), contains('not an allowed web_fetch target'));
    });

    test('redirect to a blocked host is rejected mid-flight', () async {
      // First hop is a public literal IP (no DNS needed in tests); the
      // Location header points at a blocked loopback target, which must be
      // rejected before a second request is issued.
      var hops = 0;
      final client = MockClient((request) async {
        hops++;
        return http.Response(
          'Redirecting',
          302,
          headers: {'location': 'http://127.0.0.1:8080/internal'},
        );
      });

      await expectLater(
        ReadableWebFetchService.fetch(
          url: Uri.parse('http://93.184.216.34/start'),
          client: client,
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('not an allowed web_fetch target'),
          ),
        ),
      );
      expect(hops, 1);
    });
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
    return _ok(result.content ?? '');
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
