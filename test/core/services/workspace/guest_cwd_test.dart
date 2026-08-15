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
  });
}
