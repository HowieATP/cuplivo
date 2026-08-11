import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SandboxReadiness.compute', () {
    test('non-android is unsupported', () {
      expect(
        SandboxReadiness.compute(
          isAndroid: false,
          hasRootfs: true,
          hasProot: true,
        ),
        SandboxStatus.unsupported,
      );
    });

    test('no rootfs is disabled even with proot', () {
      expect(
        SandboxReadiness.compute(
          isAndroid: true,
          hasRootfs: false,
          hasProot: true,
        ),
        SandboxStatus.disabled,
      );
    });

    test('rootfs without proot is runtimeMissing', () {
      expect(
        SandboxReadiness.compute(
          isAndroid: true,
          hasRootfs: true,
          hasProot: false,
        ),
        SandboxStatus.runtimeMissing,
      );
    });

    test('rootfs and proot is ready', () {
      expect(
        SandboxReadiness.compute(
          isAndroid: true,
          hasRootfs: true,
          hasProot: true,
        ),
        SandboxStatus.ready,
      );
    });

    test('rootfs check failure is broken', () {
      expect(
        SandboxReadiness.compute(
          isAndroid: true,
          hasRootfs: false,
          hasProot: true,
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
      contains('proot'),
    );
  });
}
