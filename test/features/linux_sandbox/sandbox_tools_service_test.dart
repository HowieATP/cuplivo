import 'dart:convert';
import 'dart:io';

import 'package:Cuplivo/features/linux_sandbox/models/linux_sandbox.dart';
import 'package:Cuplivo/features/linux_sandbox/services/sandbox_runtime.dart';
import 'package:Cuplivo/features/linux_sandbox/services/sandbox_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingRuntime implements SandboxRuntime {
  final List<String> calls = <String>[];

  @override
  String get sandboxId => 'fake';

  @override
  bool get isSupported => true;

  @override
  Future<void> ensureReady() async {
    calls.add('ensureReady');
  }

  @override
  Future<Directory> rootDirectory() async {
    throw UnimplementedError();
  }

  @override
  Future<SandboxToolResult> read(String path) async {
    calls.add('read:$path');
    return SandboxToolResult.success('content:$path');
  }

  @override
  Future<SandboxToolResult> write(String path, String content) async {
    calls.add('write:$path:$content');
    return SandboxToolResult.success('ok');
  }

  @override
  Future<SandboxToolResult> edit(
    String path,
    String oldString,
    String newString,
  ) async {
    calls.add('edit:$path:$oldString->$newString');
    return SandboxToolResult.success('edited');
  }

  @override
  Future<SandboxToolResult> shell(String command, {Duration? timeout}) async {
    calls.add('shell:$command:${timeout?.inSeconds}');
    return SandboxToolResult.success('out', exitCode: 0);
  }

  @override
  Future<List<SandboxFsEntry>> listDir([String path = '']) async =>
      const <SandboxFsEntry>[];

  @override
  Future<void> destroyDisk() async {}
}

void main() {
  group('SandboxToolsService', () {
    test('isSandboxTool recognizes only sandbox tools', () {
      expect(
        SandboxToolsService.isSandboxTool(LinuxSandboxToolNames.read),
        isTrue,
      );
      expect(
        SandboxToolsService.isSandboxTool(LinuxSandboxToolNames.shell),
        isTrue,
      );
      expect(SandboxToolsService.isSandboxTool('clipboard_tool'), isFalse);
    });

    test('toolNeedsApproval respects config', () {
      final sandbox = LinuxSandbox(id: '1', name: 's');
      expect(
        SandboxToolsService.toolNeedsApproval(
          sandbox,
          LinuxSandboxToolNames.read,
        ),
        isFalse,
      );
      expect(
        SandboxToolsService.toolNeedsApproval(
          sandbox,
          LinuxSandboxToolNames.write,
        ),
        isTrue,
      );
    });

    test('buildToolDefinitions empty without sandbox or tools support', () {
      expect(
        SandboxToolsService.buildToolDefinitions(
          sandbox: null,
          supportsTools: true,
        ),
        isEmpty,
      );
      expect(
        SandboxToolsService.buildToolDefinitions(
          sandbox: LinuxSandbox(id: '1', name: 's'),
          supportsTools: false,
        ),
        isEmpty,
      );
    });

    test('buildToolDefinitions includes enabled tools only', () {
      final sandbox = LinuxSandbox(
        id: '1',
        name: 's',
        tools: {
          ...LinuxSandbox.defaultTools(),
          LinuxSandboxToolNames.shell: const LinuxSandboxToolConfig(
            enabled: false,
            needsApproval: true,
          ),
        },
      );
      final defs = SandboxToolsService.buildToolDefinitions(
        sandbox: sandbox,
        supportsTools: true,
      );
      final names = defs
          .map((d) => (d['function'] as Map)['name'] as String)
          .toList();
      expect(names, contains(LinuxSandboxToolNames.read));
      expect(names, contains(LinuxSandboxToolNames.write));
      expect(names, contains(LinuxSandboxToolNames.edit));
      expect(names, isNot(contains(LinuxSandboxToolNames.shell)));
    });

    test('tryHandleToolCall returns null for non-sandbox tools', () async {
      final result = await SandboxToolsService.tryHandleToolCall(
        name: 'clipboard_tool',
        args: const {},
        sandbox: LinuxSandbox(id: '1', name: 's'),
        runtime: _RecordingRuntime(),
      );
      expect(result, isNull);
    });

    test('tryHandleToolCall dispatches read/write/edit/shell', () async {
      final runtime = _RecordingRuntime();
      final sandbox = LinuxSandbox(id: '1', name: 's');

      final read = await SandboxToolsService.tryHandleToolCall(
        name: LinuxSandboxToolNames.read,
        args: {'path': 'a.txt'},
        sandbox: sandbox,
        runtime: runtime,
      );
      expect(jsonDecode(read!)['content'], 'content:a.txt');

      final write = await SandboxToolsService.tryHandleToolCall(
        name: LinuxSandboxToolNames.write,
        args: {'path': 'a.txt', 'content': 'hi'},
        sandbox: sandbox,
        runtime: runtime,
      );
      expect(jsonDecode(write!)['ok'], isTrue);

      final edit = await SandboxToolsService.tryHandleToolCall(
        name: LinuxSandboxToolNames.edit,
        args: {'path': 'a.txt', 'old_string': 'a', 'new_string': 'b'},
        sandbox: sandbox,
        runtime: runtime,
      );
      expect(jsonDecode(edit!)['ok'], isTrue);

      final shell = await SandboxToolsService.tryHandleToolCall(
        name: LinuxSandboxToolNames.shell,
        args: {'command': 'echo hi', 'timeout_seconds': 10},
        sandbox: sandbox,
        runtime: runtime,
      );
      expect(jsonDecode(shell!)['exit_code'], 0);

      expect(runtime.calls, contains('ensureReady'));
      expect(runtime.calls, contains('read:a.txt'));
      expect(runtime.calls, contains('write:a.txt:hi'));
      expect(runtime.calls, contains('edit:a.txt:a->b'));
      expect(runtime.calls, contains('shell:echo hi:10'));
    });

    test('tryHandleToolCall reports disabled tool', () async {
      final sandbox = LinuxSandbox(
        id: '1',
        name: 's',
        tools: {
          ...LinuxSandbox.defaultTools(),
          LinuxSandboxToolNames.read: const LinuxSandboxToolConfig(
            enabled: false,
            needsApproval: false,
          ),
        },
      );
      final raw = await SandboxToolsService.tryHandleToolCall(
        name: LinuxSandboxToolNames.read,
        args: {'path': 'x'},
        sandbox: sandbox,
        runtime: _RecordingRuntime(),
      );
      final map = jsonDecode(raw!) as Map<String, dynamic>;
      expect(map['error'], 'tool_disabled');
    });
  });
}
