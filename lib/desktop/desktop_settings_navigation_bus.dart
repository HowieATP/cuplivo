import 'dart:async';

enum DesktopSettingsNavigationTarget { backup, assistants }

class DesktopSettingsNavigationBus {
  DesktopSettingsNavigationBus._();

  static final DesktopSettingsNavigationBus instance =
      DesktopSettingsNavigationBus._();

  final StreamController<DesktopSettingsNavigationTarget> _controller =
      StreamController<DesktopSettingsNavigationTarget>.broadcast();

  Stream<DesktopSettingsNavigationTarget> get stream => _controller.stream;

  void openBackup() {
    _controller.add(DesktopSettingsNavigationTarget.backup);
  }

  void openAssistants() {
    _controller.add(DesktopSettingsNavigationTarget.assistants);
  }
}
