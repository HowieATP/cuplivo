import 'package:Cuplivo/core/services/workspace/workspace_path_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const safAliases = <String>{'notes', 'assets'};

  group('parseModelPath', () {
    test('translates the bound workspace', () {
      expect(parseModelPath('/workspace', 'default'), '@default');
      expect(parseModelPath('/workspace/a/b.md', 'default'), '@default/a/b.md');
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
          safAliases: safAliases,
        ),
        '@notes/a.md',
      );
    });

    test('rejects an unknown SAF alias', () {
      expect(
        () => parseModelPath(
          '/workspace/.mounts/nope/a.md',
          'default',
          safAliases: safAliases,
        ),
        throwsA(isA<ModelPathException>()),
      );
    });

    test('rejects .mounts without an alias', () {
      expect(
        () => parseModelPath(
          '/workspace/.mounts',
          'default',
          safAliases: safAliases,
        ),
        throwsA(isA<ModelPathException>()),
      );
    });

    test('a literal .mounts workspace folder is shadowed', () {
      // /workspace/.mounts/notes resolves as the SAF mount when the alias is
      // known — a real folder named .mounts cannot be addressed (ADR-0037).
      expect(
        parseModelPath(
          '/workspace/.mounts/notes',
          'default',
          safAliases: safAliases,
        ),
        '@notes',
      );
    });

    test('still rejects canonical wire and absolute paths', () {
      expect(
        () => parseModelPath('@notes/a.md', 'default', safAliases: safAliases),
        throwsA(isA<ModelPathException>()),
      );
      expect(
        () => parseModelPath('/etc/passwd', 'default'),
        throwsA(isA<ModelPathException>()),
      );
    });

    test('passes the root listing through', () {
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
