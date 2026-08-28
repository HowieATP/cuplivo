// ignore_for_file: prefer_initializing_formals

import 'dart:collection';
import 'dart:convert';

const String webConversationStyleKind = 'cuplivo.web-conversation-style';
const int webConversationStyleSchemaVersion = 1;
const String webConversationStyleFileSuffix = '.cuplivo-style.json';
const String webConversationStyleLibraryPreferenceKey =
    'web_conversation_style_library_v1';
const int webConversationStyleFileByteLimit = 64 * 1024;
const int webConversationStyleLibraryByteLimit = 1024 * 1024;
const int webConversationStyleLibraryEntryLimit = 64;

final RegExp _styleIdPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
final RegExp _styleColorPattern = RegExp(
  r'^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$',
);

enum WebConversationStyleErrorCode {
  fileTooLarge,
  invalidUtf8,
  invalidJson,
  invalidRoot,
  invalidKind,
  invalidSchemaVersion,
  invalidId,
  invalidName,
  invalidDescription,
  invalidSection,
  invalidSurface,
  invalidField,
  noApplicableFields,
  tooManyEntries,
  libraryTooLarge,
  duplicateId,
  styleNotFound,
}

class WebConversationStyleException implements Exception {
  const WebConversationStyleException(this.code, [this.path]);

  final WebConversationStyleErrorCode code;
  final String? path;

  @override
  String toString() => path == null ? code.name : '${code.name}: $path';
}

/// A validated, immutable projection of one configurable chat surface.
class WebConversationSurfaceStyle {
  const WebConversationSurfaceStyle({
    this.backgroundColor,
    this.textColor,
    this.accentColor,
    this.borderColor,
    this.borderWidth,
    this.cornerRadius,
    this.paddingHorizontal,
    this.paddingVertical,
    this.shadowElevation,
    this.maxWidthPercent,
  });

  final String? backgroundColor;
  final String? textColor;
  final String? accentColor;
  final String? borderColor;
  final double? borderWidth;
  final double? cornerRadius;
  final double? paddingHorizontal;
  final double? paddingVertical;
  final double? shadowElevation;
  final double? maxWidthPercent;

  bool get isEmpty => toAppearanceJson().isEmpty;

  WebConversationSurfaceStyle merge(WebConversationSurfaceStyle override) {
    return WebConversationSurfaceStyle(
      backgroundColor: override.backgroundColor ?? backgroundColor,
      textColor: override.textColor ?? textColor,
      accentColor: override.accentColor ?? accentColor,
      borderColor: override.borderColor ?? borderColor,
      borderWidth: override.borderWidth ?? borderWidth,
      cornerRadius: override.cornerRadius ?? cornerRadius,
      paddingHorizontal: override.paddingHorizontal ?? paddingHorizontal,
      paddingVertical: override.paddingVertical ?? paddingVertical,
      shadowElevation: override.shadowElevation ?? shadowElevation,
      maxWidthPercent: override.maxWidthPercent ?? maxWidthPercent,
    );
  }

  Map<String, Object> toAppearanceJson() => {
    if (backgroundColor != null) 'backgroundColor': backgroundColor!,
    if (textColor != null) 'textColor': textColor!,
    if (accentColor != null) 'accentColor': accentColor!,
    if (borderColor != null) 'borderColor': borderColor!,
    if (borderWidth != null) 'borderWidth': borderWidth!,
    if (cornerRadius != null) 'cornerRadius': cornerRadius!,
    if (paddingHorizontal != null) 'paddingHorizontal': paddingHorizontal!,
    if (paddingVertical != null) 'paddingVertical': paddingVertical!,
    if (shadowElevation != null) 'shadowElevation': shadowElevation!,
    if (maxWidthPercent != null) 'maxWidthPercent': maxWidthPercent!,
  };
}

class _WebConversationStyleLayer {
  const _WebConversationStyleLayer({
    required this.userBubble,
    required this.assistantBubble,
    required this.processCard,
  });

  const _WebConversationStyleLayer.empty()
    : userBubble = const WebConversationSurfaceStyle(),
      assistantBubble = const WebConversationSurfaceStyle(),
      processCard = const WebConversationSurfaceStyle();

