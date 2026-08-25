import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web viewport stops scrolling through every supported native bridge', () {
    final source = File(
      'lib/features/home/webview/web_conversation_viewport.dart',
    ).readAsStringSync();

    expect(source, contains('onPointerDown'));
    expect(source, contains('window.CuplivoWeb?.stopScrolling?.();'));
    expect(source, contains('_windowsController?.executeScript'));
    expect(source, contains('_androidController?.runJavaScript'));
    expect(source, contains('_flutterController?.runJavaScript'));
  });

  test('HomePage assigns the Flutter-owned background mode to Web snapshots', () {
    final source = File('lib/features/home/pages/home_page.dart').readAsStringSync();

    expect(source, contains("'backgroundOwner': 'flutter'"));
  });
}
