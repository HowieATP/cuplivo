import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/isolated_html_preview_document.dart';

class HtmlPreviewPage extends StatefulWidget {
  const HtmlPreviewPage({super.key, required this.html, this.isolated = false});

  final String html;
  final bool isolated;

  @override
  State<HtmlPreviewPage> createState() => _HtmlPreviewPageState();
}

class _HtmlPreviewPageState extends State<HtmlPreviewPage> {
  late final WebViewController _controller;
  bool _didInit = false;

  @override
  void initState() {
    super.initState();
    final controller = WebViewController(
      onPermissionRequest: widget.isolated
          ? (request) => unawaited(request.deny())
          : null,
    )..setJavaScriptMode(JavaScriptMode.unrestricted);
    if (widget.isolated) {
      controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              isAllowedIsolatedHtmlPreviewUrl(request.url)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      );
    }
    _controller = controller;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Safe place to access Theme.of(context)
    if (!_didInit) {
      _didInit = true;
      unawaited(_loadHtml());
    } else {
      // Reload on theme changes
      unawaited(_loadHtml());
    }
  }

  Future<void> _loadHtml() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final html = widget.isolated
        ? buildIsolatedHtmlPreviewDocument(widget.html, isDark: isDark)
        : wrapHtmlPreviewDocument(widget.html, isDark: isDark);
    await _controller.loadHtmlString(html);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.assistantEditPreviewTitle)),
      body: SafeArea(child: WebViewWidget(controller: _controller)),
    );
  }
}
