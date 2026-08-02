import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_keys.dart';
import '../services/network/dio_http_client.dart';
import 'settings_provider.dart';

const String kCodexClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
const String kCodexUsercodeEndpoint =
    'https://auth.openai.com/api/accounts/deviceauth/usercode';
const String kCodexPollEndpoint =
    'https://auth.openai.com/api/accounts/deviceauth/token';
const String kCodexTokenEndpoint = 'https://auth.openai.com/oauth/token';
const String kCodexVerificationUri = 'https://auth.openai.com/codex/device';
const String kCodexRedirectUri = 'https://auth.openai.com/deviceauth/callback';
const String kCodexPrefsKey = 'codex_oauth_v1';
const Duration kCodexFlowDeadline = Duration(minutes: 15);
const Duration kCodexMinInterval = Duration(seconds: 1);
const Duration kCodexDefaultInterval = Duration(seconds: 5);
const Duration kCodexSlowDownIncrement = Duration(seconds: 5);
const Duration kCodexRefreshGrace = Duration(seconds: 60);
const String kCodexProviderKey = 'Codex';
const String kCodexBaseUrl = 'https://chatgpt.com/backend-api/codex';
const List<String> kCodexModels = [
  'gpt-5.3-codex-spark',
  'gpt-5.4',
  'gpt-5.4-mini',
  'gpt-5.5',
  'gpt-5.6-luna',
  'gpt-5.6-sol',
  'gpt-5.6-terra',
];

class CodexOAuthCredential {
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String accountId;
  final NetworkProxyConfig? proxy;

  const CodexOAuthCredential({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.accountId,
    this.proxy,
  });

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'accountId': accountId,
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

  factory CodexOAuthCredential.fromJson(Map<String, dynamic> json) =>
      CodexOAuthCredential(
        accessToken: json['accessToken'] as String? ?? '',
        refreshToken: json['refreshToken'] as String? ?? '',
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (json['expiresAt'] as num?)?.toInt() ?? 0,
        ),
        accountId: json['accountId'] as String? ?? '',
        proxy: _proxyFromJson(json['proxy']),
      );

  /// Tolerantly parses the persisted proxy block; missing or malformed values
  /// degrade to a direct connection instead of failing the whole restore.
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

enum CodexAuthStatus {
  signedOut,
  waitingForUser,
  polling,
  signedIn,
  expired,
  failed,
}

enum CodexFlowOutcome { success, notEnabled, failed, timedOut, cancelled }

class CodexOAuthException implements Exception {
  final String message;

  const CodexOAuthException(this.message);

  @override
  String toString() => 'CodexOAuthException: $message';
}

class CodexDeviceCodeController extends ChangeNotifier {
  CodexDeviceCodeController({
    http.Client Function(NetworkProxyConfig? proxy)? clientFactory,
    this._pollDeadline = kCodexFlowDeadline,
  }) : _clientFactory = clientFactory ?? _defaultClientFactory;

  static CodexDeviceCodeController? _instance;

  static CodexDeviceCodeController get instance =>
      _instance ??= CodexDeviceCodeController();

  @visibleForTesting
  static void debugOverrideInstance(CodexDeviceCodeController c) {
    _instance = c;
  }

