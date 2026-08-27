import 'package:Cuplivo/core/services/workspace/workspace_path_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const safAliases = <String>{'notes', 'assets'};

  group('parseModelPath', () {
    test('translates workspace absolute and relative paths', () {
      expect(parseModelPath('/workspace', 'default'), '@default');
      expect(parseModelPath('/workspace/a/b.md', 'default'), '@default/a/b.md');
      expect(
        parseModelPath(
          'notes.md',
          'default',
          workingDirectory: '/workspace/project',
        ),
        '@default/project/notes.md',
      );
      expect(
        parseModelPath(
          '../shared/file.txt',
          'default',
          workingDirectory: '/workspace/project/src',
        ),
        '@default/project/shared/file.txt',
      );
      expect(
        parseModelPath(
          '/workspace/root.txt',
          'default',
          workingDirectory: '/workspace/project',
        ),
        '@default/root.txt',
      );
    });

    test('translates SAF mounts under /workspace/.mounts/<alias>', () {
      expect(
        parseModelPath(
          '/workspace/.mounts/notes',
          'default',
          safAliases: safAliases,
        ),
        '@notes',
      );
      expect(
        parseModelPath(
          '/workspace/.mounts/notes/a.md',
          'default',
          workingDirectory: '/workspace/project',
          safAliases: safAliases,
        ),
        '@notes/a.md',
      );
    });

    test('rejects escaping and foreign paths', () {
      for (final bad in [
        '../../outside.txt',
        '/etc/passwd',
        '/tmp/x',
        '/workspace2/x',
        'C:/x',
        '@default/x',
      ]) {
        expect(
          () => parseModelPath(
            bad,
            'default',
            workingDirectory: '/workspace/project',
          ),
          throwsA(isA<ModelPathException>()),
          reason: 'should reject: $bad',
        );
      }
    });

    test('rejects unknown or missing SAF aliases', () {
      expect(
        () => parseModelPath(
          '/workspace/.mounts/nope/a.md',
          'default',
          safAliases: safAliases,
        ),
        throwsA(isA<ModelPathException>()),
      );
      expect(
        () => parseModelPath(
          '/workspace/.mounts',
          'default',
          safAliases: safAliases,
        ),
        throwsA(isA<ModelPathException>()),
      );
    });

    test('preserves trailing slash for engine validation parity', () {
      expect(parseModelPath('/workspace/', 'default'), '@default/');
      expect(parseModelPath('/workspace/dir/', 'default'), '@default/dir/');
      expect(
        parseModelPath(
          '/workspace/.mounts/notes/',
          'default',
          safAliases: safAliases,
        ),
        '@notes/',
      );
    });

    test('passes the mount listing root through', () {
      expect(parseModelPath('/', 'default', safAliases: safAliases), '/');
    });
  });

  group('presentWirePath', () {
    test('presents the bound workspace', () {
      expect(presentWirePath('@default', 'default'), '/workspace');
      expect(
        presentWirePath('@default/notes.md', 'default'),
        '/workspace/notes.md',
      );
    });

    test('presents SAF mounts under /workspace/.mounts/<alias>', () {
      expect(
        presentWirePath('@notes', 'default', safAliases: safAliases),
        '/workspace/.mounts/notes',
      );
      expect(
        presentWirePath('@notes/a.md', 'default', safAliases: safAliases),
        '/workspace/.mounts/notes/a.md',
      );
    });

    test('leaves unknown mounts unchanged', () {
      expect(
        presentWirePath('@unknown/x', 'default', safAliases: safAliases),
        '@unknown/x',
      );
    });
  });

  group('presentDefText', () {
    test('rewrites wire-format copy to the workspace vocabulary', () {
      final out = presentDefText(
        'A mount-relative path like @default/notes.md or @alias/rel/path',
      );
      expect(out, contains('/workspace/notes.md'));
      expect(out, contains('/workspace/rel/path'));
      expect(out, contains('workspace-relative'));
      expect(out, isNot(contains('@default')));
      expect(out, isNot(contains('@alias')));
    });
  });
}
