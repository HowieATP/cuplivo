import 'package:Cuplivo/core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import 'package:Cuplivo/core/services/workspace/workspace_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkspaceToolsService.dedupeMounts', () {
    test('keeps workspace mounts first and drops colliding SAF mounts', () {
      final wsMounts = [
        const FilesystemMount(
          alias: 'default',
          path: '/ws/default',
          readOnly: false,
        ),
      ];
      final safMounts = [
        const FilesystemMount(
          alias: 'default',
          path: '/mirror/default',
          uri: 'content://tree/1',
        ),
        const FilesystemMount(
          alias: 'notes',
          path: '/mirror/notes',
          uri: 'content://tree/2',
        ),
      ];

      final out = WorkspaceToolsService.dedupeMounts(wsMounts, safMounts);

      expect(out.map((m) => m.alias), ['default', 'notes']);
      // The workspace mount wins the alias; the SAF mirror is shadowed.
      expect(out.first.uri, isNull);
      expect(out.first.path, '/ws/default');
      // The non-colliding SAF mount stays.
      expect(out[1].uri, 'content://tree/2');
      expect(out.where((m) => m.isSafMount), hasLength(1));
    });

    test('an empty SAF list is a pass-through', () {
      final wsMounts = [
        const FilesystemMount(alias: 'default', path: '/ws/default'),
      ];
      final out = WorkspaceToolsService.dedupeMounts(wsMounts, const []);
      expect(out, hasLength(1));
      expect(out.single.alias, 'default');
    });

    test('a restored custom workspace alias shadows a SAF mount', () {
      // Backup restore can bring a workspace whose alias matches a SAF mount
      // added after that backup was made.
      final wsMounts = [
        const FilesystemMount(
          alias: 'notes',
          path: '/ws/notes',
          readOnly: false,
        ),
      ];
      final safMounts = [
        const FilesystemMount(
          alias: 'notes',
          path: '/mirror/notes',
          uri: 'content://tree/9',
        ),
      ];

      final out = WorkspaceToolsService.dedupeMounts(wsMounts, safMounts);
      expect(out, hasLength(1));
      expect(out.single.uri, isNull);
    });
  });

  group('WorkspaceToolsService.safAliasesFrom', () {
    test('derives aliases from the deduped composition only', () {
      final combined = WorkspaceToolsService.dedupeMounts(
        [
          const FilesystemMount(
            alias: 'notes',
            path: '/ws/notes',
            readOnly: false,
          ),
        ],
        [
          const FilesystemMount(
            alias: 'notes',
            path: '/mirror/notes',
            uri: 'content://tree/9',
          ),
          const FilesystemMount(
            alias: 'assets',
            path: '/mirror/assets',
            uri: 'content://tree/8',
          ),
        ],
      );
      // The shadowed "notes" alias must NOT be addressable — parse-time
      // rejection beats silent routing to the workspace mount.
      expect(WorkspaceToolsService.safAliasesFrom(combined), {'assets'});
    });

    test('empty when there are no SAF mounts', () {
      expect(
        WorkspaceToolsService.safAliasesFrom(const [
          FilesystemMount(alias: 'default', path: '/ws/default'),
        ]),
        isEmpty,
      );
    });
  });
}
