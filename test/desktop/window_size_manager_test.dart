import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/desktop/window_size_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WindowSizeManager', () {
    test('window floor matches the 720x432 acceptance target', () {
      expect(WindowSizeManager.minWindowWidth, 720.0);
      expect(WindowSizeManager.minWindowHeight, 432.0);
    });

    test(
      'defaults to the first-launch size when nothing is persisted',
      () async {
        SharedPreferences.setMockInitialValues({});

        final size = await const WindowSizeManager().getInitialSize();

        expect(size.width, WindowSizeManager.defaultWindowWidth);
        expect(size.height, WindowSizeManager.defaultWindowHeight);
      },
    );

    test('lifts a below-floor persisted size up to the floor', () async {
      SharedPreferences.setMockInitialValues({
        'window_width_v1': 500.0,
        'window_height_v1': 300.0,
      });

      final size = await const WindowSizeManager().getInitialSize();

      expect(size.width, WindowSizeManager.minWindowWidth);
      expect(size.height, WindowSizeManager.minWindowHeight);
    });

    test('passes an in-range persisted size through unchanged', () async {
      SharedPreferences.setMockInitialValues({
        'window_width_v1': 1000.0,
        'window_height_v1': 700.0,
      });

      final size = await const WindowSizeManager().getInitialSize();

      expect(size.width, 1000.0);
      expect(size.height, 700.0);
    });

    test('caps an oversized persisted size at the maximum', () async {
      SharedPreferences.setMockInitialValues({
        'window_width_v1': 9000.0,
        'window_height_v1': 9000.0,
      });

      final size = await const WindowSizeManager().getInitialSize();

      expect(size.width, WindowSizeManager.maxWindowWidth);
      expect(size.height, WindowSizeManager.maxWindowHeight);
    });

    test('setSize clamps before persisting', () async {
      SharedPreferences.setMockInitialValues({});
      final manager = const WindowSizeManager();

      await manager.setSize(const Size(500, 300));

      final size = await manager.getInitialSize();
      expect(size.width, WindowSizeManager.minWindowWidth);
      expect(size.height, WindowSizeManager.minWindowHeight);
    });
  });
}
