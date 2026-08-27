import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as winweb;

import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';
import '../shared/widgets/ios_tactile.dart';
import '../shared/widgets/isolated_html_preview_document.dart';
import '../shared/widgets/snackbar.dart';
import '../theme/app_font_weights.dart';

Future<void> showHtmlPreviewDesktopDialog(
  BuildContext context, {
  required String html,
  bool isolated = false,
}) async {
  if (Platform.isLinux) {
    final l10n = AppLocalizations.of(context)!;
    showAppSnackBar(
      context,
      message: l10n.htmlPreviewNotSupportedOnLinux,
      type: NotificationType.warning,
    );
    return;
  }
  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _HtmlPreviewDialog(html: html, isolated: isolated),
  );
}

class _HtmlPreviewDialog extends StatefulWidget {
  const _HtmlPreviewDialog({required this.html, required this.isolated});

  final String html;
  final bool isolated;

  @override
  State<_HtmlPreviewDialog> createState() => _HtmlPreviewDialogState();
}

class _HtmlPreviewDialogState extends State<_HtmlPreviewDialog> {
  // macOS uses webview_flutter; Windows uses webview_windows.
  WebViewController? _flutterCtrl;
  winweb.WebviewController? _winCtrl;
  bool _ready = false;
  bool _loadedOnce = false;
  bool? _lastDark;
  final List<_ConsoleMessage> _console = <_ConsoleMessage>[];
  StreamSubscription? _msgSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (Platform.isWindows) {
      final c = winweb.WebviewController();
      await c.initialize();
      try {
        await c.setBackgroundColor(const Color(0x00000000));
      } catch (_) {}
      if (widget.isolated) {
        await c.setPopupWindowPolicy(winweb.WebviewPopupWindowPolicy.deny);
      }
      _winCtrl = c;
      // Listen to web messages (console bridge)
      if (!widget.isolated) {
        _msgSub = _winCtrl!.webMessage.listen((event) {
          try {
            String text;
            final dynamic e = event;
            if (e is String) {
              text = e;
            } else {
              text = (e.content?.toString() ?? e.toString());
            }
            final obj = json.decode(text) as Map<String, dynamic>;
            _pushConsole(
              level: (obj['level']?.toString() ?? 'log').toUpperCase(),
              message: obj['message']?.toString() ?? '',
              source: obj['source']?.toString(),
              line: (obj['line'] as num?)?.toInt(),
            );
          } catch (_) {}
        });
      }
      _ready = true;
      if (mounted) setState(() {});
    } else {
      final c = WebViewController(
        onPermissionRequest: widget.isolated
            ? (request) => unawaited(request.deny())
            : null,
      )..setJavaScriptMode(JavaScriptMode.unrestricted);
      if (widget.isolated) {
        c.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) =>
                isAllowedIsolatedHtmlPreviewUrl(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
          ),
        );
      } else {
        c.addJavaScriptChannel(
          'Console',
          onMessageReceived: (m) {
            try {
              final obj = json.decode(m.message) as Map<String, dynamic>;
              _pushConsole(
                level: (obj['level']?.toString() ?? 'log').toUpperCase(),
                message: obj['message']?.toString() ?? '',
                source: obj['source']?.toString(),
                line: (obj['line'] as num?)?.toInt(),
              );
            } catch (_) {
              _pushConsole(level: 'LOG', message: m.message);
            }
          },
        );
      }
      _flutterCtrl = c;
      _ready = true;
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadWithTheme();
  }

  Future<String> _writeTempHtml(String html) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/html_preview_${DateTime.now().millisecondsSinceEpoch}.html',
    );
    await file.writeAsString(html, flush: true);
    return file.path;
  }

  Future<void> _loadWithTheme() async {
    if (!_ready) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loadedOnce && _lastDark == isDark) return; // no change
    _lastDark = isDark;
    final html = widget.isolated
        ? buildIsolatedHtmlPreviewDocument(widget.html, isDark: isDark)
        : wrapHtmlPreviewDocument(widget.html, isDark: isDark);
    if (Platform.isWindows) {
      if (widget.isolated) {
        await _winCtrl?.loadStringContent(html);
      } else {
        final path = await _writeTempHtml(html);
        await _winCtrl?.loadUrl(Uri.file(path).toString());
      }
    } else {
      await _flutterCtrl?.loadHtmlString(html);
    }
    _loadedOnce = true;
    if (mounted) setState(() {});
  }

  void _pushConsole({
    required String level,
    required String message,
    String? source,
    int? line,
  }) {
    if (!mounted) return;
    setState(() {
      _console.add(
        _ConsoleMessage(
          level: level,
          message: message,
          source: source,
          line: line,
        ),
      );
      if (_console.length > 128) {
        _console.removeRange(0, _console.length - 128);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    // Keep content updated with theme changes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadWithTheme();
    });
    return Dialog(
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 520,
          maxWidth: 900,
          maxHeight: 740,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: cs.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      // Left title
                      Text(
                        l10n.assistantEditPreviewTitle,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                      ),
                      const Spacer(),
                      // Right function buttons
                      if (!widget.isolated) ...[
                        IosIconButton(
                          icon: Lucide.Terminal,
                          size: 18,
                          minSize: 34,
                          semanticLabel: l10n.messageWebViewConsoleLogs,
                          onTap: _openConsoleDialog,
                        ),
                        const SizedBox(width: 4),
                      ],
                      // Far right: close
                      IosIconButton(
                        icon: Lucide.X,
                        size: 18,
                        minSize: 34,
                        semanticLabel: l10n.mcpPageClose,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Builder(
                        builder: (context) {
                          if (Platform.isWindows) {
                            final c = _winCtrl;
                            if (c == null) return const SizedBox.shrink();
                            return winweb.Webview(
                              c,
                              permissionRequested: widget.isolated
                                  ? (_, _, _) =>
                                        winweb.WebviewPermissionDecision.deny
                                  : null,
                            );
                          }
                          final c = _flutterCtrl;
                          if (c == null) return const SizedBox.shrink();
                          return WebViewWidget(controller: c);
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    try {
      _msgSub?.cancel();
    } catch (_) {}
    try {
      _winCtrl?.dispose();
    } catch (_) {}
    super.dispose();
  }
}

extension _ConsoleDialogExt on _HtmlPreviewDialogState {
  void _openConsoleDialog() {
    final l10n = AppLocalizations.of(context)!;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.25),
      barrierLabel: 'console-logs',
      pageBuilder: (ctx, _, __) => _ConsoleDialog(
        title: l10n.messageWebViewConsoleLogs,
        messages: List<_ConsoleMessage>.from(_console),
      ),
      transitionBuilder: (ctx, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}

class _ConsoleDialog extends StatelessWidget {
  const _ConsoleDialog({required this.title, required this.messages});
  final String title;
  final List<_ConsoleMessage> messages;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      elevation: 12,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 520,
          maxWidth: 700,
          maxHeight: 620,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: cs.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                      ),
                      const Spacer(),
                      IosIconButton(
                        icon: Lucide.X,
                        size: 18,
                        minSize: 34,
                        semanticLabel: AppLocalizations.of(
                          context,
                        )!.mcpPageClose,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SelectionArea(
                      child: ListView.builder(
                        itemCount: messages.length,
                        itemBuilder: (ctx, i) {
                          final m = messages[i];
                          Color c;
                          switch (m.level) {
                            case 'ERROR':
                              c = cs.error;
                              break;
                            case 'WARN':
                            case 'WARNING':
                              c = cs.secondary;
                              break;
                            default:
                              c = cs.onSurface;
                              break;
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text(
                              '${m.level}: ${m.message}\nSource: ${m.source ?? ''}${m.line != null ? ':${m.line}' : ''}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: c, fontFamily: 'monospace'),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConsoleMessage {
  _ConsoleMessage({
    required this.level,
    required this.message,
    this.source,
    this.line,
  });
  final String level;
  final String message;
  final String? source;
  final int? line;
}

// (Bottom sheet version removed; desktop uses custom dialog.)
