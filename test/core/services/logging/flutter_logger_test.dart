import 'dart:ui' as ui;

import 'package:Cuplivo/core/services/logging/flutter_logger.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'installGlobalHandlers installs a non-null uncaught handler that returns '
    'true when no original handler exists',
    () {
      TestWidgetsFlutterBinding.ensureInitialized();
      final originalPlatformOnError = ui.PlatformDispatcher.instance.onError;
      final originalFlutterOnError = FlutterError.onError;
      try {
        FlutterLogger.installGlobalHandlers();
        final handler = ui.PlatformDispatcher.instance.onError;
        expect(handler, isNotNull);
        // The dart:ui contract: returning true keeps the isolate alive.
        // Returning false lets the engine terminate the process on the first
        // unhandled root-isolate error (silent window close in release).
        expect(handler!(StateError('boom'), StackTrace.current), isTrue);
      } finally {
        ui.PlatformDispatcher.instance.onError = originalPlatformOnError;
        FlutterError.onError = originalFlutterOnError;
      }
    },
  );
}
