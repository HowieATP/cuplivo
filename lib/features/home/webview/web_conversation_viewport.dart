import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as winweb;

import '../../../core/services/streaming_content_notifier.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../controllers/conversation_viewport_port.dart';
import 'android_web_chat_view.dart';
import 'web_chat_protocol.dart';
import 'web_chat_snapshot.dart';

typedef WebChatActionHandler =
    Future<void> Function(WebChatActionRequest request);
typedef WebChatStreamingPatchBuilder =
    Map<String, dynamic>? Function(String messageId, StreamingContentData data);

class WebConversationViewport extends StatefulWidget {
  const WebConversationViewport({
    super.key,
    required this.snapshot,
    required this.mediaRegistry,
    required this.viewportPort,
    required this.streamingContentNotifier,
    required this.buildStreamingPatch,
    required this.onAction,
    required this.onUseFlutter,
    required this.onUserScrollIntent,
  });

  final Map<String, dynamic> snapshot;
  final Map<String, WebChatMediaSource> mediaRegistry;
  final WebConversationViewportPort viewportPort;
  final StreamingContentNotifier streamingContentNotifier;
  final WebChatStreamingPatchBuilder buildStreamingPatch;
  final WebChatActionHandler onAction;
  final VoidCallback onUseFlutter;
  final VoidCallback onUserScrollIntent;

  @override
  State<WebConversationViewport> createState() =>
      _WebConversationViewportState();
}

class _WebConversationViewportState extends State<WebConversationViewport> {
  static const Duration _initializationTimeout = Duration(seconds: 10);
  static const String _webView2Url =
      'https://developer.microsoft.com/microsoft-edge/webview2/';
  static const List<String> _windowsAssets = <String>[
    'index.html',
    'styles.css',
    'app.mjs',
    'protocol.mjs',
    'vendor/marked.min.js',
    'vendor/purify.min.js',
    'vendor/highlight.min.js',
    'vendor/github.min.css',
    'vendor/katex.min.js',
    'vendor/katex.min.css',
    'vendor/auto-render.min.js',
  ];

  WebViewController? _flutterController;
  AndroidWebChatController? _androidController;
  winweb.WebviewController? _windowsController;
  StreamSubscription<dynamic>? _windowsMessageSubscription;
  final Map<String, VoidCallback> _streamListeners = <String, VoidCallback>{};
  final WebChatStreamingPatchBuffer _streamPatchBuffer =
      WebChatStreamingPatchBuffer();
  Timer? _streamFlushTimer;
  Timer? _initializationTimer;
  bool _ready = false;
  bool _initializing = false;
  bool _webView2Missing = false;
  int _generation = 0;
  String? _errorCode;
  late final String _capabilityToken = _randomCapabilityToken();
  late WebChatActionGate _actionGate = _newActionGate();
  late final WebViewportCommandSender _viewportCommandSender =
      _sendViewportCommand;

  String get _renderSessionId =>
      widget.snapshot['renderSessionId']?.toString() ?? '';
  String get _conversationId =>
      widget.snapshot['conversationId']?.toString() ?? '';
  int get _actionEpoch =>
      (widget.snapshot['actionEpoch'] as num?)?.toInt() ?? 0;

  @override
  void initState() {
    super.initState();
    widget.viewportPort.attach(_viewportCommandSender);
    _syncStreamingListeners();
    _initialize();
  }

  @override
  void didUpdateWidget(covariant WebConversationViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sessionChanged =
        oldWidget.snapshot['renderSessionId'] !=
            widget.snapshot['renderSessionId'] ||
        oldWidget.snapshot['conversationId'] !=
            widget.snapshot['conversationId'];
    if (sessionChanged ||
        oldWidget.snapshot['actionEpoch'] != widget.snapshot['actionEpoch']) {
      _actionGate = _newActionGate();
    }
    if (sessionChanged) {
      _streamFlushTimer?.cancel();
      _streamFlushTimer = null;
      _streamPatchBuffer.clear();
    }
    if (!identical(oldWidget.viewportPort, widget.viewportPort)) {
      oldWidget.viewportPort.detach(_viewportCommandSender);
      widget.viewportPort.attach(_viewportCommandSender);
    }
    _syncStreamingListeners();
    if (_ready) unawaited(_sendSnapshot());
  }

