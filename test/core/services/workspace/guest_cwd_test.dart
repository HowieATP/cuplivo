import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/workspace/guest_cwd.dart';

void main() {
  group('normalizeGuestCwd', () {
    test('blank and null map to /workspace', () {
      expect(normalizeGuestCwd(null), '/workspace');
      expect(normalizeGuestCwd(''), '/workspace');
      expect(normalizeGuestCwd('   '), '/workspace');
    });

    test('accepts the exact /workspace root', () {
      expect(normalizeGuestCwd('/workspace'), '/workspace');
    });

    test('accepts relative paths and resolves them under /workspace', () {
      expect(normalizeGuestCwd('src'), '/workspace/src');
      expect(normalizeGuestCwd('src/lib'), '/workspace/src/lib');
      expect(normalizeGuestCwd('a//b'), '/workspace/a/b');
      expect(normalizeGuestCwd('./a'), '/workspace/a');
    });

    test('accepts /workspace/... and normalizes . and .. segments', () {
      expect(normalizeGuestCwd('/workspace/src'), '/workspace/src');
      expect(normalizeGuestCwd('/workspace/a/../b'), '/workspace/b');
      expect(normalizeGuestCwd('/workspace/.'), '/workspace');
      expect(normalizeGuestCwd('/workspace/'), '/workspace');
    });

    test('rejects lookalike prefixes that are not /workspace subpaths', () {
      expect(normalizeGuestCwd('/workspaceX'), isNull);
      expect(normalizeGuestCwd('/workspaceX/src'), isNull);
    });

    test('rejects absolute paths outside /workspace', () {
      expect(normalizeGuestCwd('/'), isNull);
      expect(normalizeGuestCwd('/src'), isNull);
      expect(normalizeGuestCwd('/etc'), isNull);
      expect(normalizeGuestCwd('//workspace/src'), isNull);
    });

    test('rejects traversal that escapes /workspace', () {
      expect(normalizeGuestCwd('/workspace/../etc'), isNull);
      expect(normalizeGuestCwd('/workspace/../../root'), isNull);
      expect(normalizeGuestCwd('../../root'), isNull);
      expect(normalizeGuestCwd('/workspace/a/../../root'), isNull);
      expect(normalizeGuestCwd('..'), isNull);
      expect(normalizeGuestCwd('../a'), isNull);
    });

    test('rejects NUL bytes', () {
      final nul = String.fromCharCode(0);
      expect(normalizeGuestCwd('/workspace/a${nul}b'), isNull);
      expect(normalizeGuestCwd('a$nul'), isNull);
    });
  });
}
