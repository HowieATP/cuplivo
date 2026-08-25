import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'web viewport stops scrolling through every supported native bridge',
    () {
      final source = File(
        'lib/features/home/webview/web_conversation_viewport.dart',
      ).readAsStringSync();

      expect(source, contains('onPointerDown'));
      expect(source, contains('window.CuplivoWeb?.stopScrolling?.();'));
      expect(source, contains('_windowsController?.executeScript'));
      expect(source, contains('_androidController?.stopScrolling()'));
      expect(source, contains('_flutterController?.runJavaScript'));
    },
  );

  test(
    'HomePage assigns the Flutter-owned background mode to Web snapshots',
    () {
      final source = File(
        'lib/features/home/pages/home_page.dart',
      ).readAsStringSync();

      expect(source, contains("'backgroundOwner': 'flutter'"));
    },
  );

  test(
    'HomePage passes Flutter code-block surface tokens to Web snapshots',
    () {
      final source = File(
        'lib/features/home/pages/home_page.dart',
      ).readAsStringSync();

      expect(source, contains("'code-body'"));
      expect(source, contains("'code-header'"));
      expect(source, contains("'code-border'"));
      expect(source, contains("'code-header-text'"));
      expect(source, contains("'code-action'"));
    },
  );

  test(
    'Android WebView cancels compositor fling before the JavaScript lock',
    () {
      final nativeSource = File(
        'android/app/src/main/kotlin/com/cup11/cuplivo/AndroidWebChatView.kt',
      ).readAsStringSync();
      final controllerSource = File(
        'lib/features/home/webview/android_web_chat_view.dart',
      ).readAsStringSync();

      expect(nativeSource, contains('setOnTouchListener'));
      expect(nativeSource, contains('MotionEvent.ACTION_DOWN'));
      expect(nativeSource, contains('"stopScrolling"'));
      expect(nativeSource, contains('webView.flingScroll(0, 0)'));
      expect(nativeSource, contains('window.CuplivoWeb?.stopScrolling?.();'));
      expect(
        controllerSource,
        contains("Future<void> stopScrolling() => _invoke('stopScrolling')"),
      );
    },
  );
}
