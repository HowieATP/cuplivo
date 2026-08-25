import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../utils/brand_assets.dart';
import '../../chat/models/tool_ui_part.dart';
import '../../chat/utils/message_visual_content.dart';
import '../../chat/utils/thinking_tag_parser.dart';
import '../controllers/stream_controller.dart' as stream_ctrl;
import 'web_chat_protocol.dart';

class WebChatSnapshotBuilder {
  const WebChatSnapshotBuilder();

  Map<String, dynamic> build({
    required String renderSessionId,
    required String conversationId,
    required int renderRevision,
    required int actionEpoch,
    required List<ChatMessage> messages,
    required Map<String, List<ChatMessage>> byGroup,
    required Map<String, int> versionSelections,
    required Map<String, stream_ctrl.ReasoningData> reasoning,
    required Map<String, List<stream_ctrl.ReasoningSegmentData>>
    reasoningSegments,
    required Map<String, stream_ctrl.ContentSplitData> contentSplits,
    required Map<String, List<ToolUIPart>> toolParts,
    required Set<String> selectedItems,
    required bool selecting,
    required int truncCollapsedIndex,
    required List<String> suggestions,
    required bool hasMoreBefore,
    required bool hasMoreAfter,
    required Map<String, String> strings,
    required Map<String, String> theme,
    required Map<String, dynamic> user,
    required Map<String, dynamic> display,
    required Assistant? assistant,
    required double fontScale,
    required bool canStartMultiAI,
    required bool autoCollapseThinking,
  }) {
    return <String, dynamic>{
      'type': 'snapshot',
      'protocolVersion': webChatProtocolVersion,
      'assetVersion': webChatAssetVersion,
      'renderSessionId': renderSessionId,
      'conversationId': conversationId,
      'renderRevision': renderRevision,
      'actionEpoch': actionEpoch,
      'messages': <Map<String, dynamic>>[
        for (var index = 0; index < messages.length; index++)
          _message(
            messages[index],
            index: index,
            byGroup: byGroup,
            versionSelections: versionSelections,
            reasoning: reasoning[messages[index].id],
            reasoningSegments: reasoningSegments[messages[index].id],
            contentSplit: contentSplits[messages[index].id],
            toolParts: toolParts[messages[index].id],
            selected: selectedItems.contains(messages[index].id),
            selecting: selecting,
            showContextDivider:
                truncCollapsedIndex >= 0 && index == truncCollapsedIndex,
            assistant: assistant,
            display: display,
            autoCollapseThinking: autoCollapseThinking,
          ),
      ],
      'suggestions': suggestions,
      'hasMoreBefore': hasMoreBefore,
      'hasMoreAfter': hasMoreAfter,
      'strings': strings,
      'theme': theme,
      'user': user,
      'display': display,
      'fontScale': fontScale,
      'canStartMultiAI': canStartMultiAI,
      'assistant': <String, dynamic>{
        'name': assistant?.name ?? '',
        'avatar': _assistantAvatarReference(assistant?.avatar),
        'avatarLabel': _assistantAvatarLabel(assistant?.avatar),
        'background': _safeMediaReference(assistant?.background),
        'useAvatar': assistant?.useAssistantAvatar ?? false,
        'useName': assistant?.useAssistantName ?? false,
      },
    };
  }

