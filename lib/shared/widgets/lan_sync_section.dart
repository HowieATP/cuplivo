import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/backup.dart';
import '../../core/services/backup/data_sync.dart';
import '../../core/services/chat/chat_service.dart';
import '../../core/services/sync/lan_sync_client.dart';
import '../../core/services/sync/lan_sync_models.dart';
import '../../core/services/sync/lan_sync_server.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import '../dialogs/restart_required_dialog.dart';
import 'ios_form_text_field.dart';
import 'ios_tactile.dart';

/// Shared LAN Sync section widget for backup settings.
///
/// Adapts layout for mobile vs desktop based on [Platform.isAndroid]/[isIOS].
/// Both layouts share the same sync logic via [LanSyncServer] and [LanSyncClient].
class LanSyncSection extends StatefulWidget {
  const LanSyncSection({super.key});

  @override
  State<LanSyncSection> createState() => _LanSyncSectionState();
}

class _LanSyncSectionState extends State<LanSyncSection> {
  late final LanSyncServer _server;
  late final LanSyncClient _client;
  late final DataSync _dataSync;

  // Client-side form controllers
  final _hostController = TextEditingController(text: '192.168.');
  final _portController = TextEditingController(text: '9527');
  final _pinController = TextEditingController();

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    final chatService = context.read<ChatService>();
    _dataSync = DataSync(chatService: chatService);
    _server = LanSyncServer(chatService: chatService, dataSync: _dataSync);
    _client = LanSyncClient(chatService: chatService, dataSync: _dataSync);
    _server.addListener(_onChanged);
    _client.addListener(_onChanged);

