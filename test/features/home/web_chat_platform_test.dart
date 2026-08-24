import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/webview/web_chat_platform.dart';

void main() {
  test(
    'Web conversation viewport is exposed only on supported native targets',
    () {
      expect(
        supportsWebConversationViewport(
          isWeb: false,
          platform: TargetPlatform.android,
        ),
        isTrue,
      );
      expect(
        supportsWebConversationViewport(
          isWeb: false,
          platform: TargetPlatform.windows,
        ),
        isTrue,
      );
      expect(
        supportsWebConversationViewport(
          isWeb: false,
          platform: TargetPlatform.linux,
        ),
        isFalse,
      );
      expect(
        supportsWebConversationViewport(
          isWeb: true,
          platform: TargetPlatform.macOS,
        ),
        isFalse,
      );
    },
  );
}