  Map<String, dynamic> _message(
    ChatMessage message, {
    required int index,
    required Map<String, List<ChatMessage>> byGroup,
    required Map<String, int> versionSelections,
    required stream_ctrl.ReasoningData? reasoning,
    required List<stream_ctrl.ReasoningSegmentData>? reasoningSegments,
    required stream_ctrl.ContentSplitData? contentSplit,
    required List<ToolUIPart>? toolParts,
    required bool selected,
    required bool selecting,
    required bool showContextDivider,
    required Assistant? assistant,
    required Map<String, dynamic> display,
    required bool autoCollapseThinking,
  }) {
    final versions = List<ChatMessage>.of(
      byGroup[message.groupId] ?? <ChatMessage>[message],
    )..sort((a, b) => a.version.compareTo(b.version));
    final selectedVersion =
        versionSelections[message.groupId] ?? message.version;
    final selectedVersionIndex = versions.indexWhere(
      (item) => item.version == selectedVersion,
    );
    final legacy = ThinkingTagParser.parseLegacyInlineBlocks(message.content);
    final visualContent = message.role == 'assistant'
        ? messageVisualContent(message, assistant: assistant)
        : _userVisualContent(message.content);
    return <String, dynamic>{
      'id': message.id,
      'index': index,
      'role': message.role,
      'content': visualContent,
      'timestamp': message.timestamp.toIso8601String(),
      'modelId': message.modelId,
      'providerId': message.providerId,
      'modelIcon': _modelIconReference(message),
      'modelIconMonochrome': _modelIconIsMonochrome(message),
      'tokens': message.contextTokens ?? message.totalTokens,
      'promptTokens': message.promptTokens,
      'completionTokens': message.completionTokens,
      'cachedTokens': message.cachedTokens,
      'durationMs': message.durationMs,
      'isStreaming': message.isStreaming,
      'isPreset': message.isPreset,
      'translation': message.translation,
      'reasoning': _reasoning(
        message,
        reasoning,
        reasoningSegments,
        legacy.thinkingTexts,
        autoCollapseThinking: autoCollapseThinking,
      ),
      'contentSplits': contentSplit == null
          ? null
          : <String, dynamic>{
              'offsets': contentSplit.offsets,
              'reasoningCounts': contentSplit.reasoningCounts,
              'toolCounts': contentSplit.toolCounts,
            },
      'tools': (toolParts ?? const <ToolUIPart>[])
          .map((part) => part.toJson())
          .toList(growable: false),
      'attachments': parseWebChatAttachments(message.content),
      'selected': selected,
      'selecting': selecting,
      'showContextDivider': showContextDivider,
      'groupId': message.groupId,
      'version': message.version,
      'versionCount': versions.length,
      'selectedVersion': selectedVersion,
      'versionIndex': selectedVersionIndex < 0 ? 0 : selectedVersionIndex,
      'actions': _primaryActions(message, display),
    };
  }

  List<String> _primaryActions(
    ChatMessage message,
    Map<String, dynamic> display,
  ) {
    if (message.role == 'user') {
      if (display['showUserMessageActions'] == false) return const <String>[];
      return const <String>['copy', 'resend', 'edit', 'more'];
    }
    if (message.isStreaming) return const <String>[];
    return const <String>['copy', 'regenerate', 'speak', 'translate', 'more'];
  }

