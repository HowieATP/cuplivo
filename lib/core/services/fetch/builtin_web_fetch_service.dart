import 'package:flutter/foundation.dart' show visibleForTesting;

import 'readable_web_fetch_service.dart';
import 'web_fetch_content.dart';
import 'web_fetch_target_guard.dart' as guard;

/// Cuplivo's transport-independent built-in web fetch engine.
///
/// Provides one token-conscious `fetch` tool. HTML is simplified to Markdown
/// by default, while raw content requires an explicit opt-in. Responses are
/// bounded and can be continued with `start_index`.

class BuiltInWebFetchRequest {
  static const defaultMaxLength = WebFetchContentWindow.defaultMaxLength;
  static const maximumMaxLength = WebFetchContentWindow.maximumMaxLength;

  final Uri url;
  final Map<String, String> headers;
  final int maxLength;
  final int startIndex;
  final bool raw;

  BuiltInWebFetchRequest({
    required this.url,
    Map<String, String>? headers,
    this.maxLength = defaultMaxLength,
    this.startIndex = 0,
    this.raw = false,
  }) : headers = headers ?? const {};

  static BuiltInWebFetchRequest parse(Object? args) {
    if (args is! Map) {
      throw ArgumentError(
        'Invalid arguments: expected an object containing url',
      );
    }
    final map = args.cast<String, dynamic>();
    final urlRaw = (map['url'] ?? '').toString().trim();
    final uri = Uri.tryParse(urlRaw);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw ArgumentError('Invalid url: $urlRaw');
    }
    final blockReason = guard.WebFetchTargetGuard.literalBlockReason(uri);
    if (blockReason != null) {
      throw ArgumentError('Invalid url: $blockReason');
    }
    final headersAny = map['headers'];
    final headers = <String, String>{};
    if (headersAny != null && headersAny is! Map) {
      throw ArgumentError('Invalid headers: expected an object');
    }
    if (headersAny is Map) {
      headersAny.forEach((k, v) {
        if (k == null || v == null) return;
        headers[k.toString()] = v.toString();
      });
    }
    final maxLength = _parseInteger(
      map['max_length'],
      name: 'max_length',
      defaultValue: defaultMaxLength,
    );
    if (maxLength < 1 || maxLength > maximumMaxLength) {
      throw ArgumentError(
        'Invalid max_length: expected a value from 1 to $maximumMaxLength',
      );
    }
    final startIndex = _parseInteger(
      map['start_index'],
      name: 'start_index',
      defaultValue: 0,
    );
    if (startIndex < 0) {
      throw ArgumentError('Invalid start_index: expected a non-negative value');
    }
    final rawAny = map['raw'];
    if (rawAny != null && rawAny is! bool) {
      throw ArgumentError('Invalid raw: expected a boolean');
    }

    return BuiltInWebFetchRequest(
      url: uri,
      headers: headers,
      maxLength: maxLength,
      startIndex: startIndex,
      raw: rawAny as bool? ?? false,
    );
  }

  static int _parseInteger(
    Object? value, {
    required String name,
    required int defaultValue,
  }) {
    if (value == null) return defaultValue;
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    throw ArgumentError('Invalid $name: expected an integer');
  }
}

class BuiltInWebFetchResult {
  final String url;
  final String? title;
  final String? content;
  final bool raw;

  const BuiltInWebFetchResult({
    required this.url,
    this.title,
    this.content,
    this.raw = false,
  });
}

class BuiltInWebFetchException implements Exception {
  final String message;

  const BuiltInWebFetchException(this.message);

  @override
  String toString() => message;
}

class BuiltInWebFetchService {
  static const _defaultUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Total-duration timeout for TEXT mode (`http.get` covers connect,
  /// headers and body in one unbounded future). Bounds what would otherwise
  /// hang indefinitely — a blackholed page must fail fast for the model.
  /// Mutable only so tests can shrink it.
  @visibleForTesting
  static Duration textFetchTimeout = const Duration(seconds: 60);

  static Map<String, String> _mergedHeaders(BuiltInWebFetchRequest payload) =>
      <String, String>{'User-Agent': _defaultUA, ...payload.headers};

  static Future<BuiltInWebFetchResult> fetch(
    BuiltInWebFetchRequest payload, {
    Duration? timeout,
  }) async {
    try {
      final readable = await ReadableWebFetchService.fetch(
        url: payload.url,
        headers: _mergedHeaders(payload),
        raw: payload.raw,
        timeout: timeout ?? textFetchTimeout,
      );
      return BuiltInWebFetchResult(
        url: readable.url,
        title: readable.title,
        content: readable.content,
        raw: payload.raw,
      );
    } on UnsupportedReadableContentException catch (e) {
      throw BuiltInWebFetchException('Possible binary content detected. $e');
    } catch (e) {
      if (e is BuiltInWebFetchException) rethrow;
      throw BuiltInWebFetchException(e.toString());
    }
  }
}