  @override
  void dispose() {
    _generation++;
    _initializationTimer?.cancel();
    _streamFlushTimer?.cancel();
    _streamPatchBuffer.clear();
    _detachStreamingListeners();
    widget.viewportPort.detach(_viewportCommandSender);
    unawaited(_windowsMessageSubscription?.cancel());
    final controller = _windowsController;
    _windowsController = null;
    if (controller != null) {
      unawaited(
        controller.dispose().catchError((Object error) {
          debugPrint(
            'WebConversationViewport: Windows dispose failed '
            '(${error.runtimeType})',
          );
        }),
      );
    }
    _androidController?.dispose();
    _androidController = null;
    _flutterController = null;
    super.dispose();
  }

  WebChatActionGate _newActionGate() => WebChatActionGate(
    renderSessionId: _renderSessionId,
    conversationId: _conversationId,
    actionEpoch: _actionEpoch,
  );

  Future<void> _initialize() async {
    if (_initializing || _ready) return;
    _initializing = true;
    _errorCode = null;
    _webView2Missing = false;
    if (mounted) setState(() {});
    final generation = ++_generation;
    _initializationTimer?.cancel();
    _initializationTimer = Timer(_initializationTimeout, () {
      debugPrint('WebConversationViewport: shell ready timed out');
      _fail(generation, 'shell_ready_timeout');
    });
    try {
      if (Platform.isWindows) {
        await _initializeWindows(generation);
      } else if (Platform.isAndroid) {
        // The Android platform view loads the shell once it is attached.
      } else {
        await _initializeFlutterWebView(generation);
      }
    } on TimeoutException {
      debugPrint('WebConversationViewport: initialization timed out');
      _fail(generation, 'initialization_timeout');
    } on PlatformException catch (error) {
      debugPrint(
        'WebConversationViewport: platform initialization failed: '
        '${error.code}',
      );
      _fail(generation, 'platform_${error.code}');
    } catch (error) {
      debugPrint(
        'WebConversationViewport: initialization failed '
        '(${error.runtimeType})',
      );
      _fail(generation, 'initialization_failed');
    }
  }

  Future<void> _initializeWindows(int generation) async {
    final version = await winweb.WebviewController.getWebViewVersion().timeout(
      _initializationTimeout,
    );
    if (version == null || version.isEmpty) {
      _webView2Missing = true;
      throw const WebChatProtocolException('webview2_runtime_missing');
    }
    final controller = winweb.WebviewController();
    await controller.initialize().timeout(_initializationTimeout);
    if (_isStale(generation)) {
      await controller.dispose();
      return;
    }
    await controller.setBackgroundColor(const Color(0x00000000));
    await controller.setPopupWindowPolicy(winweb.WebviewPopupWindowPolicy.deny);
    _windowsMessageSubscription = controller.webMessage.listen(
      (dynamic event) => _handleBridgeMessage(_windowsMessageText(event)),
      onError: (Object error) {
        debugPrint(
          'WebConversationViewport: Windows bridge failed '
          '(${error.runtimeType})',
        );
      },
    );
    final shell = await _prepareWindowsShell();
    _windowsController = controller;
    await controller.loadUrl(Uri.file(shell.path).toString());
  }

  Future<void> _initializeFlutterWebView(int generation) async {
    final controller =
        WebViewController(
            onPermissionRequest: (request) => unawaited(request.deny()),
          )
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(const Color(0x00000000))
          ..setNavigationDelegate(
            NavigationDelegate(
              onNavigationRequest: (request) {
                if (!request.isMainFrame || _isLocalShellUrl(request.url)) {
                  return NavigationDecision.navigate;
                }
                unawaited(_openExternalUrl(request.url));
                return NavigationDecision.prevent;
              },
              onWebResourceError: (error) {
                if (error.isForMainFrame != true) return;
                debugPrint(
                  'WebConversationViewport: shell resource failed: '
                  '${error.errorCode}',
                );
                _fail(generation, 'resource_${error.errorCode}');
              },
            ),
          )
          ..addJavaScriptChannel(
            'CuplivoChat',
            onMessageReceived: (message) =>
                _handleBridgeMessage(message.message),
          );
    if (_isStale(generation)) return;
    _flutterController = controller;
    await controller.loadFlutterAsset('assets/web_chat/index.html');
  }