    // When a zip is received (either side), restore it and prompt restart.
    _server.onZipReceived = _restoreAndRestart;
    _client.onZipReceived = _restoreAndRestart;
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _server.removeListener(_onChanged);
    _client.removeListener(_onChanged);
    _hostController.dispose();
    _portController.dispose();
    _pinController.dispose();
    _server.stop();
    super.dispose();
  }

  Future<void> _restoreAndRestart(File zipFile) async {
    if (!mounted) return;
    // Pop the sync dialog (server or client) before showing the restart
    // dialog. The sync dialog is the topmost route at this point.
    Navigator.of(context, rootNavigator: true).pop();
    await _dataSync.restoreFromLocalFile(
      zipFile,
      const WebDavConfig(includeChats: true, includeFiles: true),
      mode: RestoreMode.merge,
    );
    if (!mounted) return;
    await showRestartRequiredDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isDesktop) {
      return _buildDesktop(context, l10n, cs, isDark);
    }
    return _buildMobile(context, l10n, cs, isDark);
  }

  // ===== Desktop layout =====

  Widget _buildDesktop(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
    bool isDark,
  ) {
    return _desktopCard(
      isDark,
      cs,
      children: [
        _desktopHeader(l10n.lanSyncSectionTitle, cs),
        const SizedBox(height: 4),
        Text(
          l10n.lanSyncSecurityNote,
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _server.running ? null : () => _showServerDialog(),
                icon: const Icon(Icons.wifi_tethering, size: 18),
                label: Text(l10n.lanSyncServerMode),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _server.running
                    ? null
                    : () => _showClientDialog(context, l10n, cs),
                icon: const Icon(Icons.link, size: 18),
                label: Text(l10n.lanSyncClientMode),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _desktopCard(
    bool isDark,
    ColorScheme cs, {
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _desktopHeader(String title, ColorScheme cs) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 15,
        fontWeight: AppFontWeights.semibold,
        color: cs.onSurface.withValues(alpha: 0.95),
      ),
    );
  }

  void _showServerDialog() {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ServerDialog(
        server: _server,
        l10n: l10n,
        cs: cs,
        onClose: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  void _showClientDialog(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    _client.reset();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ClientDialog(
        hostController: _hostController,
        portController: _portController,
        pinController: _pinController,
        client: _client,
        l10n: l10n,
        cs: cs,
        onNegotiate: _negotiate,
        onExchange: _exchange,
        onClose: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  // ===== Mobile layout =====

  Widget _buildMobile(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
    bool isDark,
  ) {
    return _mobileCard(
      isDark,
      cs,
      children: [
        _mobileHeader(context, l10n.lanSyncSectionTitle, cs),
        _mobileNavRow(
          context,
          icon: Icons.wifi_tethering,
          label: l10n.lanSyncServerMode,
          onTap: _server.running ? null : () => _showServerDialog(),
        ),
        _mobileDivider(context),
        _mobileNavRow(
          context,
          icon: Icons.link,
          label: l10n.lanSyncClientMode,
          onTap: _server.running
              ? null
              : () => _showMobileClientSheet(context, l10n, cs),
        ),
      ],
    );
  }

  Widget _mobileHeader(BuildContext context, String title, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: AppFontWeights.semibold,
          color: cs.onSurface.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  Widget _mobileCard(
    bool isDark,
    ColorScheme cs, {
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: children),
      ),
    );
  }

  Widget _mobileNavRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    final interactive = onTap != null;
    return IosCardPress(
      onTap: onTap,
      baseColor: Colors.transparent,
      pressedBlendStrength: 0.06,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            SizedBox(width: 36, child: Icon(icon, size: 20)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 15),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (interactive) Icon(Icons.chevron_right, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _mobileDivider(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Divider(
      height: 6,
      thickness: 0.6,
      indent: 54,
      endIndent: 12,
      color: cs.outlineVariant.withValues(alpha: 0.18),
    );
  }

  void _showMobileClientSheet(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme cs,
  ) {
    _client.reset();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _ClientSheet(
        hostController: _hostController,
        portController: _portController,
        pinController: _pinController,
        client: _client,
        l10n: l10n,
        cs: cs,
        onNegotiate: _negotiate,
        onExchange: _exchange,
        onClose: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  // ===== Shared logic =====

  Future<void> _negotiate() async {
    final l10n = AppLocalizations.of(context)!;
    final host = _hostController.text.trim();
    final portStr = _portController.text.trim();
    final pin = _pinController.text.trim();

    if (host.isEmpty || portStr.isEmpty || pin.isEmpty) {
      _showError(l10n.lanSyncErrorConnection('All fields required'));
      return;
    }

    final port = int.tryParse(portStr);
    if (port == null || port < 1 || port > 65535) {
      _showError(l10n.lanSyncErrorConnection('Invalid port'));
      return;
    }

    try {
      await _client.negotiate(host: host, port: port, pin: pin);
    } catch (e) {
      _showError(
        e.toString().contains('PIN')
            ? l10n.lanSyncErrorInvalidPin
            : l10n.lanSyncErrorConnection(e.toString()),
      );
    }
  }

  Future<void> _exchange() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final host = _hostController.text.trim();
      final portStr = _portController.text.trim();
      final pin = _pinController.text.trim();
      final port = int.tryParse(portStr) ?? 9527;
      await _client.exchange(host: host, port: port, pin: pin);
    } catch (e) {
      _showError(l10n.lanSyncErrorConnection(e.toString()));
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    final snackBar = SnackBar(content: Text(message));
    ScaffoldMessenger.of(context).showSnackBar(snackBar);
  }
}

// ===== Server dialog (shared by mobile & desktop) =====

class _ServerDialog extends StatefulWidget {
  final LanSyncServer server;
  final AppLocalizations l10n;
  final ColorScheme cs;
  final VoidCallback onClose;

  const _ServerDialog({
    required this.server,
    required this.l10n,
    required this.cs,
    required this.onClose,
  });

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  @override
  void initState() {
    super.initState();
    widget.server.addListener(_onChanged);
    _start();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.server.removeListener(_onChanged);
    widget.server.stop();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await widget.server.start(preferredPort: 9527);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.l10n.lanSyncErrorConnection(e.toString())),
          ),
        );
        widget.onClose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final cs = widget.cs;
    final server = widget.server;

    return AlertDialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.wifi_tethering, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Text(l10n.lanSyncServerDialogTitle),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.lanSyncSecurityNote,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 16),
            _AddressDisplay(
              label: l10n.lanSyncServerAddress,
              value: server.address ?? '...',
              cs: cs,
            ),
            _AddressDisplay(
              label: l10n.lanSyncServerPort,
              value: server.port?.toString() ?? '...',
              cs: cs,
            ),
            _AddressDisplay(
              label: l10n.lanSyncServerPin,
              value: server.pin ?? '...',
              cs: cs,
              emphasize: true,
            ),
            if (server.status.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                server.status,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.onClose,
          child: Text(l10n.lanSyncServerStop),
        ),
      ],
    );
  }
}

/// Displays an address-like value with prominent (non-gray) styling.
class _AddressDisplay extends StatelessWidget {
  final String label;
  final String value;
  final ColorScheme cs;
  final bool emphasize;

  const _AddressDisplay({
    required this.label,
    required this.value,
    required this.cs,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: emphasize ? 22 : 16,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface,
                letterSpacing: emphasize ? 4 : 0,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ===== Client dialog (desktop) =====

class _ClientDialog extends StatefulWidget {
  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController pinController;
  final LanSyncClient client;
  final AppLocalizations l10n;
  final ColorScheme cs;
  final Future<void> Function() onNegotiate;
  final Future<void> Function() onExchange;
  final VoidCallback onClose;

  const _ClientDialog({
    required this.hostController,
    required this.portController,
    required this.pinController,
    required this.client,
    required this.l10n,
    required this.cs,
    required this.onNegotiate,
    required this.onExchange,
    required this.onClose,
  });

  @override
  State<_ClientDialog> createState() => _ClientDialogState();
}

class _ClientDialogState extends State<_ClientDialog> {
  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.client.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final cs = widget.cs;
    final client = widget.client;

    return AlertDialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.link, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Text(l10n.lanSyncClientDialogTitle),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: widget.hostController,
              decoration: InputDecoration(
                labelText: l10n.lanSyncClientHost,
                hintText: '192.168.1.100',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: widget.portController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.lanSyncClientPort,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: widget.pinController,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    decoration: InputDecoration(
                      labelText: l10n.lanSyncClientPin,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                ),
              ],
            ),
            if (client.status.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                client.status,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
            if (client.plan != null) ...[
              const SizedBox(height: 12),
              ...buildPlanSummary(l10n, client.plan!, cs),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: client.busy ? null : widget.onClose,
          child: Text(l10n.backupPageCancel),
        ),
        FilledButton(
          onPressed: client.busy
              ? null
              : () async {
                  if (client.plan == null) {
                    await widget.onNegotiate();
                  } else {
                    await widget.onExchange();
                  }
                },
          child: client.busy
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.onPrimary,
                  ),
                )
              : Text(
                  client.plan == null
                      ? l10n.lanSyncClientConnect
                      : l10n.lanSyncClientConfirm,
                ),
        ),
      ],
    );
  }
}

