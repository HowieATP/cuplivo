import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/providers/settings_provider.dart';
import '../../../../icons/lucide_adapter.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../desktop/setting/hotkeys_pane.dart';
import '../../widgets/display_setting_rows.dart';
import '../../widgets/ios_settings_widgets.dart';
import '../display_settings_page.dart';

class BehaviorSettingsPage extends StatelessWidget {
  const BehaviorSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
    final isBackgroundChatSupported = BackgroundChatRow.supportedOn(
      defaultTargetPlatform,
    );
    final showTray = context.select<SettingsProvider, bool>(
      (s) => s.desktopShowTray,
    );
    final minimizeOnClose = context.select<SettingsProvider, bool>(
      (s) => s.desktopMinimizeToTrayOnClose,
    );

    return IosSettingsPage(
      title: l10n.newSettingsBehaviorTitle,
      subtitle: l10n.newSettingsBehaviorSubtitle,
      children: [
        IosSettingsSectionCard(
          children: [
            IosSettingsNavRow(
              context,
              icon: Lucide.eclipse,
              label: l10n.displaySettingsPageBehaviorStartupTitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const BehaviorStartupSettingsPage(),
                ),
              ),
            ),
            IosSettingsDivider(context),
            IosSettingsNavRow(
              context,
              icon: Lucide.Vibrate,
              label: l10n.displaySettingsPageHapticsSettingsTitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HapticsSettingsPage()),
              ),
            ),
            IosSettingsDivider(context),
            if (isBackgroundChatSupported) ...[
              const BackgroundChatRow(),
              IosSettingsDivider(context),
            ],
            const AutoScrollIdleRow(),
          ],
        ),
        if (isDesktop) ...[
          const SizedBox(height: 12),
          IosSettingsHeader(context, l10n.newSettingsDesktopOnlySection),
          IosSettingsSectionCard(
            children: [
              IosSettingsNavRow(
                context,
                icon: Lucide.Keyboard,
                label: l10n.settingsPageHotkeys,
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const _HotkeysPage())),
              ),
              IosSettingsDivider(context),
              IosSettingsSwitchRow(
                label: l10n.displaySettingsPageTrayShowTrayTitle,
                value: showTray,
                onChanged: (v) =>
                    context.read<SettingsProvider>().setDesktopShowTray(v),
              ),
              IosSettingsDivider(context),
              IosSettingsSwitchRow(
                label: l10n.displaySettingsPageTrayMinimizeOnCloseTitle,
                value: showTray && minimizeOnClose,
                onChanged: showTray
                    ? (v) => context
                          .read<SettingsProvider>()
                          .setDesktopMinimizeToTrayOnClose(v)
                    : null,
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Standalone hotkeys page pushed from the desktop-only section. Uses its own
/// build context for the back button so the pop targets this route.
class _HotkeysPage extends StatelessWidget {
  const _HotkeysPage();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosTactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.settingsPageHotkeys),
      ),
      body: const DesktopHotkeysPane(),
    );
  }
}
