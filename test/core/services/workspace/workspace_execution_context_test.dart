import 'dart:io';

import 'package:Cuplivo/core/services/workspace/workspace_execution_context.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('normalizeWorkspaceDirectory', () {
    test('stores root-relative and absolute input canonically', () {
      expect(normalizeWorkspaceDirectory('/workspace'), '/workspace');
      expect(
        normalizeWorkspaceDirectory('project/src'),
        '/workspace/project/src',
      );
      expect(
        normalizeWorkspaceDirectory('/workspace/project/./src/../test'),
        '/workspace/project/test',
      );
    });

    test('rejects empty, foreign absolute, backslash, and escaping input', () {
      for (final path in <String>[
        '',
        '/tmp/project',
        r'project\src',
        '../outside',
        'project/bad:',
        'project/trailing.',
      ]) {
        expect(
          () => normalizeWorkspaceDirectory(path),
          throwsA(isA<WorkspacePathException>()),
          reason: path,
        );
      }
    });
  });

  group('resolveWorkspaceGuestPath', () {
    test('normalizes dot segments inside the workspace', () {
      expect(
        resolveWorkspaceGuestPath(
          './lib/../test/a.dart',
          baseDirectory: '/workspace/project',
        ),
        '/workspace/project/test/a.dart',
      );
    });

    test('absolute workspace paths stay root-anchored', () {
      expect(
        resolveWorkspaceGuestPath(
          '/workspace/other',
          baseDirectory: '/workspace/project',
        ),
        '/workspace/other',
      );
    });
  });

  test(
    'conversation override wins, otherwise assistant default is inherited',
    () {
      final assistant = Assistant(
        id: 'a1',
        name: 'Assistant',
        workspaceDefaultDirectories: const {
          'a': '/workspace/assistant-a',
          'b': '/workspace/assistant-b',
        },
      );
      final conversation = Conversation(
        title: 'Conversation',
        workspaceDirectoryOverrides: const {'a': '/workspace/conversation-a'},
      );

      expect(
        effectiveWorkspaceDirectory(
          assistant: assistant,
          conversation: conversation,
          workspaceId: 'a',
        ),
        '/workspace/conversation-a',
      );
      expect(
        effectiveWorkspaceDirectory(
          assistant: assistant,
          conversation: conversation,
          workspaceId: 'b',
        ),
        '/workspace/assistant-b',
      );
      expect(
        effectiveWorkspaceDirectory(
          assistant: assistant,
          conversation: conversation,
          workspaceId: 'c',
        ),
        '/workspace',
      );
    },
  );

  test(
    'missing configured directory is created and recreated after deletion',
    () async {
      final root = await Directory.systemTemp.createTemp('cuplivo_cwd_');
      addTearDown(() => root.delete(recursive: true));
      final workspace = Workspace.createDefault();

      final hostPath = await ensureWorkspaceDirectoryAtHostRoot(
        workspace: workspace,
        hostRoot: root.path,
        workingDirectory: '/workspace/project/session',
      );
      expect(await Directory(hostPath).exists(), isTrue);
      await Directory(hostPath).delete(recursive: true);
      await ensureWorkspaceDirectoryAtHostRoot(
        workspace: workspace,
        hostRoot: root.path,
        workingDirectory: '/workspace/project/session',
      );
      expect(await Directory(hostPath).exists(), isTrue);
    },
  );

  test(
    'read-only workspace rejects a missing directory without fallback',
    () async {
      final root = await Directory.systemTemp.createTemp('cuplivo_cwd_ro_');
      addTearDown(() => root.delete(recursive: true));
      final workspace = Workspace.createDefault().copyWith(readOnly: true);

      expect(
        () => ensureWorkspaceDirectoryAtHostRoot(
          workspace: workspace,
          hostRoot: root.path,
          workingDirectory: '/workspace/missing',
        ),
        throwsA(isA<WorkspacePathException>()),
      );
    },
  );

  test('working directory rejects a symbolic-link escape', () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('cuplivo_cwd_root_');
    final outside = await Directory.systemTemp.createTemp(
      'cuplivo_cwd_outside_',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    await Link('${root.path}/escape').create(outside.path);

    await expectLater(
      ensureWorkspaceDirectoryAtHostRoot(
        workspace: Workspace.createDefault(),
        hostRoot: root.path,
        workingDirectory: '/workspace/escape/created-outside',
      ),
      throwsA(isA<WorkspacePathException>()),
    );
    expect(
      await Directory('${outside.path}/created-outside').exists(),
      isFalse,
    );
  });

  test(
    'loads AGENTS.md from the working directory up to the workspace root',
    () async {
      final container = await Directory.systemTemp.createTemp(
        'cuplivo_agents_md_',
      );
      final root = Directory('${container.path}/workspace');
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(container.path);
      addTearDown(() => container.delete(recursive: true));
      addTearDown(() => PathProviderPlatform.instance = originalPathProvider);
      await Directory('${root.path}/project/nested').create(recursive: true);
      await File('${root.path}/AGENTS.md').writeAsString('root instructions');
      await File(
        '${root.path}/project/AGENTS.md',
      ).writeAsString('project instructions');
      await File(
        '${container.path}/AGENTS.md',
      ).writeAsString('outside instructions');

      final workspace = Workspace(
        id: 'workspace-a',
        displayName: 'Workspace',
        alias: 'workspace',
        customHostPath: root.path,
      );
      final workspaces = WorkspaceProvider();
      await workspaces.init();
      final instructions = await loadWorkspaceAgentsMdInstructions(
        context: WorkspaceExecutionContext(
          workspace: workspace,
          workingDirectory: '/workspace/project/nested',
        ),
        workspaces: workspaces,
      );

      expect(
        instructions,
        'Instructions from: /workspace/project/AGENTS.md\n'
        'project instructions\n\n'
        'Instructions from: /workspace/AGENTS.md\nroot instructions',
      );
      expect(instructions, isNot(contains('outside instructions')));
    },
  );

  test(
    'keeps an empty AGENTS.md and returns null when none are found',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cuplivo_agents_empty_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => PathProviderPlatform.instance = originalPathProvider);
      await Directory('${root.path}/project').create();
      final workspace = Workspace(
        id: 'workspace-a',
        displayName: 'Workspace',
        alias: 'workspace',
        customHostPath: root.path,
      );
      final context = WorkspaceExecutionContext(
        workspace: workspace,
        workingDirectory: '/workspace/project',
      );
      final workspaces = WorkspaceProvider();
      await workspaces.init();

      expect(
        await loadWorkspaceAgentsMdInstructions(
          context: context,
          workspaces: workspaces,
        ),
        isNull,
      );
      await File('${root.path}/project/AGENTS.md').writeAsString('');
      expect(
        await loadWorkspaceAgentsMdInstructions(
          context: context,
          workspaces: workspaces,
        ),
        'Instructions from: /workspace/project/AGENTS.md\n',
      );
    },
  );

  test(
    'rejects AGENTS.md entries that resolve outside the workspace',
    () async {
      if (Platform.isWindows) return;
      final root = await Directory.systemTemp.createTemp(
        'cuplivo_agents_root_',
      );
      final outside = await Directory.systemTemp.createTemp(
        'cuplivo_agents_outside_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      addTearDown(() => PathProviderPlatform.instance = originalPathProvider);
      await Directory('${root.path}/project').create();
      final outsideAgents = File('${outside.path}/AGENTS.md');
      await outsideAgents.writeAsString('outside');
      await Link('${root.path}/project/AGENTS.md').create(outsideAgents.path);
      final workspaces = WorkspaceProvider();
      await workspaces.init();

      await expectLater(
        loadWorkspaceAgentsMdInstructions(
          context: WorkspaceExecutionContext(
            workspace: Workspace(
              id: 'workspace-a',
              displayName: 'Workspace',
              alias: 'workspace',
              customHostPath: root.path,
            ),
            workingDirectory: '/workspace/project',
          ),
          workspaces: workspaces,
        ),
        throwsA(isA<WorkspaceAgentsMdLoadException>()),
      );
    },
  );

  test('rejects a missing working directory and directory AGENTS.md', () async {
    final root = await Directory.systemTemp.createTemp(
      'cuplivo_agents_invalid_',
    );
    final originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => PathProviderPlatform.instance = originalPathProvider);
    final workspace = Workspace(
      id: 'workspace-a',
      displayName: 'Workspace',
      alias: 'workspace',
      customHostPath: root.path,
    );
    final workspaces = WorkspaceProvider();
    await workspaces.init();

    await expectLater(
      loadWorkspaceAgentsMdInstructions(
        context: WorkspaceExecutionContext(
          workspace: workspace,
          workingDirectory: '/workspace/missing',
        ),
        workspaces: workspaces,
      ),
      throwsA(isA<WorkspaceAgentsMdLoadException>()),
    );

    await Directory('${root.path}/AGENTS.md').create();
    await expectLater(
      loadWorkspaceAgentsMdInstructions(
        context: WorkspaceExecutionContext(
          workspace: workspace,
          workingDirectory: '/workspace',
        ),
        workspaces: workspaces,
      ),
      throwsA(isA<WorkspaceAgentsMdLoadException>()),
    );
  });
}
