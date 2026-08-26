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
    'viewport navigation cancels native momentum before sending commands',
    () {
      final source = File(
        'lib/features/home/webview/web_conversation_viewport.dart',
      ).readAsStringSync();

      expect(source, contains('_sendViewportCommand'));
      final methodStart = source.indexOf('Future<void> _sendViewportCommand');
      final methodBody = source.substring(methodStart, methodStart + 500);
      expect(methodBody.indexOf('_stopWebScrolling()'), isNonNegative);
      expect(
        methodBody.indexOf('_sendEnvelope(command)'),
        greaterThan(methodBody.indexOf('_stopWebScrolling()')),
      );
    },
  );

  test('streaming bridge serializes batches and retains latest patches', () {
    final source = File(
      'lib/features/home/webview/web_conversation_viewport.dart',
    ).readAsStringSync();
    final protocolSource = File(
      'lib/features/home/webview/web_chat_protocol.dart',
    ).readAsStringSync();

    expect(source, contains('WebChatStreamingPatchBuffer'));
    expect(source, contains('completeBatch()'));
    expect(source, contains('hasPending'));
    expect(source, contains('_snapshotQueue.hasInFlight'));
    expect(source, contains('_streamPatchBuffer.inFlight'));
    expect(protocolSource, contains("'streamRevision'"));
  });

  test(
    'translation listeners detach from the notifier instance they bound',
    () {
      final source = File(
        'lib/features/home/webview/web_conversation_viewport.dart',
      ).readAsStringSync();
      final homeSource = File(
        'lib/features/home/pages/home_page.dart',
      ).readAsStringSync();

      expect(source, contains('_StreamingListenerBinding'));
      expect(
        source,
        contains('binding.notifier.removeListener(binding.listener)'),
      );
      final detachStart = source.indexOf('void _detachStreamingListeners()');
      final detachBody = source.substring(detachStart, detachStart + 300);
      expect(detachBody, isNot(contains('getNotifier')));
      expect(homeSource, contains("'patchKind': 'translation'"));
    },
  );

  test('remote media and message actions stay behind opaque registries', () {
    final viewportSource = File(
      'lib/features/home/webview/web_conversation_viewport.dart',
    ).readAsStringSync();
    final homeSource = File(
      'lib/features/home/pages/home_page.dart',
    ).readAsStringSync();

    expect(viewportSource, contains("handle.startsWith('remote:')"));
    expect(viewportSource, contains('WebChatRemoteImageLoader'));
    expect(viewportSource, contains('unknown media handle'));
    expect(homeSource, contains('remoteMediaClientFactory'));
    expect(homeSource, contains('NetworkProxyConfig'));
    expect(homeSource, contains('settings.globalProxyEnabled'));
    expect(homeSource, contains('forceCloseOnDispose: true'));
    expect(homeSource, contains('ImageViewerPage'));
    expect(homeSource, contains('OpenFilex.open'));
    expect(homeSource, contains('buildWebChatCitationSources'));
    final targetLookup = homeSource.substring(
      homeSource.indexOf('ChatMessage? _findWebActionMessage'),
      homeSource.indexOf('bool _webMessageActionAllowed'),
    );
    expect(targetLookup, isNot(contains('groupedMessages')));
  });

  test(
    'conversation switching restores a saved Web viewport before bottoming',
    () {
      final source = File(
        'lib/features/home/controllers/home_page_controller.dart',
      ).readAsStringSync();

      expect(source, contains('savedAnchorForConversation(id)'));
      expect(source, contains('restoreAnchor(savedAnchor)'));
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
    'HomePage reuses the localized Web loading label for virtual windows',
    () {
      final source = File(
        'lib/features/home/pages/home_page.dart',
      ).readAsStringSync();

      expect(source, contains("'loading': l10n.webChatLoading"));
    },
  );

  test('Windows Web assets reuse only complete versioned caches', () {
    final source = File(
      'lib/features/home/webview/web_conversation_viewport.dart',
    ).readAsStringSync();

    expect(source, contains('.complete'));
    expect(source, contains('.complete.tmp'));
    expect(source, contains('_windowsCacheIsComplete'));
    expect(source, contains('_cleanupOldWindowsCaches'));
    expect(source, contains("'mermaid.min.js'"));
    expect(
      source,
      contains("queryParameters: <String, String>{'platform': 'windows'}"),
    );
    expect(RegExp(r'flush: true').allMatches(source), hasLength(1));
  });

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
      expect(nativeSource, contains('stopScrolling { result.success(null) }'));
      expect(nativeSource, contains('onComplete?.invoke()'));
      expect(
        controllerSource,
        contains("Future<void> stopScrolling() => _invoke('stopScrolling')"),
      );
    },
  );
}