  Future<void> _handleAndroidViewCreated(int viewId, int generation) async {
    if (_isStale(generation)) return;
    final oldController = _androidController;
    final controller = AndroidWebChatController.attach(
      viewId: viewId,
      onMessage: _handleBridgeMessage,
      onResourceError: (errorCode) {
        debugPrint(
          'WebConversationViewport: Android shell resource failed: '
          '$errorCode',
        );
        _fail(generation, 'resource_$errorCode');
      },
      onNavigationRequest: (url) => unawaited(_openExternalUrl(url)),
      onDiagnostic: (code) {
        debugPrint('WebConversationViewport: Android diagnostic $code');
        if (code == 'render_process_gone') {
          _fail(generation, code);
        }
      },
    );
    _androidController = controller;
    oldController?.dispose();
    try {
      await controller.loadShell();
    } on PlatformException catch (error) {
      debugPrint(
        'WebConversationViewport: Android shell initialization failed: '
        '${error.code}',
      );
      _fail(generation, 'platform_${error.code}');
    } catch (error) {
      debugPrint(
        'WebConversationViewport: Android shell initialization failed '
        '(${error.runtimeType})',
      );
      _fail(generation, 'initialization_failed');
    }
  }

  bool _isLocalShellUrl(String url) =>
      url.startsWith('file:') ||
      url.startsWith('data:') ||
      url.startsWith('about:') ||
      url.startsWith('https://appassets.androidplatform.net/');

