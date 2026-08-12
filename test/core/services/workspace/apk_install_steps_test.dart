import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinuxSandboxService.buildApkInstallSteps', () {
    test('runs recover before update before install', () {
      final steps = LinuxSandboxService.buildApkInstallSteps(packages: 'git');
      expect(steps.map((s) => s.stage).toList(), [
        'recover',
        'update',
        'install',
      ]);
    });

    test('recover clears the stale apk lock', () {
      final steps = LinuxSandboxService.buildApkInstallSteps(packages: 'git');
      expect(steps.first.stage, 'recover');
      expect(steps.first.command, contains('rm -f /lib/apk/db/lock'));
    });

    test('update runs apk update without mirror setup by default', () {
      final steps = LinuxSandboxService.buildApkInstallSteps(packages: 'git');
      expect(steps[1].command, 'apk update');
    });

    test('update prepends mirror setup when provided', () {
      final mirror = LinuxSandboxService.apkMirrorSetup(
        'https://mirrors.aliyun.com/alpine',
      );
      final steps = LinuxSandboxService.buildApkInstallSteps(
        packages: 'git',
        mirrorSetup: mirror,
      );
      expect(steps[1].command, '${mirror}apk update');
    });

    test('install targets the requested packages', () {
      final steps = LinuxSandboxService.buildApkInstallSteps(
        packages: 'python3 py3-pip',
      );
      expect(steps.last.command, 'apk add python3 py3-pip');
    });

    test('uses fixed staged timeouts', () {
      final steps = LinuxSandboxService.buildApkInstallSteps(packages: 'git');
      expect(steps[0].timeoutSeconds, 120);
      expect(steps[1].timeoutSeconds, 600);
      expect(steps[2].timeoutSeconds, 1800);
    });
  });

  group('LinuxSandboxService.apkMirrorSetup', () {
    test('rewrites repositories for the bundled Alpine version', () {
      final setup = LinuxSandboxService.apkMirrorSetup(
        'https://mirrors.tuna.tsinghua.edu.cn/alpine',
      );
      expect(
        setup,
        contains(
          'https://mirrors.tuna.tsinghua.edu.cn/alpine/v'
          '${LinuxSandboxService.alpineVersion}/main',
        ),
      );
      expect(
        setup,
        contains(
          'https://mirrors.tuna.tsinghua.edu.cn/alpine/v'
          '${LinuxSandboxService.alpineVersion}/community',
        ),
      );
      expect(setup, contains('> /etc/apk/repositories'));
      expect(setup, endsWith('&& '));
    });
  });

  test('apkMirrorBaseUrls maps named sources only', () {
    expect(
      LinuxSandboxService.apkMirrorBaseUrls.keys,
      containsAll(['tuna', 'aliyun']),
    );
    expect(LinuxSandboxService.apkMirrorBaseUrls, isNot(contains('auto')));
    expect(LinuxSandboxService.apkMirrorBaseUrls, isNot(contains('official')));
  });
}