  final WebConversationSurfaceStyle userBubble;
  final WebConversationSurfaceStyle assistantBubble;
  final WebConversationSurfaceStyle processCard;

  bool get isEmpty =>
      userBubble.isEmpty && assistantBubble.isEmpty && processCard.isEmpty;

  _WebConversationStyleLayer merge(_WebConversationStyleLayer override) {
    return _WebConversationStyleLayer(
      userBubble: userBubble.merge(override.userBubble),
      assistantBubble: assistantBubble.merge(override.assistantBubble),
      processCard: processCard.merge(override.processCard),
    );
  }
}

/// A validated style plus its complete original JSON object for round-tripping.
class WebConversationStyle {
  const WebConversationStyle._({
    required this.id,
    required this.name,
    required this.description,
    required this.schemaVersion,
    required this.warnings,
    required this.raw,
    required _WebConversationStyleLayer common,
    required _WebConversationStyleLayer light,
    required _WebConversationStyleLayer dark,
  }) : _common = common,
       _light = light,
       _dark = dark;

  final String id;
  final String name;
  final String? description;
  final int schemaVersion;
  final List<String> warnings;
  final Map<String, Object?> raw;
  final _WebConversationStyleLayer _common;
  final _WebConversationStyleLayer _light;
  final _WebConversationStyleLayer _dark;

  static WebConversationStyle parseBytes(List<int> bytes) {
    if (bytes.length > webConversationStyleFileByteLimit) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.fileTooLarge,
      );
    }
    late final String source;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidUtf8,
      );
    }
    return parse(source);
  }

  static WebConversationStyle parse(String source) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidJson,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidRoot,
      );
    }
    return fromRaw(decoded);
  }

  static WebConversationStyle fromRaw(Map<String, dynamic> source) {
    final warnings = <String>[];
    const rootFields = {
      'kind',
      'schemaVersion',
      'id',
      'name',
      'description',
      'common',
      'light',
      'dark',
    };
    _recordUnknownFields(source, rootFields, r'$', warnings);

    if (source['kind'] != webConversationStyleKind) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidKind,
        r'$.kind',
      );
    }
    final schemaVersion = source['schemaVersion'];
    if (schemaVersion is! int || schemaVersion < 1) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidSchemaVersion,
        r'$.schemaVersion',
      );
    }
    if (schemaVersion > webConversationStyleSchemaVersion) {
      warnings.add(r'$.schemaVersion');
    }

    final id = source['id'];
    if (id is! String || id.length > 64 || !_styleIdPattern.hasMatch(id)) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidId,
        r'$.id',
      );
    }
    final name = source['name'];
    if (name is! String || name.trim().isEmpty || name.length > 80) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidName,
        r'$.name',
      );
    }
    final descriptionValue = source['description'];
    if (descriptionValue != null &&
        (descriptionValue is! String || descriptionValue.length > 240)) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidDescription,
        r'$.description',
      );
    }

    final common = _parseLayer(source['common'], r'$.common', warnings);
    final light = _parseLayer(source['light'], r'$.light', warnings);
    final dark = _parseLayer(source['dark'], r'$.dark', warnings);
    if (common.isEmpty && light.isEmpty && dark.isEmpty) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.noApplicableFields,
      );
    }

    final immutableRaw = _deepFreeze(source) as Map<String, Object?>;
    return WebConversationStyle._(
      id: id,
      name: name,
      description: descriptionValue as String?,
      schemaVersion: schemaVersion,
      warnings: List.unmodifiable(warnings),
      raw: immutableRaw,
      common: common,
      light: light,
      dark: dark,
    );
  }

  Map<String, Object> resolveAppearance({required bool isDark}) {
    final layer = _common.merge(isDark ? _dark : _light);
    return {
      if (!layer.userBubble.isEmpty)
        'userBubble': layer.userBubble.toAppearanceJson(),
      if (!layer.assistantBubble.isEmpty)
        'assistantBubble': layer.assistantBubble.toAppearanceJson(),
      if (!layer.processCard.isEmpty)
        'processCard': layer.processCard.toAppearanceJson(),
    };
  }

  String exportJson() => const JsonEncoder.withIndent('  ').convert(raw);

  int get rawByteLength => utf8.encode(jsonEncode(raw)).length;
}

