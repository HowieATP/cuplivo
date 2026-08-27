import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/shared/widgets/isolated_html_preview_document.dart';

void main() {
  test(
    'isolated preview keeps scripts interactive inside an opaque sandbox',
    () {
      const source = '''<!doctype html>
<html><body><button onclick="count += 1">Run</button>
<script>let count = 0;</script></body></html>''';

      final document = buildIsolatedHtmlPreviewDocument(source, isDark: false);

      expect(document, contains('sandbox="allow-scripts"'));
      expect(document, contains('csp="'));
      expect(document, contains('credentialless'));
      expect(document, isNot(contains('allow-same-origin')));
      expect(document, isNot(contains('allow-top-navigation')));
      expect(document, isNot(contains('allow-popups')));
      expect(document, isNot(contains('allow-forms')));
      expect(document, contains('referrerpolicy="no-referrer"'));
      expect(document, contains('srcdoc="'));
      expect(document, isNot(contains('<script>let count = 0;</script>')));
      expect(document, contains('&lt;script&gt;let count = 0;&lt;/script&gt;'));
    },
  );

  test(
    'isolated preview applies network-denying CSP inside and outside iframe',
    () {
      final document = buildIsolatedHtmlPreviewDocument(
        '<img src="https://example.test/tracker.png">',
        isDark: true,
      );

      expect(RegExp('default-src').allMatches(document).length, greaterThan(1));
      expect(RegExp('connect-src').allMatches(document).length, greaterThan(1));
      expect(document, contains('script-src'));
      expect(document, contains('frame-src'));
      expect(document, contains("object-src 'none'"));
      expect(document, contains("form-action 'none'"));
      expect(document, contains("base-uri 'none'"));
    },
  );

  test('isolated navigation accepts only non-network document schemes', () {
    expect(isAllowedIsolatedHtmlPreviewUrl('about:blank'), isTrue);
    expect(isAllowedIsolatedHtmlPreviewUrl('data:text/html,preview'), isTrue);
    expect(isAllowedIsolatedHtmlPreviewUrl('blob:https://opaque/id'), isTrue);
    expect(isAllowedIsolatedHtmlPreviewUrl('https://example.test'), isFalse);
    expect(isAllowedIsolatedHtmlPreviewUrl('http://example.test'), isFalse);
    expect(isAllowedIsolatedHtmlPreviewUrl('file:///private/secret'), isFalse);
  });
}
