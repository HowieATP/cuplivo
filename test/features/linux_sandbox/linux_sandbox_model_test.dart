import 'package:Cuplivo/features/linux_sandbox/models/linux_sandbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinuxSandbox', () {
    test('defaultTools enables all with correct approval defaults', () {
      final tools = LinuxSandbox.defaultTools();
      expect(tools.keys.toSet(), LinuxSandboxToolNames.all.toSet());
      expect(tools[LinuxSandboxToolNames.read]!.enabled, isTrue);
      expect(tools[LinuxSandboxToolNames.read]!.needsApproval, isFalse);
      expect(tools[LinuxSandboxToolNames.write]!.needsApproval, isTrue);
      expect(tools[LinuxSandboxToolNames.edit]!.needsApproval, isTrue);
      expect(tools[LinuxSandboxToolNames.shell]!.needsApproval, isTrue);
    });

    test('toJson/fromJson round-trip', () {
      final original = LinuxSandbox(
        id: 'sb-1',
        name: 'Dev',
        description: 'desc',
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        updatedAt: DateTime.utc(2026, 1, 3, 4, 5, 6),
        tools: {
          ...LinuxSandbox.defaultTools(),
          LinuxSandboxToolNames.shell: const LinuxSandboxToolConfig(
            enabled: false,
            needsApproval: true,
          ),
        },
        enabledEnvPacks: const <String>[],
      );

      final restored = LinuxSandbox.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.description, original.description);
      expect(restored.createdAt, original.createdAt);
      expect(restored.updatedAt, original.updatedAt);
      expect(restored.enabledEnvPacks, isEmpty);
      expect(restored.tools[LinuxSandboxToolNames.shell]!.enabled, isFalse);
      expect(
        restored.tools[LinuxSandboxToolNames.read]!.needsApproval,
        isFalse,
      );
    });

    test('fromJson fills missing tools from defaults', () {
      final restored = LinuxSandbox.fromJson({
        'id': 'x',
        'name': 'n',
        'tools': {
          LinuxSandboxToolNames.read: {'enabled': false, 'needsApproval': true},
        },
      });
      expect(restored.tools[LinuxSandboxToolNames.read]!.enabled, isFalse);
      expect(restored.tools[LinuxSandboxToolNames.write]!.enabled, isTrue);
      expect(restored.tools[LinuxSandboxToolNames.edit]!.enabled, isTrue);
      expect(restored.tools[LinuxSandboxToolNames.shell]!.enabled, isTrue);
    });

    test('copyWith clearDescription', () {
      final s = LinuxSandbox(id: '1', name: 'n', description: 'd');
      final cleared = s.copyWith(clearDescription: true);
      expect(cleared.description, isNull);
      expect(cleared.name, 'n');
    });
  });

  group('LinuxSandboxToolConfig', () {
    test('copyWith and json', () {
      const c = LinuxSandboxToolConfig(enabled: true, needsApproval: false);
      final c2 = c.copyWith(needsApproval: true);
      expect(c2.enabled, isTrue);
      expect(c2.needsApproval, isTrue);
      final round = LinuxSandboxToolConfig.fromJson(c2.toJson());
      expect(round.enabled, isTrue);
      expect(round.needsApproval, isTrue);
    });
  });
}
