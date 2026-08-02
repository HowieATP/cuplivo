import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/network/dio_http_client.dart';
import 'codex_device_code_controller.dart';
import 'settings_provider.dart';

// The device-code protocol is adapted from earendil-works/pi's
// packages/ai/src/auth/oauth/xai.ts and device-code.ts. See
// THIRD_PARTY_LICENSES.md for the required MIT copyright and permission notice.

const String kGrokClientId = 'b1a00492-073a-47ea-816f-4c329264a828';
const String kGrokScope =
    'openid profile email offline_access grok-cli:access api:access';
const String kGrokDeviceCodeUrl = 'https://auth.x.ai/oauth2/device/code';
const String kGrokTokenUrl = 'https://auth.x.ai/oauth2/token';
const String kGrokReferrer = 'cuplivo';
const String kGrokPrefsKey = 'grok_oauth_v1';
const String kGrokProviderKey = 'Grok';
const String kGrokDefaultBaseUrl = 'https://api.x.ai/v1';
const String kGrokTrustedVerificationUri = 'https://accounts.x.ai/sign-in';
const Duration kGrokFlowDeadline = Duration(minutes: 15);
const Duration kGrokMinInterval = Duration(seconds: 1);
const Duration kGrokDefaultInterval = Duration(seconds: 5);
const Duration kGrokSlowDownIncrement = Duration(seconds: 5);
const Duration kGrokRefreshGrace = Duration(seconds: 60);
const int kGrokDefaultTokenLifetimeSeconds = 3600;

class GrokOAuthCredential {
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final NetworkProxyConfig? proxy;

