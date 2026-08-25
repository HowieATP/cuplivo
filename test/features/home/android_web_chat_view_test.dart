import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/webview/android_web_chat_view.dart';

void main() {
  testWidgets('Android Web chat eagerly owns pointer sequences', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: AndroidWebChatView(onPlatformViewCreated: (_) {}),
      ),
    );

    final view = tester.widget<AndroidView>(find.byType(AndroidView));
    final recognizers = view.gestureRecognizers;
    expect(recognizers, isNotNull);
    expect(recognizers, hasLength(1));
    expect(recognizers!.single.constructor(), isA<EagerGestureRecognizer>());
  });
}