  Future<File> _prepareWindowsShell() async {
    final temp = await getTemporaryDirectory();
    final directory = Directory(
      '${temp.path}${Platform.pathSeparator}cuplivo_web_chat_$webChatAssetVersion',
    );
    await directory.create(recursive: true);
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final relativeAssets = <String>{
      ..._windowsAssets,
      for (final asset in manifest.listAssets())
        if (asset.startsWith('assets/web_chat/vendor/fonts/'))
          asset.substring('assets/web_chat/'.length),
    };
    for (final relative in relativeAssets) {
      final data = await rootBundle.load('assets/web_chat/$relative');
      final output = File(
        '${directory.path}${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}',
      );
      await output.parent.create(recursive: true);
      await output.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    final mermaid = await rootBundle.load('assets/mermaid.min.js');
    await File(
      '${directory.parent.path}${Platform.pathSeparator}mermaid.min.js',
    ).writeAsBytes(
      mermaid.buffer.asUint8List(mermaid.offsetInBytes, mermaid.lengthInBytes),
      flush: true,
    );
    return File('${directory.path}${Platform.pathSeparator}index.html');
  }

  void _handleBridgeMessage(String raw) {
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('bridge payload is not an object');
      }
      message = decoded.map((key, value) => MapEntry(key.toString(), value));
    } catch (error) {
      debugPrint(
        'WebConversationViewport: malformed bridge message '
        '(${error.runtimeType})',
      );
      return;
    }
    switch (message['type']) {
      case 'ready':
        if (message['protocolVersion'] != webChatProtocolVersion ||
            message['assetVersion'] != webChatAssetVersion) {
          _fail(_generation, 'protocol_mismatch');
          return;
        }
        _ready = true;
        _initializing = false;
        _initializationTimer?.cancel();
        if (mounted) setState(() {});
        unawaited(
          _sendSnapshot().whenComplete(() {
            if (_streamPatchBuffer.hasPending) {
              _scheduleStreamingPatchFlush();
            }
          }),
        );
        return;
      case 'action':
        unawaited(_handleAction(message));
        return;
      case 'externalLink':
        if (!_isAuthorizedBridgeRequest(message)) {
          debugPrint('WebConversationViewport: rejected external link');
          return;
        }
        final url = message['url']?.toString();
        if (url != null) unawaited(_openExternalUrl(url));
        return;
      case 'mediaRequest':
        unawaited(_handleMediaRequest(message));
        return;
      case 'viewportMetrics':
        final wasUserScrolling = widget.viewportPort.isUserScrolling;
        widget.viewportPort.updateMetrics(message);
        if (!wasUserScrolling && widget.viewportPort.isUserScrolling) {
          widget.onUserScrollIntent();
        }
        return;
      case 'diagnostic':
        debugPrint(
          'WebConversationViewport: web diagnostic '
          '${message['code']?.toString() ?? 'unknown'}',
        );
        return;
    }
  }

  Future<void> _handleAction(Map<String, dynamic> message) async {
    final requestId = message['requestId']?.toString() ?? '';
    if (message['capabilityToken'] != _capabilityToken) {
      debugPrint('WebConversationViewport: rejected action capability');
      await _sendActionResult(requestId, ok: false, code: 'capability');
      return;
    }
    try {
      final request = WebChatActionRequest.fromJson(message);
      if (!_actionGate.accept(request)) {
        await _sendActionResult(requestId, ok: false, code: 'stale');
        return;
      }
      await widget.onAction(request);
      await _sendActionResult(requestId, ok: true);
    } catch (error) {
      debugPrint(
        'WebConversationViewport: action failed (${error.runtimeType})',
      );
      await _sendActionResult(requestId, ok: false, code: 'action_failed');
    }
  }

  Future<void> _handleMediaRequest(Map<String, dynamic> message) async {
    if (!_isAuthorizedBridgeRequest(message)) {
      debugPrint('WebConversationViewport: rejected media capability');
      return;
    }
    final handle = message['handle']?.toString() ?? '';
    if (!handle.startsWith('local:') && !handle.startsWith('asset:')) return;
    try {
      final source = widget.mediaRegistry[handle];
      if (source == null) {
        throw const WebChatProtocolException('unknown media handle');
      }
      final extension = source.value.toLowerCase().split('.').last;
      final mime = switch (extension) {
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'svg' when source.kind == WebChatMediaSourceKind.bundledAsset =>
          'image/svg+xml',
        _ => null,
      };
      if (mime == null) {
        throw const WebChatProtocolException('unsupported media type');
      }
      final bytes = switch (source.kind) {
        WebChatMediaSourceKind.localFile => await _readLocalMedia(source.value),
        WebChatMediaSourceKind.bundledAsset => await _readBundledMedia(
          source.value,
        ),
      };
      final payload = <String, dynamic>{
        'type': 'mediaResult',
        'renderSessionId': _renderSessionId,
        'conversationId': _conversationId,
        'handle': handle,
        'dataUrl': 'data:$mime;base64,${base64Encode(bytes)}',
      };
      for (final chunk in chunkWebChatEnvelope(
        payload: payload,
        transferId: 'media:$_renderSessionId:${handle.hashCode}',
      )) {
        await _sendEnvelope(chunk);
      }
    } catch (error) {
      final detail = switch (error) {
        WebChatProtocolException(:final message) => message,
        FileSystemException(:final message) => message,
        _ => error.runtimeType.toString(),
      };
      debugPrint('WebConversationViewport: media request failed ($detail)');
      await _sendEnvelope(<String, dynamic>{
        'type': 'mediaError',
        'handle': handle,
        'code': detail,
      });
    }
  }

  Future<Uint8List> _readLocalMedia(String path) async {
    final resolvedPath = SandboxPathResolver.fix(path);
    final file = File(resolvedPath);
    if (!await file.exists()) {
      throw const FileSystemException('media file does not exist');
    }
    final length = await file.length();
    if (length > 16 * 1024 * 1024) {
      throw const WebChatProtocolException('local media exceeds size limit');
    }
    return file.readAsBytes();
  }

  Future<Uint8List> _readBundledMedia(String path) async {
    if (!path.startsWith('assets/icons/') ||
        path.contains('..') ||
        path.contains(r'\')) {
      throw const WebChatProtocolException('bundled media is not allowed');
    }
    final data = await rootBundle.load(path);
    if (data.lengthInBytes > 2 * 1024 * 1024) {
      throw const WebChatProtocolException('bundled media exceeds size limit');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  bool _isAuthorizedBridgeRequest(Map<String, dynamic> message) =>
      message['capabilityToken'] == _capabilityToken &&
      message['renderSessionId'] == _renderSessionId &&
      message['conversationId'] == _conversationId;

  Future<void> _sendSnapshot() async {
    if (!_ready) return;
    final payload = Map<String, dynamic>.of(widget.snapshot)
      ..['capabilityToken'] = _capabilityToken;
    final transferId =
        '${widget.snapshot['renderSessionId']}:${widget.snapshot['renderRevision']}';
    for (final chunk in chunkWebChatEnvelope(
      payload: payload,
      transferId: transferId,
    )) {
      await _sendEnvelope(chunk);
    }
  }

  Future<void> _sendActionResult(
    String requestId, {
    required bool ok,
    String? code,
  }) => _sendEnvelope(<String, dynamic>{
    'type': 'actionResult',
    'requestId': requestId,
    'ok': ok,
    if (code != null) 'code': code,
  });

  Future<void> _sendEnvelope(Map<String, dynamic> envelope) async {
    final encoded = jsonEncode(envelope);
    try {
      if (Platform.isWindows) {
        await _windowsController?.postWebMessage(encoded);
      } else {
        await _runWebJavaScript(
          'window.CuplivoWeb.receive(${jsonEncode(encoded)});',
        );
      }
    } catch (error) {
      debugPrint(
        'WebConversationViewport: bridge send failed '
        '(${error.runtimeType})',
      );
      _fail(_generation, 'bridge_send_failed');
    }
  }

  Future<void> _sendViewportCommand(Map<String, dynamic> command) async {
    await _stopWebScrolling();
    await _sendEnvelope(command);
  }

  Future<void> _runWebJavaScript(String source) async {
    if (Platform.isWindows) {
      await _windowsController?.executeScript(source);
    } else if (Platform.isAndroid) {
      await _androidController?.runJavaScript(source);
    } else {
      await _flutterController?.runJavaScript(source);
    }
  }

  Future<void> _stopWebScrolling() async {
    if (!_ready) return;
    try {
      if (Platform.isAndroid) {
        await _androidController?.stopScrolling();
      } else {
        await _runWebJavaScript('window.CuplivoWeb?.stopScrolling?.();');
      }
    } catch (error) {
      debugPrint(
        'WebConversationViewport: stop scrolling failed '
        '(${error.runtimeType})',
      );
    }
  }

  void _syncStreamingListeners() {
    final ids = <String>{
      for (final message in (widget.snapshot['messages'] as List? ?? const []))
        if (message is Map && message['isStreaming'] == true)
          message['id']?.toString() ?? '',
    }..remove('');
    for (final id in _streamListeners.keys.toList()) {
      if (ids.contains(id)) continue;
      final notifier = widget.streamingContentNotifier.getNotifier(id);
      notifier.removeListener(_streamListeners.remove(id)!);
      _streamPatchBuffer.remove(id);
    }
    for (final id in ids) {
      if (_streamListeners.containsKey(id) ||
          !widget.streamingContentNotifier.hasNotifier(id)) {
        continue;
      }
      final notifier = widget.streamingContentNotifier.getNotifier(id);
      void listener() {
        final patch = widget.buildStreamingPatch(id, notifier.value);
        if (patch == null) return;
        _streamPatchBuffer.enqueue(id, patch);
        _scheduleStreamingPatchFlush();
      }

      _streamListeners[id] = listener;
      notifier.addListener(listener);
    }
  }

  void _detachStreamingListeners() {
    for (final entry in _streamListeners.entries) {
      if (widget.streamingContentNotifier.hasNotifier(entry.key)) {
        widget.streamingContentNotifier
            .getNotifier(entry.key)
            .removeListener(entry.value);
      }
    }
    _streamListeners.clear();
  }

  void _scheduleStreamingPatchFlush() {
    if (_streamFlushTimer != null || _streamPatchBuffer.inFlight) return;
    _streamFlushTimer = Timer(const Duration(milliseconds: 16), () {
      _streamFlushTimer = null;
      unawaited(_flushStreamingPatches());
    });
  }

  Future<void> _flushStreamingPatches() async {
    if (!_ready) return;
    final patches = _streamPatchBuffer.takeBatch();
    if (patches == null) return;
    try {
      await _sendEnvelope(<String, dynamic>{
        'type': 'messagePatches',
        'renderSessionId': _renderSessionId,
        'conversationId': _conversationId,
        'patches': patches,
      });
    } finally {
      _streamPatchBuffer.completeBatch();
      if (_streamPatchBuffer.hasPending) _scheduleStreamingPatchFlush();
    }
  }

  Future<void> _openExternalUrl(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      debugPrint('WebConversationViewport: rejected external URL');
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      debugPrint('WebConversationViewport: could not open external URL');
    }
  }

  void _fail(int generation, String code) {
    if (_isStale(generation)) return;
    _ready = false;
    _initializing = false;
    _errorCode = code;
    _initializationTimer?.cancel();
    if (mounted) setState(() {});
  }

  bool _isStale(int generation) => !mounted || generation != _generation;

  void _retry() {
    _generation++;
    _ready = false;
    _initializing = false;
    _errorCode = null;
    unawaited(_windowsMessageSubscription?.cancel());
    _windowsMessageSubscription = null;
    final windowsController = _windowsController;
    _windowsController = null;
    if (windowsController != null) unawaited(windowsController.dispose());
    _androidController?.dispose();
    _androidController = null;
    _flutterController = null;
    unawaited(_initialize());
  }

  @override
  Widget build(BuildContext context) {
    if (_errorCode != null) return _buildError(context);
    final Widget child;
    if (Platform.isWindows) {
      child = _windowsController == null
          ? const SizedBox.shrink()
          : winweb.Webview(
              _windowsController!,
              permissionRequested: (_, _, _) =>
                  winweb.WebviewPermissionDecision.deny,
            );
    } else if (Platform.isAndroid) {
      final generation = _generation;
      child = AndroidWebChatView(
        key: ValueKey<int>(generation),
        onPlatformViewCreated: (viewId) =>
            unawaited(_handleAndroidViewCreated(viewId, generation)),
      );
    } else {
      child = _flutterController == null
          ? const SizedBox.shrink()
          : WebViewWidget(controller: _flutterController!);
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (PointerDownEvent _) => unawaited(_stopWebScrolling()),
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (!_ready)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: Semantics(
                  label: AppLocalizations.of(context)!.webChatLoading,
                  child: const CircularProgressIndicator.adaptive(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final diagnostics = <String, dynamic>{
      'component': 'web_conversation_viewport',
      'code': _errorCode,
      'platform': Platform.operatingSystem,
      'protocolVersion': webChatProtocolVersion,
      'assetVersion': webChatAssetVersion,
    };
    return ColoredBox(
      color: colors.surface,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Lucide.Globe, size: 34, color: colors.error),
                const SizedBox(height: 12),
                Text(
                  _webView2Missing
                      ? l10n.webChatWebView2Missing
                      : l10n.webChatInitializationFailed,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ErrorAction(label: l10n.webChatRetry, onTap: _retry),
                    _ErrorAction(
                      label: l10n.webChatCopyDiagnostics,
                      onTap: () async {
                        await Clipboard.setData(
                          ClipboardData(text: jsonEncode(diagnostics)),
                        );
                        if (context.mounted) {
                          showAppSnackBar(
                            context,
                            message: l10n.webChatDiagnosticsCopied,
                          );
                        }
                      },
                    ),
                    if (_webView2Missing)
                      _ErrorAction(
                        label: l10n.webChatInstallWebView2,
                        onTap: () => unawaited(_openExternalUrl(_webView2Url)),
                      ),
                    _ErrorAction(
                      label: l10n.webChatUseFlutterThisConversation,
                      onTap: widget.onUseFlutter,
                      primary: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorAction extends StatelessWidget {
  const _ErrorAction({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IosCardPress(
      baseColor: primary ? colors.primary : context.appColors.surfaceFill,
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        label,
        style: TextStyle(color: primary ? colors.onPrimary : colors.onSurface),
      ),
    );
  }
}

String _windowsMessageText(dynamic event) {
  if (event is String) return event;
  try {
    return event.content?.toString() ?? event.toString();
  } catch (error) {
    debugPrint(
      'WebConversationViewport: bridge conversion failed '
      '(${error.runtimeType})',
    );
    return event.toString();
  }
}

String _randomCapabilityToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes);
}