  List<Map<String, dynamic>> _reasoning(
    ChatMessage message,
    stream_ctrl.ReasoningData? live,
    List<stream_ctrl.ReasoningSegmentData>? liveSegments,
    List<String> legacyThinking, {
    required bool autoCollapseThinking,
  }) {
    if (liveSegments != null && liveSegments.isNotEmpty) {
      return liveSegments
          .asMap()
          .entries
          .map(
            (entry) => <String, dynamic>{
              'kind': 'segment',
              'index': entry.key,
              'key': _reasoningKey(message.id, 'segment', entry.key),
              'text': entry.value.text,
              'expanded': entry.value.expanded,
              'loading': entry.value.finishedAt == null && message.isStreaming,
              'startAt': entry.value.startAt?.toIso8601String(),
              'finishedAt': entry.value.finishedAt?.toIso8601String(),
              'toolStartIndex': entry.value.toolStartIndex,
            },
          )
          .toList(growable: false);
    }
    final raw = message.reasoningSegmentsJson;
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        final segments = decoded is Map ? decoded['segments'] : decoded;
        if (segments is List) {
          return segments
              .whereType<Map>()
              .toList(growable: false)
              .asMap()
              .entries
              .map(
                (entry) => <String, dynamic>{
                  'kind': 'segment',
                  'index': entry.key,
                  'key': _reasoningKey(message.id, 'segment', entry.key),
                  'text': entry.value['text']?.toString() ?? '',
                  'expanded': entry.value['expanded'] is bool
                      ? entry.value['expanded']
                      : !autoCollapseThinking,
                  'loading': false,
                  'startAt': entry.value['startAt']?.toString(),
                  'finishedAt': entry.value['finishedAt']?.toString(),
                  'toolStartIndex':
                      (entry.value['toolStartIndex'] as num?)?.toInt() ?? 0,
                },
              )
              .toList(growable: false);
        }
      } catch (error) {
        debugPrint(
          'WebChatSnapshotBuilder: malformed reasoning payload '
          '(${error.runtimeType})',
        );
        // The legacy text below remains authoritative for malformed old rows.
      }
    }
    final text = live?.text ?? message.reasoningText;
    if (text != null && text.isNotEmpty) {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'kind': 'single',
          'index': 0,
          'key': _reasoningKey(message.id, 'single', 0),
          'text': text,
          'expanded': live?.expanded ?? !autoCollapseThinking,
          'loading': message.isStreaming && live?.finishedAt == null,
          'startAt': (live?.startAt ?? message.reasoningStartAt)
              ?.toIso8601String(),
          'finishedAt': (live?.finishedAt ?? message.reasoningFinishedAt)
              ?.toIso8601String(),
          'toolStartIndex': 0,
        },
      ];
    }
    return legacyThinking
        .asMap()
        .entries
        .map(
          (entry) => <String, dynamic>{
            'kind': 'legacy',
            'index': entry.key,
            'key': _reasoningKey(message.id, 'legacy', entry.key),
            'text': entry.value,
            'expanded': !autoCollapseThinking,
            'loading': false,
            'startAt': null,
            'finishedAt': null,
            'toolStartIndex': 0,
          },
        )
        .toList(growable: false);
  }
}

String _reasoningKey(String messageId, String kind, int index) =>
    '$messageId:reasoning:$kind:$index';

String? _modelIconAsset(ChatMessage message) {
  final modelId = message.modelId?.trim();
  final providerId = message.providerId?.trim();
  if (modelId != null && modelId.isNotEmpty) {
    final asset = BrandAssets.assetForName(modelId);
    if (asset != null) return asset;
  }
  if (providerId != null && providerId.isNotEmpty) {
    return BrandAssets.assetForName(providerId);
  }
  return null;
}

String? _modelIconReference(ChatMessage message) {
  final asset = _modelIconAsset(message);
  return asset == null ? null : webChatBundledAssetHandle(asset);
}

bool _modelIconIsMonochrome(ChatMessage message) {
  final asset = _modelIconAsset(message);
  if (asset == null) return false;
  return !asset.contains('-color.');
}

String _userVisualContent(String content) => content
    .replaceAll(RegExp(r'\[image:[^\]]+\]'), '')
    .replaceAll(RegExp(r'\[file:[^\]]+\]'), '')
    .trim();

List<Map<String, dynamic>> parseWebChatAttachments(String content) {
  final attachments = <Map<String, dynamic>>[];
  final imagePattern = RegExp(r'\[image:([^\]]+)\]');
  for (final match in imagePattern.allMatches(content)) {
    final reference = _safeMediaReference(match.group(1));
    if (reference != null) {
      attachments.add(<String, dynamic>{
        'kind': 'image',
        'reference': reference,
      });
    }
  }
  final filePattern = RegExp(r'\[file:([^|\]]+)\|([^|\]]*)\|([^\]]*)\]');
  for (final match in filePattern.allMatches(content)) {
    final reference = _safeMediaReference(match.group(1));
    if (reference != null) {
      attachments.add(<String, dynamic>{
        'kind': 'file',
        'reference': reference,
        'name': match.group(2) ?? '',
        'mime': match.group(3) ?? '',
      });
    }
  }
  return attachments;
}

