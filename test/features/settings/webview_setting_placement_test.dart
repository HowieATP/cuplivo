import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('experimental WebView setting belongs to chat item settings', () {
    final mobile = File(
      'lib/features/settings/pages/display_settings_page.dart',
    ).readAsStringSync();
    final mobileChatItems = mobile.substring(
      mobile.indexOf('class ChatItemDisplaySettingsPage'),
      mobile.indexOf('class RenderingSettingsPage'),
    );
    expect(
      mobileChatItems,
      contains('displaySettingsPageExperimentalWebViewRenderingTitle'),
    );

    final desktop = File(
      'lib/desktop/setting/display_pane.dart',
    ).readAsStringSync();
    final chatItemsStart = desktop.indexOf(
      'title: l10n.displaySettingsPageChatItemDisplayTitle',
    );
    final renderingStart = desktop.indexOf(
      'title: l10n.displaySettingsPageRenderingSettingsTitle',
      chatItemsStart,
    );
    final behaviorStart = desktop.indexOf(
      'title: l10n.displaySettingsPageBehaviorStartupTitle',
      renderingStart,
    );
    final desktopChatItems = desktop.substring(chatItemsStart, renderingStart);
    final desktopRendering = desktop.substring(renderingStart, behaviorStart);

    expect(
      desktopChatItems,
      contains('_ToggleRowExperimentalWebViewRendering'),
    );
    expect(
      desktopRendering,
      isNot(contains('_ToggleRowExperimentalWebViewRendering')),
    );
  });
}