  const GrokOAuthCredential({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.proxy,
  });

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'proxy': proxy == null
        ? null
        : {
            'type': proxy!.type,
            'host': proxy!.host,
            'port': proxy!.port,
            'username': proxy!.username,
            'password': proxy!.password,
          },
  };

  factory GrokOAuthCredential.fromJson(Map<String, dynamic> json) =>
      GrokOAuthCredential(
        accessToken: json['accessToken'] as String? ?? '',
        refreshToken: json['refreshToken'] as String? ?? '',
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (json['expiresAt'] as num?)?.toInt() ?? 0,
        ),
        proxy: _proxyFromJson(json['proxy']),
      );

  static NetworkProxyConfig? _proxyFromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      final host = raw['host'];
      final port = raw['port'];
      if (host is! String || host.isEmpty || port is! num || port <= 0) {
        return null;
      }
      return NetworkProxyConfig(
        enabled: true,
        type: (raw['type'] is String && (raw['type'] as String).isNotEmpty)
            ? raw['type'] as String
            : 'http',
        host: host,
        port: port.toInt(),
        username: raw['username'] as String?,
        password: raw['password'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

enum GrokAuthStatus {
  signedOut,
  waitingForUser,
  polling,
  signedIn,
  expired,
  failed,
}

enum GrokFlowOutcome { success, failed, timedOut, cancelled }

class GrokOAuthException implements Exception {
  final String message;

  const GrokOAuthException(this.message);

  @override
  String toString() => 'GrokOAuthException: $message';
}

class GrokDeviceCodeController extends ChangeNotifier {
  GrokDeviceCodeController({
    http.Client Function(NetworkProxyConfig? proxy)? clientFactory,
    this._pollDeadline = kGrokFlowDeadline,
  }) : _clientFactory = clientFactory ?? _defaultClientFactory;

  static GrokDeviceCodeController? _instance;

  static GrokDeviceCodeController get instance =>
      _instance ??= GrokDeviceCodeController();

  @visibleForTesting
  static void debugOverrideInstance(GrokDeviceCodeController c) {
    _instance = c;
  }

  @visibleForTesting
  void resetForTest() {
    _refreshing = null;
    _signInProxy = null;
    _cancelled = false;
    _signOutEpoch = 0;
    _cancelListeners.clear();
    credential = null;
    status = GrokAuthStatus.signedOut;
    usercode = null;
    verificationUri = null;
    errorMessage = null;
  }

  static http.Client _defaultClientFactory(NetworkProxyConfig? proxy) {
    if (proxy == null) return DioHttpClient();
    return DioHttpClient(proxy: proxy);
  }

  final http.Client Function(NetworkProxyConfig? proxy) _clientFactory;
  final Duration _pollDeadline;

  GrokAuthStatus status = GrokAuthStatus.signedOut;
  String? usercode;
  Uri? verificationUri;
  String? errorMessage;
  GrokOAuthCredential? credential;

  bool _cancelled = false;
  int _signOutEpoch = 0;
  final List<void Function()> _cancelListeners = [];
  Future<void>? _refreshing;
  NetworkProxyConfig? _signInProxy;

  static bool isGrokHost(ProviderConfig cfg) {
    final uri = Uri.tryParse(cfg.baseUrl);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == 'api.x.ai' || host == 'x.ai' || host.endsWith('.x.ai');
  }

  /// Ensures a usable Grok OAuth session when a credential exists.
  /// Dual-mode: no credential → API key path (no-op). Credential present →
  /// OAuth owns the session and must be refreshed or rejected.
  static Future<void> ensureFreshOrThrow(ProviderConfig cfg) async {
    if (!isGrokHost(cfg)) return;
    final controller = instance;
    if (controller.credential == null) return;
    if (controller.isUsable) return;
    await controller.ensureFresh();
    if (!controller.isUsable) {
      final message = controller.credential == null
          ? 'Grok account is not signed in. Please sign in first.'
          : 'Grok session expired, please sign in again.';
      throw HttpException(message, uri: Uri.tryParse(cfg.baseUrl));
    }
  }

  static bool showEntryFor(ProviderConfig cfg) {
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    if (kind != ProviderKind.openai) return false;
    return cfg.id == kGrokProviderKey || isGrokHost(cfg);
  }

  http.Client _clientFor(ProviderConfig cfg) {
    return _clientFactory(CodexDeviceCodeController.proxyFromConfig(cfg));
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kGrokPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await _removeStoredCredential();
        return;
      }
      final restored = GrokOAuthCredential.fromJson(
        decoded.cast<String, dynamic>(),
      );
      if (restored.accessToken.isEmpty || restored.refreshToken.isEmpty) {
        await _removeStoredCredential();
        return;
      }
      credential = restored;
      status = credential!.expiresAt.isBefore(DateTime.now())
          ? GrokAuthStatus.expired
          : GrokAuthStatus.signedIn;
      notifyListeners();
    } catch (e, st) {
      debugPrint('[GrokOAuth] init restore failed: $e\n$st');
      try {
        await _removeStoredCredential();
      } catch (removeErr, removeSt) {
        debugPrint('[GrokOAuth] init cleanup failed: $removeErr\n$removeSt');
      }
    }
  }

  Future<void> _persistCredential(GrokOAuthCredential cred) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kGrokPrefsKey, jsonEncode(cred.toJson()));
  }

  Future<void> _removeStoredCredential() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kGrokPrefsKey);
  }

  Future<void> _sleepInterruptible(Duration duration) async {
    if (_cancelled) return;
    final done = Completer<void>();
    void complete() {
      if (!done.isCompleted) done.complete();
    }

    final timer = Timer(duration, complete);
    void onCancel() {
      timer.cancel();
      complete();
    }

    _cancelListeners.add(onCancel);
    try {
      await done.future;
    } finally {
      _cancelListeners.remove(onCancel);
    }
  }

  void _flowEnded() {
    usercode = null;
    verificationUri = null;
    _signInProxy = null;
    _cancelled = false;
    if (status != GrokAuthStatus.signedIn) {
      status = GrokAuthStatus.signedOut;
    }
    notifyListeners();
  }

  void _fail(String message) {
    errorMessage = message;
    usercode = null;
    verificationUri = null;
    _signInProxy = null;
    status = GrokAuthStatus.failed;
    notifyListeners();
  }

  Map<String, dynamic>? _tryDecodeJson(http.Response resp) {
    try {
      final decoded = jsonDecode(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
      );
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  String? _extractErrorCode(http.Response resp) {
    final json = _tryDecodeJson(resp);
    if (json == null) return null;
    final error = json['error'];
    if (error is String) return error;
    if (error is Map) {
      final code = error['code'];
      if (code is String) return code;
    }
    return null;
  }

  Future<http.Response> _postForm(
    http.Client client,
    String url,
    Map<String, String> fields,
  ) {
    return client
        .post(
          Uri.parse(url),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: fields.entries
              .map(
                (e) =>
                    '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
              )
              .join('&'),
        )
        .timeout(const Duration(seconds: 30));
  }

  static Uri? _validateVerificationUri(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'https') return null;
    final host = uri.host.toLowerCase();
    if (host != 'x.ai' && !host.endsWith('.x.ai')) return null;
    return uri;
  }

  GrokOAuthCredential? _credentialFromTokenResponse(
    Map<String, dynamic> json, {
    String? previousRefreshToken,
    NetworkProxyConfig? proxy,
  }) {
    final access = json['access_token'];
    if (access is! String || access.isEmpty) return null;
    final rawRefresh = json['refresh_token'];
    final refresh = (rawRefresh is String && rawRefresh.isNotEmpty)
        ? rawRefresh
        : previousRefreshToken;
    if (refresh == null || refresh.isEmpty) return null;
    final rawExpires = json['expires_in'];
    int expiresInSeconds = kGrokDefaultTokenLifetimeSeconds;
    if (rawExpires is num && rawExpires > 0) {
      expiresInSeconds = rawExpires.round();
    } else if (rawExpires is String) {
      final parsed = int.tryParse(rawExpires.trim());
      if (parsed != null && parsed > 0) expiresInSeconds = parsed;
    }
    return GrokOAuthCredential(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime.now().add(Duration(seconds: expiresInSeconds)),
      proxy: proxy,
    );
  }

  Future<GrokFlowOutcome> startFlow({
    required ProviderConfig cfg,
    required Future<void> Function() onAuthenticated,
  }) async {
    if (status == GrokAuthStatus.waitingForUser ||
        status == GrokAuthStatus.polling) {
      debugPrint('[GrokOAuth] startFlow ignored: flow already in progress');
      return GrokFlowOutcome.failed;
    }
    _cancelled = false;
    _signInProxy = null;
    status = GrokAuthStatus.waitingForUser;
    errorMessage = null;
    notifyListeners();
    http.Client? client;
    try {
      client = _clientFor(cfg);
      final deviceResp = await _postForm(client, kGrokDeviceCodeUrl, {
        'client_id': kGrokClientId,
        'scope': kGrokScope,
        'referrer': kGrokReferrer,
      });
      debugPrint('[GrokOAuth] device code status=${deviceResp.statusCode}');
      if (deviceResp.statusCode < 200 || deviceResp.statusCode >= 300) {
        _fail(
          'Grok device authorization failed with status ${deviceResp.statusCode}',
        );
        return GrokFlowOutcome.failed;
      }
      final deviceJson = _tryDecodeJson(deviceResp);
      final deviceCode = deviceJson?['device_code'];
      final rawUserCode = deviceJson?['user_code'];
      final rawVerificationUri = deviceJson?['verification_uri'];
      final rawVerificationUriComplete =
          deviceJson?['verification_uri_complete'];
      if (deviceCode is! String ||
          deviceCode.isEmpty ||
          rawUserCode is! String ||
          rawUserCode.isEmpty ||
          rawVerificationUri is! String ||
          rawVerificationUri.isEmpty) {
        _fail('Invalid Grok device code response');
        return GrokFlowOutcome.failed;
      }
      final verifiedUri =
          _validateVerificationUri(
            rawVerificationUriComplete is String &&
                    rawVerificationUriComplete.isNotEmpty
                ? rawVerificationUriComplete
                : rawVerificationUri,
          ) ??
          _validateVerificationUri(rawVerificationUri);
      if (verifiedUri == null) {
        _fail('Untrusted verification URI in Grok OAuth response');
        return GrokFlowOutcome.failed;
      }

      var serverIntervalSeconds = kGrokDefaultInterval.inSeconds;
      final rawInterval = deviceJson?['interval'];
      double parsedInterval = double.nan;
      if (rawInterval is num) {
        parsedInterval = rawInterval.toDouble();
      } else if (rawInterval is String) {
        parsedInterval = double.tryParse(rawInterval.trim()) ?? double.nan;
      }
      if (parsedInterval.isFinite && parsedInterval > 0) {
        serverIntervalSeconds = parsedInterval
            .round()
            .clamp(kGrokMinInterval.inSeconds, 60)
            .toInt();
      }

      final rawExpiresIn = deviceJson?['expires_in'];
      Duration pollDeadline = _pollDeadline;
      if (rawExpiresIn is num && rawExpiresIn > 0) {
        pollDeadline = Duration(seconds: rawExpiresIn.round());
      }

      if (_cancelled) {
        _flowEnded();
        return GrokFlowOutcome.cancelled;
      }
      usercode = rawUserCode;
      verificationUri = verifiedUri;
      _signInProxy = CodexDeviceCodeController.proxyFromConfig(cfg);
      status = GrokAuthStatus.polling;
      notifyListeners();
      debugPrint(
        '[GrokOAuth] polling usercode=$usercode interval=${serverIntervalSeconds}s',
      );

      final deadline = DateTime.now().add(pollDeadline);
      var intervalSeconds = serverIntervalSeconds;
      // RFC 8628 / pi: wait before first poll.
      {
        final remaining = deadline.difference(DateTime.now());
        if (remaining > Duration.zero) {
          final firstWait = Duration(seconds: intervalSeconds);
          await _sleepInterruptible(
            firstWait < remaining ? firstWait : remaining,
          );
        }
      }
      late final GrokOAuthCredential obtained;
      while (true) {
        if (_cancelled) {
          _flowEnded();
          return GrokFlowOutcome.cancelled;
        }
        if (!DateTime.now().isBefore(deadline)) {
          errorMessage = 'Grok device login timed out';
          _flowEnded();
          return GrokFlowOutcome.timedOut;
        }
        http.Response? resp;
        try {
          resp = await _postForm(client, kGrokTokenUrl, {
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            'client_id': kGrokClientId,
            'device_code': deviceCode,
          });
        } on TimeoutException catch (e) {
          debugPrint('[GrokOAuth] poll TimeoutException: $e, keeping polling');
        } on SocketException catch (e) {
          debugPrint('[GrokOAuth] poll SocketException: $e, keeping polling');
        } catch (e, st) {
          debugPrint('[GrokOAuth] poll failed: $e\n$st, keeping polling');
        }
        if (_cancelled) {
          _flowEnded();
          return GrokFlowOutcome.cancelled;
        }
        if (resp != null) {
          debugPrint('[GrokOAuth] poll status=${resp.statusCode}');
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            final json = _tryDecodeJson(resp);
            if (json == null) {
              _fail('Invalid Grok device token response');
              return GrokFlowOutcome.failed;
            }
            final parsed = _credentialFromTokenResponse(
              json,
              proxy: CodexDeviceCodeController.proxyFromConfig(cfg),
            );
            if (parsed == null) {
              _fail('Grok token response missing fields');
              return GrokFlowOutcome.failed;
            }
            obtained = parsed;
            break;
          }
          final errCode = _extractErrorCode(resp);
          if (errCode == 'authorization_pending') {
            // keep polling
          } else if (errCode == 'slow_down') {
            final bodyInterval = _tryDecodeJson(resp)?['interval'];
            if (bodyInterval is num && bodyInterval > 0) {
              intervalSeconds = bodyInterval
                  .round()
                  .clamp(kGrokMinInterval.inSeconds, 60)
                  .toInt();
            } else {
              intervalSeconds =
                  (intervalSeconds + kGrokSlowDownIncrement.inSeconds)
                      .clamp(kGrokMinInterval.inSeconds, 60)
                      .toInt();
            }
            debugPrint(
              '[GrokOAuth] poll slow_down, interval now ${intervalSeconds}s',
            );
          } else if (errCode == 'access_denied' ||
              errCode == 'authorization_denied') {
            _fail('Grok device authorization was denied');
            return GrokFlowOutcome.failed;
          } else if (errCode == 'expired_token') {
            _fail('Grok device code expired');
            return GrokFlowOutcome.failed;
          } else if (resp.statusCode == 429 || resp.statusCode >= 500) {
            debugPrint(
              '[GrokOAuth] poll transient status ${resp.statusCode}, '
              'keeping polling',
            );
          } else if (errCode != null && errCode.isNotEmpty) {
            _fail('Grok device auth rejected with code: $errCode');
            return GrokFlowOutcome.failed;
          } else {
            _fail('Grok device auth failed with status ${resp.statusCode}');
            return GrokFlowOutcome.failed;
          }
        }
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          errorMessage = 'Grok device login timed out';
          _flowEnded();
          return GrokFlowOutcome.timedOut;
        }
        final interval = Duration(seconds: intervalSeconds);
        await _sleepInterruptible(interval < remaining ? interval : remaining);
      }

      if (_cancelled) {
        _flowEnded();
        return GrokFlowOutcome.cancelled;
      }
      final cred = obtained;
      await _persistCredential(cred);
      if (_cancelled) {
        try {
          await _removeStoredCredential();
        } catch (e, st) {
          debugPrint('[GrokOAuth] post-persist cancel cleanup failed: $e\n$st');
        }
        _flowEnded();
        _cancelled = false;
        return GrokFlowOutcome.cancelled;
      }
      credential = cred;
      status = GrokAuthStatus.signedIn;
      usercode = null;
      verificationUri = null;
      notifyListeners();
      debugPrint('[GrokOAuth] signed in');
      try {
        await onAuthenticated();
      } catch (e, st) {
        debugPrint('[GrokOAuth] onAuthenticated failed: $e\n$st');
      }
      return GrokFlowOutcome.success;
    } catch (e, st) {
      debugPrint('[GrokOAuth] startFlow failed: $e\n$st');
      if (_cancelled) {
        _flowEnded();
        return GrokFlowOutcome.cancelled;
      }
      _fail('Grok device login failed');
      return GrokFlowOutcome.failed;
    } finally {
      client?.close();
    }
  }

  void cancel() {
    _cancelled = true;
    final listeners = List<void Function()>.from(_cancelListeners);
    _cancelListeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  bool get isFresh {
    final c = credential;
    if (c == null) return false;
    return c.expiresAt.subtract(kGrokRefreshGrace).isAfter(DateTime.now());
  }

  bool get isUsable {
    final c = credential;
    if (c == null) return false;
    return c.expiresAt.isAfter(DateTime.now());
  }

  Future<void> ensureFresh() async {
    final inFlight = _refreshing;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final c = credential;
    if (c == null) return;
    if (c.expiresAt.subtract(kGrokRefreshGrace).isAfter(DateTime.now())) {
      return;
    }
    _refreshing = _doRefresh();
    try {
      await _refreshing;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> _doRefresh() async {
    final c = credential;
    if (c == null) return;
    final epochAtStart = _signOutEpoch;
    final client = _clientFactory(c.proxy ?? _signInProxy);
    try {
      final resp = await _postForm(client, kGrokTokenUrl, {
        'grant_type': 'refresh_token',
        'client_id': kGrokClientId,
        'refresh_token': c.refreshToken,
      });
      debugPrint('[GrokOAuth] refresh status=${resp.statusCode}');
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final json = _tryDecodeJson(resp);
        if (json == null) {
          debugPrint('[GrokOAuth] refresh response invalid JSON');
          return;
        }
        final cred = _credentialFromTokenResponse(
          json,
          previousRefreshToken: c.refreshToken,
          proxy: c.proxy ?? _signInProxy,
        );
        if (cred == null) {
          debugPrint(
            '[GrokOAuth] refresh response missing fields: ${json.keys.toList()}',
          );
          return;
        }
        if (_cancelled ||
            _signOutEpoch != epochAtStart ||
            !identical(credential, c)) {
          debugPrint('[GrokOAuth] refresh commit aborted (signed out)');
          return;
        }
        await _persistCredential(cred);
        credential = cred;
        status = GrokAuthStatus.signedIn;
        notifyListeners();
        return;
      }
      final errCode = _extractErrorCode(resp);
      final invalid =
          resp.statusCode == 400 ||
          resp.statusCode == 401 ||
          resp.statusCode == 403;
      if (invalid &&
          (errCode == 'invalid_grant' ||
              errCode == 'invalid_token' ||
              errCode == 'expired')) {
        if (_cancelled ||
            _signOutEpoch != epochAtStart ||
            !identical(credential, c)) {
          debugPrint('[GrokOAuth] rejected refresh commit aborted');
          return;
        }
        debugPrint('[GrokOAuth] refresh rejected: clearing credential');
        await _removeStoredCredential();
        if (_cancelled ||
            _signOutEpoch != epochAtStart ||
            !identical(credential, c)) {
          debugPrint('[GrokOAuth] rejected refresh state update aborted');
          return;
        }
        credential = null;
        status = GrokAuthStatus.expired;
        notifyListeners();
        return;
      }
      debugPrint('[GrokOAuth] refresh transient failure, keeping credential');
    } on SocketException catch (e) {
      debugPrint('[GrokOAuth] refresh SocketException: $e');
    } on TimeoutException catch (e) {
      debugPrint('[GrokOAuth] refresh TimeoutException: $e');
    } catch (e, st) {
      debugPrint('[GrokOAuth] refresh failed: $e\n$st');
    } finally {
      client.close();
    }
  }

  Future<void> signOut() async {
    _signOutEpoch++;
    cancel();
    final inFlight = _refreshing;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
    }
    try {
      await _removeStoredCredential();
    } catch (e, st) {
      debugPrint('[GrokOAuth] signOut prefs remove failed: $e\n$st');
    }
    credential = null;
    status = GrokAuthStatus.signedOut;
    usercode = null;
    verificationUri = null;
    errorMessage = null;
    _signInProxy = null;
    notifyListeners();
  }

  /// Resolves Grok OAuth headers for [cfg]. Dual-mode:
  /// - No credential → empty map (API key path).
  /// - Credential exists → always emit Bearer access (even if stale) and kick
  ///   a background refresh when not usable. Never return {} while credential
  ///   exists (OAuth owns the session; no silent API-key fallback).
  Map<String, String> maybeGrokHeaders(ProviderConfig cfg) {
    try {
      if (ProviderConfig.classify(cfg.id, explicitType: cfg.providerType) !=
          ProviderKind.openai) {
        return const {};
      }
      if (!isGrokHost(cfg)) return const {};
      final c = credential;
      if (c == null) return const {};
      if (!isUsable) {
        unawaited(ensureFresh());
      }
      return <String, String>{'Authorization': 'Bearer ${c.accessToken}'};
    } catch (e, st) {
      debugPrint('[GrokOAuth] maybeGrokHeaders failed: $e\n$st');
      return const {};
    }
  }
}