_WebConversationStyleLayer _parseLayer(
  Object? value,
  String path,
  List<String> warnings,
) {
  if (value == null) return const _WebConversationStyleLayer.empty();
  if (value is! Map<String, dynamic>) {
    throw WebConversationStyleException(
      WebConversationStyleErrorCode.invalidSection,
      path,
    );
  }
  const surfaces = {'userBubble', 'assistantBubble', 'processCard'};
  _recordUnknownFields(value, surfaces, path, warnings);
  return _WebConversationStyleLayer(
    userBubble: _parseSurface(
      value['userBubble'],
      '$path.userBubble',
      warnings,
      supportsAccent: false,
      supportsMaxWidth: true,
    ),
    assistantBubble: _parseSurface(
      value['assistantBubble'],
      '$path.assistantBubble',
      warnings,
      supportsAccent: false,
      supportsMaxWidth: true,
    ),
    processCard: _parseSurface(
      value['processCard'],
      '$path.processCard',
      warnings,
      supportsAccent: true,
      supportsMaxWidth: false,
    ),
  );
}

WebConversationSurfaceStyle _parseSurface(
  Object? value,
  String path,
  List<String> warnings, {
  required bool supportsAccent,
  required bool supportsMaxWidth,
}) {
  if (value == null) return const WebConversationSurfaceStyle();
  if (value is! Map<String, dynamic>) {
    throw WebConversationStyleException(
      WebConversationStyleErrorCode.invalidSurface,
      path,
    );
  }
  const knownFields = {
    'backgroundColor',
    'textColor',
    'accentColor',
    'borderColor',
    'borderWidth',
    'cornerRadius',
    'paddingHorizontal',
    'paddingVertical',
    'shadowElevation',
    'maxWidthPercent',
  };
  _recordUnknownFields(value, knownFields, path, warnings);

  final accentColor = _color(value, 'accentColor', path);
  final maxWidthPercent = _number(
    value,
    'maxWidthPercent',
    path,
    min: 40,
    max: 100,
  );
  if (accentColor != null && !supportsAccent) warnings.add('$path.accentColor');
  if (maxWidthPercent != null && !supportsMaxWidth) {
    warnings.add('$path.maxWidthPercent');
  }
  return WebConversationSurfaceStyle(
    backgroundColor: _color(value, 'backgroundColor', path),
    textColor: _color(value, 'textColor', path),
    accentColor: supportsAccent ? accentColor : null,
    borderColor: _color(value, 'borderColor', path),
    borderWidth: _number(value, 'borderWidth', path, min: 0, max: 4),
    cornerRadius: _number(value, 'cornerRadius', path, min: 0, max: 48),
    paddingHorizontal: _number(
      value,
      'paddingHorizontal',
      path,
      min: 0,
      max: 32,
    ),
    paddingVertical: _number(value, 'paddingVertical', path, min: 0, max: 32),
    shadowElevation: _number(value, 'shadowElevation', path, min: 0, max: 24),
    maxWidthPercent: supportsMaxWidth ? maxWidthPercent : null,
  );
}

String? _color(Map<String, dynamic> source, String key, String path) {
  if (!source.containsKey(key)) return null;
  final value = source[key];
  if (value is! String || !_styleColorPattern.hasMatch(value)) {
    throw WebConversationStyleException(
      WebConversationStyleErrorCode.invalidField,
      '$path.$key',
    );
  }
  return value;
}

double? _number(
  Map<String, dynamic> source,
  String key,
  String path, {
  required double min,
  required double max,
}) {
  if (!source.containsKey(key)) return null;
  final value = source[key];
  if (value is! num || value is bool || !value.isFinite) {
    throw WebConversationStyleException(
      WebConversationStyleErrorCode.invalidField,
      '$path.$key',
    );
  }
  final result = value.toDouble();
  if (result < min || result > max) {
    throw WebConversationStyleException(
      WebConversationStyleErrorCode.invalidField,
      '$path.$key',
    );
  }
  return result;
}

