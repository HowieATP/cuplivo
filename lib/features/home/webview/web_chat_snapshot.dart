import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
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
    required Assistant? assistant,
    required double fontScale,
    required bool canStartMultiAI,
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
            canStartMultiAI: canStartMultiAI,
          ),
      ],
      'suggestions': suggestions,
      'hasMoreBefore': hasMoreBefore,
      'hasMoreAfter': hasMoreAfter,
      'strings': strings,
      'theme': theme,
      'fontScale': fontScale,
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
    required bool canStartMultiAI,
  }) {
    final versions = byGroup[message.groupId] ?? <ChatMessage>[message];
    final legacy = ThinkingTagParser.parseLegacyInlineBlocks(message.content);
    final visualContent = message.role == 'assistant'
        ? messageVisualContent(message, assistant: assistant)
        : _userVisualContent(message.content);
    return <String, dynamic>{
      'id': message.id,
      'index': index,
      'role': message.role,
      'content': visualContent,
      'legacyThinking': legacy.thinkingTexts,
      'timestamp': message.timestamp.toIso8601String(),
      'modelId': message.modelId,
      'providerId': message.providerId,
      'tokens': message.contextTokens ?? message.totalTokens,
      'promptTokens': message.promptTokens,
      'completionTokens': message.completionTokens,
      'cachedTokens': message.cachedTokens,
      'durationMs': message.durationMs,
      'isStreaming': message.isStreaming,
      'isPreset': message.isPreset,
      'translation': message.translation,
      'reasoning': _reasoning(message, reasoning, reasoningSegments),
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
      'selectedVersion': versionSelections[message.groupId] ?? message.version,
      'actions': <String>[
        'copy',
        if (message.role == 'user') 'edit',
        if (message.role == 'user') 'resend' else 'regenerate',
        'quote',
        'translate',
        'speak',
        'share',
        'fork',
        'select',
        'delete',
        if (message.role == 'assistant' && canStartMultiAI) 'multiAI',
      ],
    };
  }

  List<Map<String, dynamic>> _reasoning(
    ChatMessage message,
    stream_ctrl.ReasoningData? live,
    List<stream_ctrl.ReasoningSegmentData>? liveSegments,
  ) {
    if (liveSegments != null && liveSegments.isNotEmpty) {
      return liveSegments
          .map(
            (segment) => <String, dynamic>{
              'text': segment.text,
              'expanded': segment.expanded,
              'loading': segment.finishedAt == null && message.isStreaming,
              'startAt': segment.startAt?.toIso8601String(),
              'finishedAt': segment.finishedAt?.toIso8601String(),
              'toolStartIndex': segment.toolStartIndex,
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
              .map(
                (segment) => segment.map(
                  (key, value) => MapEntry(key.toString(), value),
                ),
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
    if (text == null || text.isEmpty) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'text': text,
        'expanded': live?.expanded ?? true,
        'loading': message.isStreaming && live?.finishedAt == null,
        'startAt': (live?.startAt ?? message.reasoningStartAt)
            ?.toIso8601String(),
        'finishedAt': (live?.finishedAt ?? message.reasoningFinishedAt)
            ?.toIso8601String(),
        'toolStartIndex': 0,
      },
    ];
  }
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

Map<String, String> buildWebChatLocalMediaRegistry(
  List<ChatMessage> messages, {
  Assistant? assistant,
}) {
  final registry = <String, String>{};
  void add(String? path) {
    final value = path?.trim();
    if (value == null ||
        value.isEmpty ||
        value.startsWith('data:') ||
        value.startsWith('#') ||
        value.startsWith('http://') ||
        value.startsWith('https://')) {
      return;
    }
    registry[webChatMediaHandle(value)] = value;
  }

  final assistantAvatar = assistant?.avatar?.trim();
  if (assistantAvatar != null &&
      (assistantAvatar.startsWith('/') || assistantAvatar.contains(':'))) {
    add(assistantAvatar);
  }
  add(assistant?.background);
  final imagePattern = RegExp(r'\[image:([^\]]+)\]');
  final filePattern = RegExp(r'\[file:([^|\]]+)\|[^\]]*\]');
  for (final message in messages) {
    for (final match in imagePattern.allMatches(message.content)) {
      add(match.group(1));
    }
    for (final match in filePattern.allMatches(message.content)) {
      add(match.group(1));
    }
  }
  return registry;
}

String? _assistantAvatarReference(String? value) {
  final avatar = value?.trim();
  if (avatar == null || avatar.isEmpty) return null;
  if (avatar.startsWith('data:') ||
      avatar.startsWith('http://') ||
      avatar.startsWith('https://') ||
      avatar.startsWith('/') ||
      avatar.contains(':')) {
    return _safeMediaReference(avatar);
  }
  return null;
}

String? _assistantAvatarLabel(String? value) {
  final avatar = value?.trim();
  if (avatar == null ||
      avatar.isEmpty ||
      avatar.startsWith('data:') ||
      avatar.startsWith('http://') ||
      avatar.startsWith('https://') ||
      avatar.startsWith('/') ||
      avatar.contains(':')) {
    return null;
  }
  return avatar;
}
