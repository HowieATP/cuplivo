import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/filesystem_mounts_provider.dart';
import 'package:Cuplivo/core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('validateMountConfig', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('kelivo_mounts_test_');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('reserved alias workspaces returns errorAliasReserved', () {
      final err = validateMountConfig(
        alias: 'workspaces',
        path: tmp.path,
        existing: const [],
      );
      expect(err, FilesystemMountsProvider.errorAliasReserved);
    });

    test('syntax-invalid alias returns errorAliasInvalid', () {
      for (final bad in ['UPPER', 'has space', 'a/b', 'a..', '-x']) {
        final err = validateMountConfig(
          alias: bad,
          path: tmp.path,
          existing: const [],
        );
        expect(err, FilesystemMountsProvider.errorAliasInvalid, reason: bad);
      }
    });

    test('duplicate alias returns errorAliasDuplicate', () {
      final err = validateMountConfig(
        alias: 'docs',
        path: tmp.path,
        existing: const [
          FilesystemMount(alias: 'docs', path: '/x', readOnly: true),
        ],
      );
      expect(err, FilesystemMountsProvider.errorAliasDuplicate);
    });

    test('relative path returns errorPathInvalid', () {
      final err = validateMountConfig(
        alias: 'docs',
        path: 'relative/path',
        existing: const [],
      );
      expect(err, FilesystemMountsProvider.errorPathInvalid);
    });

    test('UNC path is accepted as absolute (Windows)', () {
      final err = validateMountConfig(
        alias: 'share',
        path: r'\\server\share',
        existing: const [],
      );
      // Accepts the syntax; existence check is platform-dependent.
      expect(
        err == FilesystemMountsProvider.errorPathInvalid,
        isFalse,
        reason: 'UNC paths are absolute on Windows',
      );
    });

    test('non-existent directory returns errorPathNotFound', () {
      final err = validateMountConfig(
        alias: 'docs',
        path: '${tmp.path}/missing_dir',
        existing: const [],
      );
      expect(err, FilesystemMountsProvider.errorPathNotFound);
    });

    test('valid config returns null', () {
      final err = validateMountConfig(
        alias: 'docs',
        path: tmp.path,
        existing: const [],
      );
      expect(err, isNull);
    });
  });
}
