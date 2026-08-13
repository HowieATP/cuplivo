import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinuxSandboxService.buildAptInstallSteps', () {
    test('runs recover before update before install', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      expect(steps.map((s) => s.stage).toList(), [
        'recover',
        'update',
        'install',
      ]);
    });

    test('recover clears stale locks and repairs interrupted dpkg state', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      final recover = steps.first;
      expect(recover.stage, 'recover');
      expect(recover.command, contains('rm -f /var/lib/dpkg/lock'));
      expect(
        recover.command,
        contains('/var/cache/apt/archives/lock /var/lib/apt/lists/lock'),
      );
      expect(recover.command, contains('dpkg --configure -a'));
      expect(
        recover.command,
        contains('apt-get -o Acquire::Lock::Timeout=600 -f install -y'),
      );
      expect(recover.command, contains('DEBIAN_FRONTEND=noninteractive'));
    });

    test('every apt invocation waits on a held lock instead of failing', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      for (final step in steps) {
        expect(step.command, contains('-o Acquire::Lock::Timeout=600'));
      }
    });

    test('update runs apt-get update without mirror setup by default', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      final update = steps[1];
      expect(update.stage, 'update');
      expect(update.command, 'apt-get -o Acquire::Lock::Timeout=600 update -y');
    });

    test('update prepends mirror setup when provided', () {
      const mirror =
          "printf '%s\\n' 'deb https://mirror.example/ubuntu noble main universe' > /etc/apt/sources.list && ";
      final steps = LinuxSandboxService.buildAptInstallSteps(
        packages: 'git',
        mirrorSetup: mirror,
      );
      expect(
        steps[1].command,
        '${mirror}apt-get -o Acquire::Lock::Timeout=600 update -y',
      );
    });

    test('install targets the requested packages and cleans cache', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(
        packages: 'python3 python3-pip',
      );
      final install = steps.last;
      expect(install.stage, 'install');
      expect(
        install.command,
        contains(
          'apt-get -o Acquire::Lock::Timeout=600 install -y '
          '--no-install-recommends python3 python3-pip',
        ),
      );
      expect(install.command, contains('&& apt-get clean'));
    });

    test('uses fixed staged timeouts', () {
      final steps = LinuxSandboxService.buildAptInstallSteps(packages: 'git');
      expect(steps[0].timeoutSeconds, 300);
      expect(steps[1].timeoutSeconds, 600);
      expect(steps[2].timeoutSeconds, 1800);
    });
  });
}