void _recordUnknownFields(
  Map<String, dynamic> source,
  Set<String> known,
  String path,
  List<String> warnings,
) {
  for (final key in source.keys) {
    if (!known.contains(key)) warnings.add('$path.$key');
  }
}

Object? _deepFreeze(Object? value) {
  if (value is Map) {
    return UnmodifiableMapView<String, Object?>({
      for (final entry in value.entries)
        entry.key as String: _deepFreeze(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_deepFreeze));
  }
  return value;
}

class WebConversationStyleLibrary {
  WebConversationStyleLibrary({
    List<WebConversationStyle> entries = const [],
    this.activeId,
  }) : entries = List.unmodifiable(entries);

  final List<WebConversationStyle> entries;
  final String? activeId;

  WebConversationStyle? get activeStyle {
    if (activeId == null) return null;
    for (final style in entries) {
      if (style.id == activeId) return style;
    }
    return null;
  }

  List<WebConversationStyle> get sortedEntries {
    final result = [...entries];
    result.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
    return List.unmodifiable(result);
  }

  WebConversationStyleLibrary importBatch(
    Iterable<WebConversationStyle> imported,
  ) {
    final incoming = imported.toList(growable: false);
    final ids = <String>{};
    for (final style in incoming) {
      if (!ids.add(style.id)) {
        throw WebConversationStyleException(
          WebConversationStyleErrorCode.duplicateId,
          style.id,
        );
      }
    }
    final byId = {for (final style in entries) style.id: style};
    for (final style in incoming) {
      byId[style.id] = style;
    }
    final result = WebConversationStyleLibrary(
      entries: List.unmodifiable(byId.values),
      activeId: activeId,
    );
    result.validateLimits();
    return result;
  }

  WebConversationStyleLibrary activate(String? id) {
    if (id != null && !entries.any((style) => style.id == id)) {
      throw WebConversationStyleException(
        WebConversationStyleErrorCode.styleNotFound,
        id,
      );
    }
    return WebConversationStyleLibrary(entries: entries, activeId: id);
  }

  WebConversationStyleLibrary remove(String id) {
    if (!entries.any((style) => style.id == id)) {
      throw WebConversationStyleException(
        WebConversationStyleErrorCode.styleNotFound,
        id,
      );
    }
    return WebConversationStyleLibrary(
      entries: List.unmodifiable(entries.where((style) => style.id != id)),
      activeId: activeId == id ? null : activeId,
    );
  }

  void validateLimits() {
    if (entries.length > webConversationStyleLibraryEntryLimit) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.tooManyEntries,
      );
    }
    if (entries.any(
      (style) => style.rawByteLength > webConversationStyleFileByteLimit,
    )) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.fileTooLarge,
      );
    }
    final rawBytes = entries.fold<int>(
      0,
      (total, style) => total + style.rawByteLength,
    );
    if (rawBytes > webConversationStyleLibraryByteLimit) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.libraryTooLarge,
      );
    }
  }

  String encode() => jsonEncode({
    'entries': entries.map((style) => style.raw).toList(growable: false),
    'activeId': activeId,
  });

  static WebConversationStyleLibrary decode(String source) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidJson,
      );
    }
    if (decoded is! Map<String, dynamic> || decoded['entries'] is! List) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidRoot,
      );
    }
    final parsed = <WebConversationStyle>[];
    for (final item in decoded['entries'] as List) {
      if (item is! Map<String, dynamic>) {
        throw const WebConversationStyleException(
          WebConversationStyleErrorCode.invalidRoot,
          r'$.entries',
        );
      }
      parsed.add(WebConversationStyle.fromRaw(item));
    }
    final active = decoded['activeId'];
    if (active != null && active is! String) {
      throw const WebConversationStyleException(
        WebConversationStyleErrorCode.invalidField,
        r'$.activeId',
      );
    }
    final library = WebConversationStyleLibrary(
      entries: List.unmodifiable(parsed),
      activeId: active is String && parsed.any((style) => style.id == active)
          ? active
          : null,
    );
    library.validateLimits();
    return library;
  }
}
