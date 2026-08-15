import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/workspace/guest_cwd.dart';

void main() {
  group('normalizeGuestCwd', () {
    test('blank and null map to /workspace', () {
      expect(normalizeGuestCwd(null), '/workspace');
      expect(normalizeGuestCwd(''), '/workspace');
    });

    test('accepts the exact /workspace root', () {
      expect(normalizeGuestCwd('/workspace'), '/workspace');
    });

    test('accepts relative paths and resolves them under /workspace', () {
      expect(normalizeGuestCwd('src'), '/workspace/src');
      expect(normalizeGuestCwd('src/lib'), '/workspace/src/lib');
      expect(normalizeGuestCwd('/src'), '/workspace/src');
      expect(normalizeGuestCwd('a//b'), '/workspace/a/b');
      expect(normalizeGuestCwd('./a'), '/workspace/a');
    });

    test('accepts /workspace/... and normalizes . and .. segments', () {
      expect(normalizeGuestCwd('/workspace/src'), '/workspace/src');
      expect(normalizeGuestCwd('/workspace/a/../b'), '/workspace/b');
      expect(normalizeGuestCwd('/workspace/.'), '/workspace');
      expect(normalizeGuestCwd('/workspace/'), '/workspace');
    });
  });
}