String? _safeMediaReference(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (trimmed.startsWith('data:') ||
      trimmed.startsWith('#') ||
      trimmed.startsWith('https://') ||
      trimmed.startsWith('http://')) {
    return trimmed;
  }
  // Local paths never cross the Web bridge. A later media request must be
  // validated and fulfilled by Dart for this opaque handle.
  return webChatMediaHandle(trimmed);
}

String webChatMediaHandle(String path) =>
    'local:${sha256.convert(utf8.encode(path)).toString()}';

String webChatBundledAssetHandle(String assetPath) =>
    'asset:${sha256.convert(utf8.encode(assetPath)).toString()}';

enum WebChatMediaSourceKind { localFile, bundledAsset }

class WebChatMediaSource {
  const WebChatMediaSource({required this.kind, required this.value});

  final WebChatMediaSourceKind kind;
  final String value;
}

Map<String, dynamic> buildWebChatUserSnapshot({
  required String name,
  String? avatarType,
  String? avatarValue,
}) {
  final value = avatarValue?.trim();
  return <String, dynamic>{
    'name': name,
    'avatarType': avatarType,
    'avatar': switch (avatarType) {
      'url' || 'file' => _safeMediaReference(value),
      _ => null,
    },
    'avatarLabel': avatarType == 'emoji' ? value : null,
  };
}

Map<String, WebChatMediaSource> buildWebChatMediaRegistry(
  List<ChatMessage> messages, {
  Assistant? assistant,
  String? userAvatarType,
  String? userAvatarValue,
}) {
  final registry = <String, WebChatMediaSource>{};
  void addFile(String? path) {
    final value = path?.trim();
    if (value == null ||
        value.isEmpty ||
        value.startsWith('data:') ||
        value.startsWith('#') ||
        value.startsWith('http://') ||
        value.startsWith('https://')) {
      return;
    }
    registry[webChatMediaHandle(value)] = WebChatMediaSource(
      kind: WebChatMediaSourceKind.localFile,
      value: value,
    );
  }

  void addAsset(String? path) {
    final value = path?.trim();
    if (value == null ||
        !value.startsWith('assets/icons/') ||
        value.contains('..') ||
        value.contains(r'\')) {
      return;
    }
    registry[webChatBundledAssetHandle(value)] = WebChatMediaSource(
      kind: WebChatMediaSourceKind.bundledAsset,
      value: value,
    );
  }

  final assistantAvatar = assistant?.avatar?.trim();
  if (assistantAvatar != null && _assistantAvatarIsMedia(assistantAvatar)) {
    if (assistantAvatar.startsWith('assets/icons/')) {
      addAsset(assistantAvatar);
    } else {
      addFile(assistantAvatar);
    }
  }
  addFile(assistant?.background);
  if (userAvatarType == 'file') addFile(userAvatarValue);
  final imagePattern = RegExp(r'\[image:([^\]]+)\]');
  final filePattern = RegExp(r'\[file:([^|\]]+)\|[^\]]*\]');
  for (final message in messages) {
    addAsset(_modelIconAsset(message));
    for (final match in imagePattern.allMatches(message.content)) {
      addFile(match.group(1));
    }
    for (final match in filePattern.allMatches(message.content)) {
      addFile(match.group(1));
    }
  }
  return registry;
}

String? _assistantAvatarReference(String? value) {
  final avatar = value?.trim();
  if (avatar == null || avatar.isEmpty) return null;
  if (avatar.startsWith('assets/icons/')) {
    return webChatBundledAssetHandle(avatar);
  }
  if (_assistantAvatarIsMedia(avatar)) {
    return _safeMediaReference(avatar);
  }
  return null;
}

String? _assistantAvatarLabel(String? value) {
  final avatar = value?.trim();
  if (avatar == null || avatar.isEmpty || _assistantAvatarIsMedia(avatar)) {
    return null;
  }
  return avatar;
}

bool _assistantAvatarIsMedia(String avatar) =>
    avatar.startsWith('data:') ||
    avatar.startsWith('http://') ||
    avatar.startsWith('https://') ||
    avatar.contains('/') ||
    avatar.contains(r'\') ||
    avatar.contains(':');
