import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SandboxReadiness.compute', () {
    test('unsupported platform is unsupported', () {
      expect(
        SandboxReadiness.compute(
          supported: false,
          hasRootfs: true,
          hasRuntime: true,
        ),
        SandboxStatus.unsupported,
      );
    });

    test('no rootfs is disabled even with runtime', () {
      expect(
        SandboxReadiness.compute(
          supported: true,
          hasRootfs: false,
          hasRuntime: true,
        ),
        SandboxStatus.disabled,
      );
    });

    test('rootfs without runtime is runtimeMissing', () {
      expect(
        SandboxReadiness.compute(
          supported: true,
          hasRootfs: true,
          hasRuntime: false,
        ),
        SandboxStatus.runtimeMissing,
      );
    });

    test('rootfs and runtime is ready', () {
      expect(
        SandboxReadiness.compute(
          supported: true,
          hasRootfs: true,
          hasRuntime: true,
        ),
        SandboxStatus.ready,
      );
    });

    test('rootfs check failure is broken', () {
      expect(
        SandboxReadiness.compute(
          supported: true,
          hasRootfs: false,
          hasRuntime: true,
          rootfsCheckFailed: true,
        ),
        SandboxStatus.broken,
      );
    });
  });

  test('statusUserMessage distinguishes runtime vs base', () {
    expect(
      LinuxSandboxService.statusUserMessage(SandboxStatus.disabled),
      contains('base'),
    );
    expect(
      LinuxSandboxService.statusUserMessage(SandboxStatus.runtimeMissing),
      contains('runtime'),
    );
    expect(
      LinuxSandboxService.statusUserMessage(SandboxStatus.unsupported),
      contains('Android or iOS'),
    );
  });
}
