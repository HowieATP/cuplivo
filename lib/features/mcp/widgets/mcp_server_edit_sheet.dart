import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/providers/settings_provider.dart';
import 'dart:math' as math;
import '../../../core/services/haptics.dart';
import '../../../core/services/oauth/oauth_flow_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../theme/app_font_weights.dart';
import 'mcp_oauth_section_controller.dart';

class _HeaderEntry {
  final TextEditingController key;
  final TextEditingController value;
  _HeaderEntry(this.key, this.value);
  void dispose() {
    key.dispose();
    value.dispose();
  }
}

Future<void> showMcpServerEditSheet(
  BuildContext context, {
  String? serverId,
}) async {
  final cs = Theme.of(context).colorScheme;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    // Match provider sheet corner radius
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _McpServerEditSheet(serverId: serverId),
  );
}

class _McpServerEditSheet extends StatefulWidget {
  const _McpServerEditSheet({this.serverId});
  final String? serverId;

  @override
  State<_McpServerEditSheet> createState() => _McpServerEditSheetState();
}

class _McpServerEditSheetState extends State<_McpServerEditSheet>
    with SingleTickerProviderStateMixin {
  late final bool isEdit = widget.serverId != null;
  TabController? _tab;

  bool _enabled = true;
  final _nameCtrl = TextEditingController();
  McpTransportType _transport = McpTransportType.http;
  final _urlCtrl = TextEditingController();
  final List<_HeaderEntry> _headers = [];
  int _heartbeatIntervalSeconds = 12;
  final _toolPrefixCtrl = TextEditingController();
  // OAuth section: shared logic lives in McpOAuthSectionController
  // (mobile sheet + desktop dialog reuse it). Built in
  // didChangeDependencies — constructing it needs AppLocalizations
  // (an inherited widget), which is illegal inside initState.
  late final McpOAuthSectionController _oauth;
  bool _oauthInitialized = false;

  @override
  void initState() {
    super.initState();
    if (isEdit) {
      _tab = TabController(length: 2, vsync: this);
      _tab!.addListener(_onTabChanged);
      final server = context.read<McpProvider>().getById(widget.serverId!)!;
      _enabled = server.enabled;
      _nameCtrl.text = server.name;
      _transport = server.transport;
      _urlCtrl.text = server.url;
      _heartbeatIntervalSeconds = server.heartbeatIntervalSeconds ?? 12;
      _toolPrefixCtrl.text = server.toolPrefix;
      server.headers.forEach((k, v) {
        _headers.add(
          _HeaderEntry(
            TextEditingController(text: k),
            TextEditingController(text: v),
          ),
        );
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_oauthInitialized) return;
    _oauthInitialized = true;
    _oauth =
        McpOAuthSectionController(
            beginFlowOp: (serverId) =>
                context.read<McpProvider>().beginOAuthFlow(serverId),
            completeFlowOp: (serverId, pasted) =>
                context.read<McpProvider>().completeOAuthFlow(serverId, pasted),
            clearTokenOp: (serverId) =>
                context.read<McpProvider>().clearOAuthToken(serverId),
            ensureServerIdOp: _ensureServerId,
            notify: (message, {isError = false}) {
              if (!mounted) return;
              showAppSnackBar(
                context,
                message: message,
                type: isError ? NotificationType.error : NotificationType.info,
              );
            },
            launch: (url) =>
                launchUrl(url, mode: LaunchMode.externalApplication),
            copyText: (text) => Clipboard.setData(ClipboardData(text: text)),
            errorMessage: _oauthErrorMessage,
            messages: _oauthMessages(context),
          )
          ..onChanged = () {
            if (mounted) setState(() {});
          };
    if (isEdit) {
      final server = context.read<McpProvider>().getById(widget.serverId!)!;
      _oauth.initFrom(server.oauth);
    }
  }

  /// Localized messages for the OAuth section.
  OAuthSectionMessages _oauthMessages(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return OAuthSectionMessages(
      notConfigured: l10n.mcpOAuthConfigIncomplete,
      urlCopied: l10n.mcpOAuthUrlCopied,
      flowStartFailed: l10n.mcpOAuthConfigIncomplete,
      success: l10n.mcpOAuthSuccess,
      tokenCleared: l10n.mcpOAuthTokenCleared,
    );
  }

  /// Maps an OAuth error code (plus server detail) to a localized message.
  String _oauthErrorMessage(OAuthFlowErrorCode code, String detail) {
    final l10n = AppLocalizations.of(context)!;
    final base = switch (code) {
      OAuthFlowErrorCode.noSession => l10n.mcpOAuthErrorNoSession,
      OAuthFlowErrorCode.noCode => l10n.mcpOAuthErrorNoCode,
      OAuthFlowErrorCode.stateMismatch => l10n.mcpOAuthErrorStateMismatch,
      OAuthFlowErrorCode.verifierLost => l10n.mcpOAuthErrorVerifierLost,
      OAuthFlowErrorCode.exchangeFailed => l10n.mcpOAuthErrorExchangeFailed,
      OAuthFlowErrorCode.callbackTimeout => l10n.mcpOAuthErrorCallbackTimeout,
      OAuthFlowErrorCode.authorizationDenied =>
        l10n.mcpOAuthErrorAuthorizationDenied,
    };
    // Show the raw server detail (error_description) for exchange
    // failures — the generic message hides the root cause.
    if (code == OAuthFlowErrorCode.exchangeFailed && detail.isNotEmpty) {
      return '$base\n$detail';
    }
    return base;
  }

  /// Persists the current form so an OAuth flow has a server id.
  /// No-op when already editing an existing server.
  Future<String> _ensureServerId(McpOAuthConfig oauth) async {
    if (isEdit) return widget.serverId!;
    final existing = _oauth.createdId;
    if (existing != null) return existing;
    final mcp = context.read<McpProvider>();
    final id = await mcp.addServer(
      enabled: _enabled,
      name: _nameCtrl.text.trim().isEmpty ? 'MCP' : _nameCtrl.text.trim(),
      transport: _transport,
      url: _urlCtrl.text.trim(),
      headers: {
        for (final h in _headers)
          if (h.key.text.trim().isNotEmpty)
            h.key.text.trim(): h.value.text.trim(),
      },
      heartbeatIntervalSeconds: _heartbeatIntervalSeconds == 12
          ? null
          : _heartbeatIntervalSeconds,
      toolPrefix: _toolPrefixCtrl.text.trim(),
      oauth: oauth,
    );
    _oauth.createdId = id;
    return id;
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tab?.removeListener(_onTabChanged);
    _tab?.dispose();
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    for (final h in _headers) {
      h.dispose();
    }
    _toolPrefixCtrl.dispose();
    _oauth.dispose();
    super.dispose();
  }

  // Match provider sheet switch row style
  Widget _switchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 14, fontWeight: AppFontWeights.medium),
          ),
        ),
        IosSwitch(value: value, onChanged: onChanged),
      ],
    );
  }

  // Simple iOS-style card wrapper, same as provider sheet
  Widget _iosCard({required List<Widget> children}) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
          width: 0.6,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          children: [
            for (int i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 10,
                  thickness: 0.6,
                  color: cs.outlineVariant.withValues(alpha: 0.18),
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _inputRow({
    required String label,
    required TextEditingController controller,
    String? hint,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: cs.onSurface.withValues(alpha: 0.8),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            // Match provider sheet input background
            fillColor: isDark ? Colors.white10 : Colors.white,
            // Match provider sheet border styles
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.5)),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
          ),
        ),
      ],
    );
  }

  // Segmented choice bar (like top tabs), used for transport type
  Widget _transportPicker() {
    final labels = ['Streamable HTTP', 'SSE'];
    final idx = _transport == McpTransportType.http ? 0 : 1;
    return _SegChoiceBar(
      labels: labels,
      selectedIndex: idx,
      onSelected: (i) => setState(
        () =>
            _transport = i == 0 ? McpTransportType.http : McpTransportType.sse,
      ),
    );
  }

  static const _heartbeatOptions = [12, 30, 60, 120, 300];

  Widget _heartbeatPicker() {
    final labels = _heartbeatOptions.map((s) => '${s}s').toList();
    final idx = _heartbeatOptions.indexOf(_heartbeatIntervalSeconds);
    final selected = idx >= 0 ? idx : 0;
    return _SegChoiceBar(
      labels: labels,
      selectedIndex: selected,
      onSelected: (i) =>
          setState(() => _heartbeatIntervalSeconds = _heartbeatOptions[i]),
    );
  }

  Widget _basicForm() {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isBuiltin = isEdit && _transport == McpTransportType.inmemory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _iosCard(
          children: [
            _switchRow(
              label: l10n.mcpServerEditSheetEnabledLabel,
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (isBuiltin)
          _iosCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Text(
                      l10n.mcpServerEditSheetNameLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: AppFontWeights.medium,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _nameCtrl.text,
                        style: TextStyle(fontWeight: AppFontWeights.semibold),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          )
        else ...[
          _inputRow(
            label: l10n.mcpServerEditSheetNameLabel,
            controller: _nameCtrl,
            hint: 'My MCP',
          ),
          const SizedBox(height: 10),
          Text(
            l10n.mcpServerEditSheetTransportLabel,
            style: TextStyle(fontSize: 13, fontWeight: AppFontWeights.medium),
          ),
          const SizedBox(height: 6),
          _transportPicker(),
          const SizedBox(height: 10),
          if (_transport == McpTransportType.sse) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                l10n.mcpServerEditSheetSseRetryHint,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
          _inputRow(
            label: l10n.mcpServerEditSheetUrlLabel,
            controller: _urlCtrl,
            hint: _transport == McpTransportType.sse
                ? 'http://localhost:3000/sse'
                : 'http://localhost:3000',
          ),
          _oauthSection(),
          const SizedBox(height: 16),
          Text(
            l10n.mcpServerEditSheetHeartbeatLabel,
            style: TextStyle(fontSize: 13, fontWeight: AppFontWeights.semibold),
          ),
          const SizedBox(height: 6),
          _heartbeatPicker(),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.mcpServerEditSheetHeartbeatHint,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _inputRow(
            label: l10n.mcpServerEditSheetToolPrefixLabel,
            controller: _toolPrefixCtrl,
            hint: l10n.mcpServerEditSheetToolPrefixHint,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.mcpServerEditSheetCustomHeadersTitle,
            style: TextStyle(fontSize: 13, fontWeight: AppFontWeights.semibold),
          ),
          const SizedBox(height: 8),
          _headersEditor(),
        ],
      ],
    );
  }

  Widget _headersEditor() {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < _headers.length; i++) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white10
                  : const Color(0xFFF7F7F9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.2),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _inputRow(
                  label: l10n.mcpServerEditSheetHeaderNameLabel,
                  controller: _headers[i].key,
                  hint: l10n.mcpServerEditSheetHeaderNameHint,
                ),
                const SizedBox(height: 10),
                _inputRow(
                  label: l10n.mcpServerEditSheetHeaderValueLabel,
                  controller: _headers[i].value,
                  hint: l10n.mcpServerEditSheetHeaderValueHint,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: _TactileIconButton(
                    icon: Lucide.Trash,
                    color: cs.error,
                    semanticLabel: l10n.mcpServerEditSheetRemoveHeaderTooltip,
                    onTap: () => setState(() => _headers.removeAt(i)),
                  ),
                ),
              ],
            ),
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: IosTileButton(
            icon: Lucide.Plus,
            label: l10n.mcpServerEditSheetAddHeader,
            backgroundColor: cs.primary,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            onTap: () => setState(
              () => _headers.add(
                _HeaderEntry(TextEditingController(), TextEditingController()),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onSave() async {
    final mcp = context.read<McpProvider>();
    // Built-in: only toggle enabled
    if (isEdit && _transport == McpTransportType.inmemory) {
      final old = mcp.getById(widget.serverId!)!;
      await mcp.updateServer(old.copyWith(enabled: _enabled));
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final name = _nameCtrl.text.trim().isEmpty ? 'MCP' : _nameCtrl.text.trim();
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.mcpServerEditSheetUrlRequired,
        type: NotificationType.warning,
      );
      return;
    }
    final headers = <String, String>{
      for (final h in _headers)
        if (h.key.text.trim().isNotEmpty)
          h.key.text.trim(): h.value.text.trim(),
    };
    final toolPrefix = _toolPrefixCtrl.text.trim();
    final oauth = _oauth.buildConfig();
    if (isEdit) {
      final old = mcp.getById(widget.serverId!)!;
      await mcp.updateServer(
        old.copyWith(
          enabled: _enabled,
          name: name,
          transport: _transport,
          url: url,
          headers: headers,
          heartbeatIntervalSeconds: _heartbeatIntervalSeconds,
          clearHeartbeatIntervalSeconds: _heartbeatIntervalSeconds == 12,
          toolPrefix: toolPrefix,
          oauth: oauth,
          clearOauth: oauth == null,
          // A token without an OAuth config is dead data — drop it when
          // the switch is turned off.
          clearOauthToken: oauth == null,
        ),
      );
    } else if (_oauth.createdId != null) {
      // The flow already persisted this server (开始授权) — update it in
      // place instead of creating a second copy.
      final created = mcp.getById(_oauth.createdId!)!;
      await mcp.updateServer(
        created.copyWith(
          enabled: _enabled,
          name: name,
          transport: _transport,
          url: url,
          headers: headers,
          heartbeatIntervalSeconds: _heartbeatIntervalSeconds,
          clearHeartbeatIntervalSeconds: _heartbeatIntervalSeconds == 12,
          toolPrefix: toolPrefix,
          oauth: oauth,
          clearOauth: oauth == null,
          clearOauthToken: oauth == null,
        ),
      );
    } else {
      await mcp.addServer(
        enabled: _enabled,
        name: name,
        transport: _transport,
        url: url,
        headers: headers,
        heartbeatIntervalSeconds: _heartbeatIntervalSeconds == 12
            ? null
            : _heartbeatIntervalSeconds,
        toolPrefix: toolPrefix,
        oauth: oauth,
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// Formats the expiry as time-only when it falls on today, otherwise
  /// date + time (a short-lived token authorized near midnight would
  /// otherwise look like a past time).
  String _formatExpiry(BuildContext context, DateTime expires) {
    final loc = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final time = loc.formatTimeOfDay(TimeOfDay.fromDateTime(expires));
    final sameDay =
        expires.year == now.year &&
        expires.month == now.month &&
        expires.day == now.day;
    if (sameDay) return time;
    return '${expires.month}/${expires.day} $time';
  }

  /// OAuth authorization section (HTTP/SSE only).
  ///
  /// Gated by an explicit switch: when off the whole section collapses and
  /// saving clears both config and token. When on the primary action
  /// ([开始授权]) shows first; the advanced fields collapse behind
  /// "高级配置" and are only needed when auto-discovery fails.
  Widget _oauthSection() {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final mcp = context.watch<McpProvider>();
    final server = isEdit
        ? mcp.getById(widget.serverId!)
        : (_oauth.createdId != null ? mcp.getById(_oauth.createdId!) : null);
    final token = server?.oauthToken;
    final expires = token?.expiresAt;
    final expired = _oauth.isTokenExpired(expires);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.mcpOAuthSectionTitle,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: AppFontWeights.semibold,
                ),
              ),
            ),
            IosSwitch(
              value: _oauth.enabled,
              onChanged: (v) => setState(() => _oauth.enabled = v),
            ),
          ],
        ),
        if (_oauth.enabled) ...[
          const SizedBox(height: 8),
          if (server != null && server.oauth != null) ...[
            Row(
              children: [
                Icon(
                  token == null || expired
                      ? Lucide.TriangleAlert
                      : Lucide.circleCheckBig,
                  size: 14,
                  color: token == null || expired ? cs.error : Colors.green,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    token == null
                        ? l10n.mcpOAuthStatusUnauthorized
                        : expired
                        ? l10n.mcpOAuthStatusExpired
                        : l10n.mcpOAuthStatusAuthorized(
                            expires == null
                                ? '--:--'
                                : _formatExpiry(context, expires),
                          ),
                    style: TextStyle(
                      fontSize: 12,
                      color: token == null || expired
                          ? cs.error
                          : cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                if (token != null)
                  _TactileIconButton(
                    icon: Lucide.KeyRound,
                    color: cs.onSurface,
                    semanticLabel: l10n.mcpOAuthClearTokenButton,
                    onTap: () => _oauth.clearTokenFor(server),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (_oauth.flowStarted) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _oauth.autoMode
                    ? l10n.mcpOAuthAutoWaitHint
                    : l10n.mcpOAuthBrowserHint,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
            _inputRow(
              label: l10n.mcpOAuthCompleteButton,
              controller: _oauth.pasteCtrl,
              hint: l10n.mcpOAuthPasteHint,
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: IosTileButton(
                icon: Lucide.Check,
                label: l10n.mcpOAuthCompleteButton,
                backgroundColor: cs.primary,
                enabled: !_oauth.completing,
                onTap: () => _oauth.completeFlow(
                  _oauth.createdId ?? widget.serverId ?? '',
                ),
              ),
            ),
          ] else ...[
            // Primary action first: one-tap start for normal users.
            SizedBox(
              width: double.infinity,
              child: IosTileButton(
                icon: Lucide.Shield,
                label: token == null
                    ? l10n.mcpOAuthStartButton
                    : l10n.mcpOAuthReauthorizeButton,
                backgroundColor: cs.primary,
                onTap: _oauth.startFlow,
              ),
            ),
            const SizedBox(height: 8),
            // Advanced config collapsed below; only needed when the server
            // does not support auto-discovery / auto-registration.
            _TactileRow(
              onTap: () => setState(
                () => _oauth.advancedExpanded = !_oauth.advancedExpanded,
              ),
              builder: (pressed) => Row(
                children: [
                  Icon(
                    _oauth.advancedExpanded
                        ? Lucide.ChevronDown
                        : Lucide.ChevronRight,
                    size: 16,
                    color: pressed
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l10n.mcpOAuthAdvancedConfig,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: AppFontWeights.medium,
                      color: pressed
                          ? cs.primary
                          : cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            if (_oauth.advancedExpanded) ...[
              const SizedBox(height: 8),
              _inputRow(
                label: l10n.mcpOAuthAuthEndpointLabel,
                controller: _oauth.authEndpointCtrl,
                hint: 'https://auth.example.com/authorize',
              ),
              const SizedBox(height: 10),
              _inputRow(
                label: l10n.mcpOAuthTokenEndpointLabel,
                controller: _oauth.tokenEndpointCtrl,
                hint: 'https://auth.example.com/token',
              ),
              const SizedBox(height: 10),
              _inputRow(
                label: l10n.mcpOAuthClientIdLabel,
                controller: _oauth.clientIdCtrl,
              ),
              const SizedBox(height: 10),
              _inputRow(
                label: l10n.mcpOAuthClientSecretLabel,
                controller: _oauth.clientSecretCtrl,
              ),
              const SizedBox(height: 10),
              _inputRow(
                label: l10n.mcpOAuthScopesLabel,
                controller: _oauth.scopesCtrl,
              ),
              const SizedBox(height: 10),
              _inputRow(
                label: l10n.mcpOAuthRedirectUriLabel,
                controller: _oauth.redirectUriCtrl,
              ),
            ],
          ],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final mcp = context.watch<McpProvider>();
    final server = isEdit ? mcp.getById(widget.serverId!) : null;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: isEdit ? 0.85 : 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.5,
          builder: (c, controller) => Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 12),
              // Header: centered title with close on the left (match provider sheet)
              SizedBox(
                height: 36,
                child: Stack(
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: Text(
                        isEdit
                            ? l10n.mcpServerEditSheetTitleEdit
                            : l10n.mcpServerEditSheetTitleAdd,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _TactileIconButton(
                          icon: Lucide.X,
                          color: cs.onSurface,
                          size: 22,
                          semanticLabel: l10n.mcpPageCancel,
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                    ),
                    if (isEdit)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _TactileIconButton(
                            icon: Lucide.RefreshCw,
                            color: cs.primary,
                            semanticLabel:
                                l10n.mcpServerEditSheetSyncToolsTooltip,
                            onTap: () => mcp.refreshTools(widget.serverId!),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (isEdit) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _SegTabBar(
                    controller: _tab!,
                    tabs: [
                      l10n.mcpServerEditSheetTabBasic,
                      l10n.mcpServerEditSheetTabTools,
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ListView(
                    controller: controller,
                    children: [
                      if (!isEdit) _basicForm(),
                      if (isEdit) ...[
                        AnimatedBuilder(
                          animation: _tab!,
                          builder: (_, __) {
                            final idx = _tab!.index;
                            if (idx == 0) {
                              return _basicForm();
                            } else {
                              // Tools tab
                              final tools =
                                  server?.tools ?? const <McpToolConfig>[];
                              if (tools.isEmpty) {
                                return Padding(
                                  padding: const EdgeInsets.only(top: 20),
                                  child: Center(
                                    child: Text(
                                      l10n.mcpServerEditSheetNoToolsHint,
                                      style: TextStyle(
                                        color: cs.onSurface.withValues(
                                          alpha: 0.6,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return Column(
                                children: [
                                  for (final tool in tools) ...[
                                    Container(
                                      margin: const EdgeInsets.only(bottom: 10),
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color:
                                            Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? Colors.white10
                                            : const Color(0xFFF7F7F9),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: cs.outlineVariant.withValues(
                                            alpha: 0.2,
                                          ),
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      tool.name,
                                                      style: TextStyle(
                                                        fontWeight:
                                                            AppFontWeights
                                                                .emphasis,
                                                      ),
                                                    ),
                                                    if ((tool.description ?? '')
                                                        .isNotEmpty) ...[
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        tool.description!,
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          color: cs.onSurface
                                                              .withValues(
                                                                alpha: 0.7,
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                                    if (tool
                                                        .params
                                                        .isNotEmpty) ...[
                                                      const SizedBox(height: 8),
                                                      Wrap(
                                                        spacing: 6,
                                                        runSpacing: 6,
                                                        children: tool.params.map((
                                                          p,
                                                        ) {
                                                          final color =
                                                              p.required
                                                              ? cs.primary
                                                              : cs.onSurface
                                                                    .withValues(
                                                                      alpha:
                                                                          0.5,
                                                                    );
                                                          final bg = p.required
                                                              ? cs.primary
                                                                    .withValues(
                                                                      alpha:
                                                                          0.12,
                                                                    )
                                                              : cs.onSurface
                                                                    .withValues(
                                                                      alpha:
                                                                          0.06,
                                                                    );
                                                          return Container(
                                                            padding:
                                                                const EdgeInsets.symmetric(
                                                                  horizontal: 8,
                                                                  vertical: 2,
                                                                ),
                                                            decoration: BoxDecoration(
                                                              color: bg,
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    999,
                                                                  ),
                                                              border: Border.all(
                                                                color: color
                                                                    .withValues(
                                                                      alpha:
                                                                          0.5,
                                                                    ),
                                                              ),
                                                            ),
                                                            child: Text(
                                                              p.name,
                                                              style: TextStyle(
                                                                fontSize: 11,
                                                                color: color,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                              ),
                                                            ),
                                                          );
                                                        }).toList(),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                              IosSwitch(
                                                value: tool.enabled,
                                                onChanged: (v) => context
                                                    .read<McpProvider>()
                                                    .setToolEnabled(
                                                      server!.id,
                                                      tool.name,
                                                      v,
                                                    ),
                                              ),
                                            ],
                                          ),
                                          // Approval toggle — compact row inside the card
                                          if (tool.enabled) ...[
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 8,
                                              ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Lucide.Shield,
                                                    size: 13,
                                                    color: tool.needsApproval
                                                        ? cs.primary
                                                        : cs.onSurface
                                                              .withValues(
                                                                alpha: 0.4,
                                                              ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    child: Text(
                                                      l10n.mcpToolNeedsApproval,
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: cs.onSurface
                                                            .withValues(
                                                              alpha: 0.6,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                  IosSwitch(
                                                    value: tool.needsApproval,
                                                    onChanged: (v) => context
                                                        .read<McpProvider>()
                                                        .setToolNeedsApproval(
                                                          server!.id,
                                                          tool.name,
                                                          v,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                ],
                              );
                            }
                          },
                        ),
                      ],
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: IosTileButton(
                    icon: isEdit ? Lucide.Check : Lucide.Plus,
                    label: l10n.mcpServerEditSheetSave,
                    backgroundColor: cs.primary,
                    onTap: _onSave,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- iOS tactile helpers (no ripple) ---

class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.semanticLabel,
    this.size = 20,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String? semanticLabel;
  final double size;
  @override
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final press = base.withValues(alpha: 0.7);
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          Haptics.light();
          widget.onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            widget.icon,
            size: widget.size,
            color: _pressed ? press : base,
          ),
        ),
      ),
    );
  }
}

class _TactileRow extends StatefulWidget {
  const _TactileRow({required this.builder, this.onTap});
  final Widget Function(bool pressed) builder;
  final VoidCallback? onTap;
  @override
  State<_TactileRow> createState() => _TactileRowState();
}

class _TactileRowState extends State<_TactileRow> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null
          ? null
          : (_) {
              /* keep pressed a bit for better feel */
            },
      onTapCancel: widget.onTap == null ? null : () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (context.read<SettingsProvider>().hapticsOnListItemTap) {
                Haptics.soft();
              }
              widget.onTap!.call();
              Future.delayed(const Duration(milliseconds: 120), () {
                if (mounted) _set(false);
              });
            },
      child: AnimatedScale(
        scale: 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: widget.builder(_pressed),
      ),
    );
  }
}

// Generic segmented choice bar (visual style matches provider segmented tabs)
class _SegChoiceBar extends StatelessWidget {
  const _SegChoiceBar({
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    const double outerHeight = 44;
    const double innerPadding = 4;
    const double gap = 6;
    const double minSegWidth = 88;
    final double pillRadius = 18;
    final double innerRadius = ((pillRadius - innerPadding).clamp(
      0.0,
      pillRadius,
    )).toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        final double availWidth = constraints.maxWidth;
        final double innerAvailWidth = availWidth - innerPadding * 2;
        final double segWidth = math.max(
          minSegWidth,
          (innerAvailWidth - gap * (labels.length - 1)) / labels.length,
        );
        final double rowWidth =
            segWidth * labels.length + gap * (labels.length - 1);

        final Color shellBg = isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white;

        List<Widget> children = [];
        for (int index = 0; index < labels.length; index++) {
          final bool selected = selectedIndex == index;
          children.add(
            SizedBox(
              width: segWidth,
              height: double.infinity,
              child: _TactileRow(
                onTap: () => onSelected(index),
                builder: (pressed) {
                  final Color baseBg = selected
                      ? cs.primary.withValues(alpha: 0.14)
                      : Colors.transparent;
                  final Color bg = baseBg;
                  final Color baseTextColor = selected
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: 0.82);
                  final Color targetTextColor = pressed
                      ? Color.lerp(baseTextColor, Colors.white, 0.22) ??
                            baseTextColor
                      : baseTextColor;

                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(innerRadius),
                    ),
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: TweenAnimationBuilder<Color?>(
                        tween: ColorTween(end: targetTextColor),
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        builder: (context, color, _) {
                          return Text(
                            labels[index],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color ?? baseTextColor,
                              fontWeight: AppFontWeights.medium,
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          if (index != labels.length - 1) {
            children.add(const SizedBox(width: gap));
          }
        }

        return Container(
          height: outerHeight,
          decoration: BoxDecoration(
            color: shellBg,
            borderRadius: BorderRadius.circular(pillRadius),
          ),
          clipBehavior: Clip.hardEdge,
          child: Padding(
            padding: const EdgeInsets.all(innerPadding),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: innerAvailWidth),
                child: SizedBox(
                  width: rowWidth,
                  child: Row(children: children),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// Copy of provider segmented tab to match style
class _SegTabBar extends StatelessWidget {
  const _SegTabBar({required this.controller, required this.tabs});
  final TabController controller;
  final List<String> tabs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    const double outerHeight = 44;
    const double innerPadding = 4;
    const double gap = 6;
    const double minSegWidth = 88;
    final double pillRadius = 18;
    final double innerRadius = ((pillRadius - innerPadding).clamp(
      0.0,
      pillRadius,
    )).toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        final double availWidth = constraints.maxWidth;
        final double innerAvailWidth = availWidth - innerPadding * 2;
        final double segWidth = math.max(
          minSegWidth,
          (innerAvailWidth - gap * (tabs.length - 1)) / tabs.length,
        );
        final double rowWidth =
            segWidth * tabs.length + gap * (tabs.length - 1);

        final Color shellBg = isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white;

        List<Widget> children = [];
        for (int index = 0; index < tabs.length; index++) {
          final bool selected = controller.index == index;
          children.add(
            SizedBox(
              width: segWidth,
              height: double.infinity,
              child: _TactileRow(
                onTap: () => controller.animateTo(index),
                builder: (pressed) {
                  // Background does not change on press; only selected shows subtle tint
                  final Color baseBg = selected
                      ? cs.primary.withValues(alpha: 0.14)
                      : Colors.transparent;
                  final Color bg = baseBg;

                  // Text color lightens slightly on press
                  final Color baseTextColor = selected
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: 0.82);
                  final Color targetTextColor = pressed
                      ? Color.lerp(baseTextColor, Colors.white, 0.22) ??
                            baseTextColor
                      : baseTextColor;

                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(innerRadius),
                    ),
                    alignment: Alignment.center,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: TweenAnimationBuilder<Color?>(
                        tween: ColorTween(end: targetTextColor),
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        builder: (context, color, _) {
                          return Text(
                            tabs[index],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color ?? baseTextColor,
                              fontWeight: AppFontWeights.medium,
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          if (index != tabs.length - 1) {
            children.add(const SizedBox(width: gap));
          }
        }

        return Container(
          height: outerHeight,
          decoration: BoxDecoration(
            color: shellBg,
            borderRadius: BorderRadius.circular(pillRadius),
          ),
          clipBehavior: Clip.hardEdge,
          child: Padding(
            padding: const EdgeInsets.all(innerPadding),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: innerAvailWidth),
                child: SizedBox(
                  width: rowWidth,
                  child: Row(children: children),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