  /// Resets all mutable state so a controller instance can be reused between
  /// tests without leaking credentials, in-flight refresh or cancel signals.
  @visibleForTesting
  void resetForTest() {
    _refreshing = null;
    _signInProxy = null;
    _cancelled = false;
    _cancelListeners.clear();
    credential = null;
    status = CodexAuthStatus.signedOut;
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

  CodexAuthStatus status = CodexAuthStatus.signedOut;
  String? usercode;
  Uri? verificationUri;
  String? errorMessage;
  CodexOAuthCredential? credential;

  bool _cancelled = false;
  final List<void Function()> _cancelListeners = [];
  Future<void>? _refreshing;
  NetworkProxyConfig? _signInProxy;

  static const String _jwtAuthClaim = 'https://api.openai.com/auth';

  static bool isCodexHost(ProviderConfig cfg) {
    // Host-only: a provider id of 'Codex' must not leak OAuth credentials
    // when the user points its baseUrl at a non-chatgpt.com endpoint.
    final uri = Uri.tryParse(cfg.baseUrl);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    // Exact path match: 'contains' would mis-hit siblings such as
    // '/backend-api/notcodex' or '/precodex-gateway' and leak OAuth
    // credentials to non-codex endpoints.
    var path = uri.path.toLowerCase();
    if (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return (host == 'chatgpt.com' || host.endsWith('.chatgpt.com')) &&
        (path == '/backend-api/codex' ||
            path.startsWith('/backend-api/codex/'));
  }

  /// Ensures a usable Codex session for codex hosts. Throws a clear
  /// [HttpException] when the account is not signed in or the session has
  /// absolutely expired and cannot be refreshed, so callers fail fast instead
  /// of sending an unauthenticated request. A token inside the refresh grace
  /// window is still usable and passes through without a refresh attempt.
  static Future<void> ensureFreshOrThrow(ProviderConfig cfg) async {
    if (!isCodexHost(cfg)) return;
    final controller = instance;
    if (controller.credential == null) {
      throw HttpException(
        'Codex account is not signed in. Please sign in first.',
        uri: Uri.tryParse(cfg.baseUrl),
      );
    }
    // A token that has not absolutely expired is still valid even when the
    // refresh grace window has passed: a transient refresh failure must not
    // kill an otherwise-usable session.
    if (controller.isUsable) return;
    await controller.ensureFresh();
    if (!controller.isUsable) {
      final message = controller.credential == null
          ? 'Codex account is not signed in. Please sign in first.'
          : 'Codex session expired, please sign in again.';
      throw HttpException(message, uri: Uri.tryParse(cfg.baseUrl));
    }
  }

  static bool showEntryFor(ProviderConfig cfg) {
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    if (kind != ProviderKind.openai) return false;
    // multiKey gating intentionally lives at the call sites, which hold the
    // live page state; cfg.multiKeyEnabled here is only a snapshot.
    return cfg.id == 'OpenAI' ||
        cfg.id == kCodexProviderKey ||
        isCodexHost(cfg);
  }

  static NetworkProxyConfig? proxyFromConfig(ProviderConfig cfg) {
    final enabled = cfg.proxyEnabled == true;
    final host = (cfg.proxyHost ?? '').trim();
    final portStr = (cfg.proxyPort ?? '').trim();
    final user = (cfg.proxyUsername ?? '').trim();
    final pass = (cfg.proxyPassword ?? '').trim();
    if (!enabled || host.isEmpty || portStr.isEmpty) return null;
    final port = int.tryParse(portStr) ?? 8080;
    return NetworkProxyConfig(
      enabled: true,
      type: ProviderConfig.resolveProxyType(cfg.proxyType),
      host: host,
      port: port,
      username: user.isEmpty ? null : user,
      password: pass.isEmpty ? null : pass,
    );
  }

  http.Client _clientFor(ProviderConfig cfg) {
    return _clientFactory(proxyFromConfig(cfg));
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kCodexPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        // Corrupt payload (e.g. JSON array): self-heal by dropping it so
        // every launch does not repeat the failed parse.
        await _removeStoredCredential();
        return;
      }
      final restored = CodexOAuthCredential.fromJson(
        decoded.cast<String, dynamic>(),
      );
      if (restored.accessToken.isEmpty ||
          restored.refreshToken.isEmpty ||
          restored.accountId.isEmpty) {
        // Partial or corrupt persisted credential (fromJson defaults missing
        // fields to ''): drop it and stay signedOut instead of resurrecting
        // a broken session.
        await _removeStoredCredential();
        return;
      }
      credential = restored;
      status = credential!.expiresAt.isBefore(DateTime.now())
          ? CodexAuthStatus.expired
          : CodexAuthStatus.signedIn;
      notifyListeners();
    } catch (e, st) {
      debugPrint('[CodexOAuth] init restore failed: $e\n$st');
      // Self-heal: a persisted value that cannot be parsed would otherwise
      // fail on every launch.
      try {
        await _removeStoredCredential();
      } catch (removeErr, removeSt) {
        debugPrint('[CodexOAuth] init cleanup failed: $removeErr\n$removeSt');
      }
    }
  }

