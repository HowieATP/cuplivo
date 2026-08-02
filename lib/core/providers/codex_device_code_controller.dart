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

  const CodexOAuthCredential({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.accountId,
  });

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'accountId': accountId,
  };

  factory CodexOAuthCredential.fromJson(Map<String, dynamic> json) =>
      CodexOAuthCredential(
        accessToken: json['accessToken'] as String? ?? '',
        refreshToken: json['refreshToken'] as String? ?? '',
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (json['expiresAt'] as num?)?.toInt() ?? 0,
        ),
        accountId: json['accountId'] as String? ?? '',
      );
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
    _cancelSignal = Completer<void>();
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
  Completer<void> _cancelSignal = Completer<void>();
  Future<void>? _refreshing;
  NetworkProxyConfig? _signInProxy;

  static const String _jwtAuthClaim = 'https://api.openai.com/auth';

  static bool isCodexHost(ProviderConfig cfg) {
    // Host-only: a provider id of 'Codex' must not leak OAuth credentials
    // when the user points its baseUrl at a non-chatgpt.com endpoint.
    final uri = Uri.tryParse(cfg.baseUrl);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    return host.contains('chatgpt.com') && path.contains('codex');
  }

  static bool showEntryFor(ProviderConfig cfg) {
    final kind = ProviderConfig.classify(
      cfg.id,
      explicitType: cfg.providerType,
    );
    if (kind != ProviderKind.openai) return false;
    if (cfg.multiKeyEnabled == true) return false;
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
      if (decoded is! Map) return;
      credential = CodexOAuthCredential.fromJson(
        decoded.cast<String, dynamic>(),
      );
      status = credential!.expiresAt.isBefore(DateTime.now())
          ? CodexAuthStatus.expired
          : CodexAuthStatus.signedIn;
      notifyListeners();
    } catch (e, st) {
      debugPrint('[CodexOAuth] init restore failed: $e\n$st');
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
    await Future.any<void>([
      Future<void>.delayed(duration),
      _cancelSignal.future,
    ]);
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
    _cancelSignal = Completer<void>();
    _signInProxy = null;
    status = CodexAuthStatus.waitingForUser;
    errorMessage = null;
    notifyListeners();
    final client = _clientFor(cfg);
    try {
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
          if (errCode == 'access_denied' ||
              errCode == 'expired_token' ||
              errCode == 'deviceauth_authorization_denied') {
            _fail('Codex device auth was denied or expired');
            return CodexFlowOutcome.failed;
          }
        }
        if (resp.statusCode != 403 && resp.statusCode != 404) {
          final errCode = _extractErrorCode(resp);
          if (errCode == 'deviceauth_authorization_pending') {
            // still pending
          } else if (errCode == 'slow_down') {
            intervalSeconds += kCodexSlowDownIncrement.inSeconds;
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
      );
      await _persistCredential(cred);
      credential = cred;
      status = CodexAuthStatus.signedIn;
      usercode = null;
      verificationUri = null;
      notifyListeners();
      debugPrint('[CodexOAuth] signed in as accountId=$accountId');
      if (_cancelled) {
        _flowEnded();
        return CodexFlowOutcome.cancelled;
      }
      await onAuthenticated();
      return CodexFlowOutcome.success;
    } catch (e, st) {
      debugPrint('[CodexOAuth] startFlow failed: $e\n$st');
      _fail('Codex device login failed: $e');
      return CodexFlowOutcome.failed;
    } finally {
      client.close();
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
    if (!_cancelSignal.isCompleted) {
      _cancelSignal.complete();
    }
  }

  bool get isFresh {
    final c = credential;
    if (c == null) return false;
    return c.expiresAt.subtract(kCodexRefreshGrace).isAfter(DateTime.now());
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
    final client = _clientFactory(_signInProxy);
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
        if (access is! String ||
            access.isEmpty ||
            refresh is! String ||
            refresh.isEmpty ||
            expiresIn is! num) {
          debugPrint('[CodexOAuth] refresh response missing fields: $json');
          return;
        }
        final accountId = _accountIdFromAccessToken(access);
        final cred = CodexOAuthCredential(
          accessToken: access,
          refreshToken: refresh,
          expiresAt: DateTime.now().add(
            Duration(milliseconds: (expiresIn * 1000).round()),
          ),
          accountId: accountId ?? c.accountId,
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
    _signInProxy = null;
    notifyListeners();
  }

  Map<String, String> maybeCodexHeaders(ProviderConfig cfg) {
    try {
      if (!isCodexHost(cfg)) return const {};
      final c = credential;
      if (c == null) return const {};
      if (isFresh) {
        final out = <String, String>{
          'Authorization': 'Bearer ${c.accessToken}',
          'chatgpt-account-id': c.accountId,
        };
        if (cfg.useResponseApi == true) {
          out['OpenAI-Beta'] = 'responses=experimental';
        }
        return out;
      }
      // Stale credential: kick off a background refresh and send no auth
      // headers for this request.
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
