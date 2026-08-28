import 'package:flutter/foundation.dart';

bool supportsWebConversationViewport({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return false;
  return switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    TargetPlatform.linux || TargetPlatform.fuchsia => false,
  };
}