// ===== Client sheet (mobile) =====

class _ClientSheet extends StatefulWidget {
  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController pinController;
  final LanSyncClient client;
  final AppLocalizations l10n;
  final ColorScheme cs;
  final Future<void> Function() onNegotiate;
  final Future<void> Function() onExchange;
  final VoidCallback onClose;

  const _ClientSheet({
    required this.hostController,
    required this.portController,
    required this.pinController,
    required this.client,
    required this.l10n,
    required this.cs,
    required this.onNegotiate,
    required this.onExchange,
    required this.onClose,
  });

  @override
  State<_ClientSheet> createState() => _ClientSheetState();
}

class _ClientSheetState extends State<_ClientSheet> {
  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.client.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final cs = widget.cs;
    final client = widget.client;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.lanSyncClientDialogTitle,
              style: TextStyle(
                fontSize: 16,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            IosFormTextField(
              label: l10n.lanSyncClientHost,
              controller: widget.hostController,
              hintText: '192.168.1.100',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: IosFormTextField(
                    label: l10n.lanSyncClientPort,
                    controller: widget.portController,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 1,
                  child: IosFormTextField(
                    label: l10n.lanSyncClientPin,
                    controller: widget.pinController,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (client.status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  client.status,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            if (client.plan != null) ...[
              ...buildPlanSummary(l10n, client.plan!, cs),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: client.busy
                  ? null
                  : () async {
                      if (client.plan == null) {
                        await widget.onNegotiate();
                      } else {
                        await widget.onExchange();
                        if (context.mounted) widget.onClose();
                      }
                    },
              child: client.busy
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.onPrimary,
                      ),
                    )
                  : Text(
                      client.plan == null
                          ? l10n.lanSyncClientConnect
                          : l10n.lanSyncClientConfirm,
                    ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: client.busy ? null : widget.onClose,
              child: Text(l10n.backupPageCancel),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared plan summary widget builder for sync plan display.
List<Widget> buildPlanSummary(
  AppLocalizations l10n,
  SyncPlan plan,
  ColorScheme cs,
) {
  if (plan.initiatorOnlyCount == 0 &&
      plan.serverOnlyCount == 0 &&
      plan.forkCount == 0) {
    return [
      Text(
        l10n.lanSyncPlanNoChanges,
        style: TextStyle(fontSize: 14, color: cs.onSurface),
      ),
    ];
  }
  return [
    if (plan.initiatorOnlyCount > 0)
      Text(
        l10n.lanSyncPlanToSend(plan.initiatorOnlyCount),
        style: TextStyle(fontSize: 14, color: cs.onSurface),
      ),
    if (plan.serverOnlyCount > 0) ...[
      const SizedBox(height: 4),
      Text(
        l10n.lanSyncPlanToReceive(plan.serverOnlyCount),
        style: TextStyle(fontSize: 14, color: cs.onSurface),
      ),
    ],
    if (plan.forkCount > 0) ...[
      const SizedBox(height: 4),
      Text(
        l10n.lanSyncPlanForks(plan.forkCount),
        style: TextStyle(
          fontSize: 13,
          color: cs.onSurface.withValues(alpha: 0.6),
        ),
      ),
    ],
  ];
}
