import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A minimal loopback HTTP server that receives the OAuth authorization
/// callback (RFC 8252 native-app pattern).
///
/// Binds to both `127.0.0.1` and `::1` (IPv4 + IPv6 loopback) on the same
/// random port so the callback is reachable regardless of how the browser
/// resolves the redirect host. The browser redirect uses `localhost`
/// (browsers race `::1` and `127.0.0.1`, so either listener answers); the
/// server must accept the `localhost` loopback variant at registration.
///
/// Mirrors the `LanSyncServer` bind pattern (random port fallback).
class OAuthLoopbackServer {
  HttpServer? _server;
  HttpServer? _serverV6;
  Completer<Uri?>? _callback;

  /// The loopback callback URL (e.g. `http://localhost:41234/callback`).
  Uri? get callbackUrl => _server == null
      ? null
      : Uri.parse('http://localhost:${_server!.port}/callback');

  /// Binds the loopback server on a random port (IPv4 + IPv6).
  ///
  /// After binding, the port is self-probed with a TCP connect from this
  /// process. Some Windows setups allocate ports that report as bound but
  /// are unreachable (Hyper-V/WSL2 excluded port ranges, security
  /// software). If the probe fails the port is abandoned and a new one is
  /// tried (up to [maxAttempts]); when all attempts fail [start] throws and
  /// the caller falls back to manual paste.
  Future<void> start({int maxAttempts = 5}) async {
    if (_server != null) return;
    HttpServer? bound;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final candidate = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (await _selfProbe(candidate.port)) {
        bound = candidate;
        break;
      }
      debugPrint(
        '[OAuthLoopbackServer] port ${candidate.port} unreachable, '
        'trying another',
      );
      await candidate.close(force: true);
    }
    if (bound == null) {
      throw SocketException('Loopback port self-probe failed');
    }
    _server = bound;
    // Best-effort IPv6 twin on the same port (fails harmlessly when the
    // platform has no IPv6 loopback).
    try {
      final v6 = await HttpServer.bind(
        InternetAddress.loopbackIPv6,
        _server!.port,
      );
      _serverV6 = v6;
      _handleRequests(v6);
    } catch (e) {
      debugPrint('[OAuthLoopbackServer] IPv6 loopback bind skipped: $e');
    }
    _callback = Completer<Uri?>();
    _handleRequests(_server!);
    debugPrint('[OAuthLoopbackServer] listening at ${callbackUrl ?? '?'}');
  }

  /// Verifies the port accepts TCP connections from this process. A plain
  /// connect with no HTTP request is harmless for the pending request
  /// stream (no request object is produced).
  Future<bool> _selfProbe(int port) async {
    try {
      final socket = await Socket.connect(
        'localhost',
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      return true;
    } catch (e) {
      debugPrint('[OAuthLoopbackServer] self-probe failed: $e');
      return false;
    }
  }

  /// Waits for the browser to redirect back with the authorization result.
  ///
  /// Returns the full callback URI (with `code`/`error` query parameters),
  /// or null when [timeout] elapses without a callback (the caller then
  /// falls back to the manual paste flow).
  Future<Uri?> waitForCallback(Duration timeout) async {
    final callback = _callback;
    if (callback == null) return null;
    final result = await callback.future.timeout(
      timeout,
      onTimeout: () => null,
    );
    return result;
  }

  /// Stops the server and releases the port.
  Future<void> close() async {
    _callback = null;
    await _server?.close(force: true);
    _server = null;
    await _serverV6?.close(force: true);
    _serverV6 = null;
  }

  Future<void> _handleRequests(HttpServer server) async {
    await for (final request in server) {
      try {
        final path = request.uri.path;
        if (path == '/callback' && request.method == 'GET') {
          _completeCallback(request.uri);
          await _respond(
            request,
            status: request.uri.queryParameters.containsKey('error')
                ? HttpStatus.badRequest
                : HttpStatus.ok,
            title: request.uri.queryParameters.containsKey('error')
                ? 'OAuth authorization failed'
                : 'OAuth authorization successful',
            message: request.uri.queryParameters.containsKey('error')
                ? 'You can close this page and go back to the app.'
                : 'You can close this page and go back to the app.',
          );
          return; // Stop accepting further requests; close() follows.
        }
        // favicon.ico and anything else: ignore.
        await _respond(
          request,
          status: HttpStatus.notFound,
          title: 'Not found',
          message: '',
        );
      } catch (e) {
        debugPrint('[OAuthLoopbackServer] request error: $e');
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  void _completeCallback(Uri uri) {
    final callback = _callback;
    if (callback == null || callback.isCompleted) return;
    callback.complete(uri);
  }

  Future<void> _respond(
    HttpRequest request, {
    required int status,
    required String title,
    required String message,
  }) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..write(
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<title>$title</title>'
        '<style>body{font-family:system-ui,sans-serif;display:flex;'
        'align-items:center;justify-content:center;height:90vh;'
        'margin:0;color:#333}div{text-align:center}h1{font-size:22px}'
        'p{color:#666}</style></head>'
        '<body><div><h1>$title</h1><p>$message</p></div></body></html>',
      );
    await request.response.close();
  }
}