  Future<void> _persistCredential(CodexOAuthCredential cred) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kCodexPrefsKey, jsonEncode(cred.toJson()));
  }

  Future<void> _removeStoredCredential() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kCodexPrefsKey);
  }

  Future<void> _sleepInterruptible(Duration duration) async {
    if (_cancelled) return;
    final done = Completer<void>();
    void complete() {
      if (!done.isCompleted) done.complete();
    }

    // A real Timer so an interrupted sleep leaves no pending delayed future
    // behind (Future.any kept the delay timer alive after cancellation).
    final timer = Timer(duration, complete);
    // Registered on the cancel-listener list instead of a one-shot signal
    // future: a 15-minute poll registers one listener per sleep, which would
    // otherwise accumulate on a completed signal.
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

  /// Flow ended without a successful login: restore a neutral state.
  /// Does not disturb an existing signed-in state.
  void _flowEnded() {
    usercode = null;
    verificationUri = null;
    if (status != CodexAuthStatus.signedIn) {
      status = CodexAuthStatus.signedOut;
    }
    notifyListeners();
  }

  void _fail(String message) {
    errorMessage = message;
    usercode = null;
    verificationUri = null;
    status = CodexAuthStatus.failed;
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

  static String? _accountIdFromAccessToken(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      final payloadJson = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final payload = jsonDecode(payloadJson);
      if (payload is! Map) return null;
      final auth = payload[_jwtAuthClaim];
      if (auth is! Map) return null;
      final accountId = auth['chatgpt_account_id'];
      if (accountId is String && accountId.isNotEmpty) return accountId;
    } catch (_) {}
    return null;
  }

  Future<CodexFlowOutcome> startFlow({
    required ProviderConfig cfg,
    required Future<void> Function() onAuthenticated,
  }) async {
    if (status == CodexAuthStatus.waitingForUser ||
        status == CodexAuthStatus.polling) {
      debugPrint('[CodexOAuth] startFlow ignored: flow already in progress');
      return CodexFlowOutcome.failed;
    }
    _cancelled = false;
    _signInProxy = null;
    status = CodexAuthStatus.waitingForUser;
    errorMessage = null;
    notifyListeners();
    http.Client? client;
    try {
      client = _clientFor(cfg);
      final usercodeResp = await _postJson(client, kCodexUsercodeEndpoint, {
        'client_id': kCodexClientId,
      });
      debugPrint('[CodexOAuth] usercode status=${usercodeResp.statusCode}');
      if (usercodeResp.statusCode == 404) {
        debugPrint('[CodexOAuth] usercode 404: device login not enabled');
        _flowEnded();
        return CodexFlowOutcome.notEnabled;
      }
      if (usercodeResp.statusCode < 200 || usercodeResp.statusCode >= 300) {
        _fail(
          'Codex usercode request failed with status ${usercodeResp.statusCode}',
        );
        return CodexFlowOutcome.failed;
      }
      final usercodeJson = _tryDecodeJson(usercodeResp);
      final deviceAuthId = usercodeJson?['device_auth_id'];
      final rawUserCode = usercodeJson?['user_code'];
      if (deviceAuthId is! String ||
          deviceAuthId.isEmpty ||
          rawUserCode is! String ||
          rawUserCode.isEmpty) {
        _fail('Invalid Codex usercode response');
        return CodexFlowOutcome.failed;
      }
      var serverIntervalSeconds = kCodexDefaultInterval.inSeconds;
      final rawInterval = usercodeJson?['interval'];
      double parsedInterval = double.nan;
      if (rawInterval is num) {
        parsedInterval = rawInterval.toDouble();
      } else if (rawInterval is String) {
        parsedInterval = double.tryParse(rawInterval.trim()) ?? double.nan;
      }
      if (parsedInterval.isFinite && parsedInterval > 0) {
        serverIntervalSeconds = parsedInterval
            .round()
            .clamp(kCodexMinInterval.inSeconds, 60)
            .toInt();
      }
      // A cancel()/signOut() may have landed while the usercode request was
      // in flight: do not publish the code, flip into polling, or let a
      // later _fail re-drive the status. Report cancelled and stay signedOut.
      if (_cancelled) {
        _flowEnded();
        return CodexFlowOutcome.cancelled;
      }
      usercode = rawUserCode;
      verificationUri = Uri.parse(kCodexVerificationUri);
      _signInProxy = proxyFromConfig(cfg);
      status = CodexAuthStatus.polling;
      notifyListeners();
      debugPrint(
        '[CodexOAuth] polling usercode=$usercode interval=${serverIntervalSeconds}s',
      );

      final deadline = DateTime.now().add(_pollDeadline);
      var intervalSeconds = serverIntervalSeconds;
      String? authorizationCode;
      String? codeVerifier;
      while (true) {
        if (_cancelled) {
          _flowEnded();
          return CodexFlowOutcome.cancelled;
        }
        if (!DateTime.now().isBefore(deadline)) {
          errorMessage = 'Codex device login timed out';
          _flowEnded();
          return CodexFlowOutcome.timedOut;
        }
        final resp = await _postJson(client, kCodexPollEndpoint, {
          'device_auth_id': deviceAuthId,
          'user_code': rawUserCode,
        });
        if (_cancelled) {
          _flowEnded();
          return CodexFlowOutcome.cancelled;
        }
        debugPrint('[CodexOAuth] poll status=${resp.statusCode}');
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final json = _tryDecodeJson(resp);
          final authCode = json?['authorization_code'];
          final verifier = json?['code_verifier'];
          if (authCode is String && verifier is String) {
            authorizationCode = authCode;
            codeVerifier = verifier;
            break;
          }
          _fail('Invalid Codex device auth token response');
          return CodexFlowOutcome.failed;
        }
        if (resp.statusCode == 403 || resp.statusCode == 404) {
          final errCode = _extractErrorCode(resp);
          if (errCode == 'slow_down') {
            // slow_down must be handled before the unknown-code fail-fast:
            // it is a non-empty code that means "keep polling, slower".
            intervalSeconds =
                (intervalSeconds + kCodexSlowDownIncrement.inSeconds)
                    .clamp(kCodexMinInterval.inSeconds, 60)
                    .toInt();
            debugPrint(
              '[CodexOAuth] poll slow_down, interval now ${intervalSeconds}s',
            );
          } else if (errCode == 'access_denied' ||
              errCode == 'expired_token' ||
              errCode == 'deviceauth_authorization_denied') {
            _fail('Codex device auth was denied or expired');
            return CodexFlowOutcome.failed;
          } else if (errCode != null && errCode.isNotEmpty) {
            // Unknown rejection code: fail fast instead of polling until the
            // deadline. A null errCode (no body / no error field, e.g. a bare
            // 403) stays pending per the device-auth semantics.
            _fail('Codex device auth rejected with code: $errCode');
            return CodexFlowOutcome.failed;
          }
        }
        if (resp.statusCode != 403 && resp.statusCode != 404) {
          final errCode = _extractErrorCode(resp);
          if (errCode == 'deviceauth_authorization_pending') {
            // still pending
          } else if (errCode == 'slow_down') {
            intervalSeconds =
                (intervalSeconds + kCodexSlowDownIncrement.inSeconds)
                    .clamp(kCodexMinInterval.inSeconds, 60)
                    .toInt();
            debugPrint(
              '[CodexOAuth] poll slow_down, interval now ${intervalSeconds}s',
            );
          } else {
            _fail('Codex device auth failed with status ${resp.statusCode}');
            return CodexFlowOutcome.failed;
          }
        }
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          errorMessage = 'Codex device login timed out';
          _flowEnded();
          return CodexFlowOutcome.timedOut;
        }
        final interval = Duration(seconds: intervalSeconds);
        await _sleepInterruptible(interval < remaining ? interval : remaining);
      }

      debugPrint('[CodexOAuth] authorization code received, exchanging');
      final exchangeResp = await client
          .post(
            Uri.parse(kCodexTokenEndpoint),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body:
                'grant_type=authorization_code'
                '&client_id=${Uri.encodeQueryComponent(kCodexClientId)}'
                '&code=${Uri.encodeQueryComponent(authorizationCode)}'
                '&code_verifier=${Uri.encodeQueryComponent(codeVerifier)}'
                '&redirect_uri=${Uri.encodeQueryComponent(kCodexRedirectUri)}',
          )
          .timeout(const Duration(seconds: 30));
      debugPrint('[CodexOAuth] exchange status=${exchangeResp.statusCode}');
      if (_cancelled) {
        _flowEnded();
        return CodexFlowOutcome.cancelled;
      }
      if (exchangeResp.statusCode < 200 || exchangeResp.statusCode >= 300) {
        _fail(
          'Codex token exchange failed with status ${exchangeResp.statusCode}',
        );
        return CodexFlowOutcome.failed;
      }
      final tokenJson = _tryDecodeJson(exchangeResp);
      final access = tokenJson?['access_token'];
      final refresh = tokenJson?['refresh_token'];
      final expiresIn = tokenJson?['expires_in'];
      if (access is! String ||
          access.isEmpty ||
          refresh is! String ||
          refresh.isEmpty ||
          expiresIn is! num) {
        _fail('Codex token exchange response missing fields');
        return CodexFlowOutcome.failed;
      }
      final accountId = _accountIdFromAccessToken(access);
      if (accountId == null) {
        _fail('Failed to extract accountId from access token');
        return CodexFlowOutcome.failed;
      }
      if (_cancelled) {
        _flowEnded();
        return CodexFlowOutcome.cancelled;
      }
      final cred = CodexOAuthCredential(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: DateTime.now().add(
          Duration(milliseconds: (expiresIn * 1000).round()),
        ),
        accountId: accountId,
        proxy: proxyFromConfig(cfg),
      );
      await _persistCredential(cred);
      // A cancel()/signOut() may have landed while the credential was being
      // persisted: the session must not resurrect. Drop the entry the persist
      // just wrote and report cancelled without restoring the in-memory
      // credential or the signedIn status (signOut already cleared both).
      if (_cancelled) {
        try {
          await _removeStoredCredential();
        } catch (e, st) {
          debugPrint(
            '[CodexOAuth] post-persist cancel cleanup failed: $e\n$st',
          );
        }
        // Reset the flow state before reporting cancelled: a cancel landing
        // while the persist was in flight used to leave the status stuck at
        // polling with _cancelled true, which permanently blocked the
        // startFlow reentrancy guard and wedged the UI on a spinner.
        _flowEnded();
        _cancelled = false;
        return CodexFlowOutcome.cancelled;
      }
      credential = cred;
      status = CodexAuthStatus.signedIn;
      usercode = null;
      verificationUri = null;
      notifyListeners();
      debugPrint('[CodexOAuth] signed in as accountId=$accountId');
      // NOTE: no cancellation check here. Once the credential is persisted
      // and status flipped to signedIn, a late cancel() must not report a
      // cancelled login for a session that exists; the UI would show a
      // signed-in account behind a "cancelled" result. Cancel semantics only
      // apply to the pre-persist stages of the flow.
      try {
        await onAuthenticated();
      } catch (e, st) {
        // The credential is already persisted and signedIn; a failing
        // callback must not flip the account back to signedOut.
        debugPrint('[CodexOAuth] onAuthenticated failed: $e\n$st');
      }
      return CodexFlowOutcome.success;
    } catch (e, st) {
      debugPrint('[CodexOAuth] startFlow failed: $e\n$st');
      // The raw exception is already logged above; the UI-facing message must
      // stay free of transient network noise.
      _fail('Codex device login failed');
      return CodexFlowOutcome.failed;
    } finally {
      client?.close();
    }
  }

  Future<http.Response> _postJson(
    http.Client client,
    String url,
    Map<String, dynamic> body,
  ) {
    return client
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
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
    return c.expiresAt.subtract(kCodexRefreshGrace).isAfter(DateTime.now());
  }

  /// Whether the stored credential is still valid in absolute terms, i.e.
  /// [expiresAt] lies in the future. Unlike [isFresh] this ignores the
  /// refresh grace window, so a transient refresh failure inside the grace
  /// period does not kill an otherwise-usable session.
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
    if (c.expiresAt.subtract(kCodexRefreshGrace).isAfter(DateTime.now())) {
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
    final client = _clientFactory(c.proxy ?? _signInProxy);
    try {
      final resp = await client
          .post(
            Uri.parse(kCodexTokenEndpoint),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body:
                'grant_type=refresh_token'
                '&refresh_token=${Uri.encodeQueryComponent(c.refreshToken)}'
                '&client_id=${Uri.encodeQueryComponent(kCodexClientId)}',
          )
          .timeout(const Duration(seconds: 30));
      debugPrint('[CodexOAuth] refresh status=${resp.statusCode}');
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final json = _tryDecodeJson(resp);
        final access = json?['access_token'];
        final refresh = json?['refresh_token'];
        final expiresIn = json?['expires_in'];
        if (access is! String || access.isEmpty || expiresIn is! num) {
          // Only log the field names, never the raw body: it may contain
          // access/refresh tokens.
          debugPrint(
            '[CodexOAuth] refresh response missing fields: ${json?.keys.toList()}',
          );
          return;
        }
        final accountId = _accountIdFromAccessToken(access);
        // RFC 6749 allows the refresh token to be omitted on rotation; keep
        // the previous one in that case instead of discarding the response.
        final newRefresh = (refresh is String && refresh.isNotEmpty)
            ? refresh
            : c.refreshToken;
        final cred = CodexOAuthCredential(
          accessToken: access,
          refreshToken: newRefresh,
          expiresAt: DateTime.now().add(
            Duration(milliseconds: (expiresIn * 1000).round()),
          ),
          accountId: accountId ?? c.accountId,
          proxy: c.proxy ?? _signInProxy,
        );
        await _persistCredential(cred);
        credential = cred;
        status = CodexAuthStatus.signedIn;
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
        debugPrint('[CodexOAuth] refresh rejected: clearing credential');
        await _removeStoredCredential();
        credential = null;
        status = CodexAuthStatus.expired;
        notifyListeners();
        return;
      }
      // Transient failure (network / 5xx / 429 / other): keep the credential
      // and the current status so isFresh/ensureFresh drive the retry.
      debugPrint('[CodexOAuth] refresh transient failure, keeping credential');
    } on SocketException catch (e) {
      debugPrint('[CodexOAuth] refresh SocketException: $e');
    } on TimeoutException catch (e) {
      debugPrint('[CodexOAuth] refresh TimeoutException: $e');
    } catch (e, st) {
      debugPrint('[CodexOAuth] refresh failed: $e\n$st');
    } finally {
      client.close();
    }
  }

  Future<void> signOut() async {
    // Abort any in-flight device-code poll loop so it cannot keep running
    // after sign-out and resurrect the credential.
    cancel();
    final inFlight = _refreshing;
    if (inFlight != null) {
      // Wait for an in-flight refresh to finish so it cannot re-persist the
      // credential or flip the status back to signedIn after we sign out.
      try {
        await inFlight;
      } catch (_) {}
    }
    try {
      await _removeStoredCredential();
    } catch (e, st) {
      debugPrint('[CodexOAuth] signOut prefs remove failed: $e\n$st');
    }
    credential = null;
    status = CodexAuthStatus.signedOut;
    usercode = null;
    verificationUri = null;
    errorMessage = null;
    _signInProxy = null;
    notifyListeners();
  }

  /// Resolves Codex OAuth headers for [cfg]. Returns an empty map in three
  /// distinct situations:
  ///   1. [cfg] is not a codex host (see [isCodexHost]) - nothing to add.
  ///   2. No credential is stored - the account is signed out.
  ///   3. The credential has absolutely expired (past [expiresAt]) - a
  ///      background refresh is kicked off and this request intentionally
  ///      goes out WITHOUT auth headers.
  /// A token that has not absolutely expired injects its headers even when
  /// the refresh grace window has passed, so a transient refresh failure
  /// inside the grace period cannot kill an otherwise-usable session.
  /// Callers MUST call [ensureFreshOrThrow] before building their headers so
  /// an absolutely expired session is refreshed (or rejected) before any
  /// request is sent.
  /// The stream entry points (sendMessageStream / generateText /
  /// testConnection) and the tool-call follow-up rounds already do this;
  /// any new call site that merges [_customHeaders]-style maps must follow
  /// the same order.
  Map<String, String> maybeCodexHeaders(ProviderConfig cfg) {
    try {
      // Provider-kind gate: a claude/google provider pointed at a chatgpt.com
      // codex host must never receive Codex OAuth credentials.
      if (ProviderConfig.classify(cfg.id, explicitType: cfg.providerType) !=
          ProviderKind.openai) {
        return const {};
      }
      if (!isCodexHost(cfg)) return const {};
      final c = credential;
      if (c == null) return const {};
      if (isUsable) {
        final out = <String, String>{
          'Authorization': 'Bearer ${c.accessToken}',
          'chatgpt-account-id': c.accountId,
        };
        if (cfg.useResponseApi == true) {
          out['OpenAI-Beta'] = 'responses=experimental';
        }
        return out;
      }
      // Absolutely expired credential: kick off a background refresh and send
      // no auth headers for this request.
      // NOTE: deliberately NOT async/await. The three call entries
      // (sendMessageStream / generateText / testConnection) already await
      // ensureFresh() synchronously before reaching here, so this branch only
      // guards non-entry call points (balance / images / listModels are
      // excluded from codex routing). Keeping this synchronous avoids
      // async-ifying the _customHeaders chain across 12 call sites.
      unawaited(ensureFresh());
      return const {};
    } catch (e, st) {
      debugPrint('[CodexOAuth] maybeCodexHeaders failed: $e\n$st');
      return const {};
    }
  }
}

ProviderConfig codexProviderConfig() => ProviderConfig(
  id: kCodexProviderKey,
  enabled: true,
  name: kCodexProviderKey,
  apiKey: '',
  baseUrl: kCodexBaseUrl,
  providerType: ProviderKind.openai,
  chatPath: null,
  useResponseApi: true,
  models: kCodexModels,
  modelOverrides: {
    for (final m in kCodexModels)
      m: {
        'type': 'chat',
        'input': ['text'],
        'output': ['text'],
        'abilities': ['tool', 'reasoning'],
      },
  },
  proxyEnabled: false,
  proxyHost: '',
  proxyPort: '8080',
  proxyUsername: '',
  proxyPassword: '',
  multiKeyEnabled: false,
  apiKeys: const [],
  keyManagement: const KeyManagementConfig(),
  aihubmixAppCodeEnabled: false,
  balanceEnabled: false,
  balanceApiPath: '/credits',
  balanceResultPath: 'data.total_usage',
  claudePromptCachingEnabled: false,
);
