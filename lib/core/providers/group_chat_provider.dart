import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/conversation.dart';
import '../models/director_message.dart';
import '../models/group_chat.dart';
import '../models/group_chat_member.dart';
import '../models/assistant_detail_injection.dart';
import '../services/chat/chat_service.dart';
import '../services/deleted_records_store.dart';

/// Soft / hard caps for assistant members (excluding the user).
const int groupChatMemberSoftCap = 12;
const int groupChatMemberHardCap = 20;

class GroupChatProvider extends ChangeNotifier {
  GroupChatProvider({required this.chatService});

  final ChatService chatService;
  ChatService get _chatService => chatService;
  final List<GroupChat> _groups = [];
  final Map<String, List<GroupChatMember>> _membersByGroup = {};
  bool _loaded = false;

  bool get loaded => _loaded;
  List<GroupChat> get groups => List.unmodifiable(_groups);

  Future<void> load() async {
    if (!_chatService.initialized) {
      await _chatService.init();
    }
    final list = await _chatService.repo.getAllGroupChats();
    _groups
      ..clear()
      ..addAll(list);
    _membersByGroup.clear();
    for (final g in list) {
      _membersByGroup[g.id] = await _chatService.repo.getGroupMembers(g.id);
    }
    _loaded = true;
    notifyListeners();
  }

  GroupChat? getById(String id) {
    for (final g in _groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  List<GroupChatMember> membersOf(String groupChatId) {
    return List.unmodifiable(_membersByGroup[groupChatId] ?? const []);
  }

  List<String> assistantIdsOf(String groupChatId) {
    return membersOf(groupChatId)
        .where((m) => !m.isUser && m.assistantId != null)
        .map((m) => m.assistantId!)
        .toList(growable: false);
  }

  /// Latest public message preview for list subtitle.
  String? latestMessagePreview(String groupChatId) {
    final g = getById(groupChatId);
    if (g == null) return null;
    final msgs = _chatService.getMessages(g.conversationId);
    if (msgs.isEmpty) return null;
    final last = msgs.last;
    final t = last.content.trim();
    if (t.isEmpty) return null;
    return t.length > 80 ? '${t.substring(0, 80)}…' : t;
  }

  Future<GroupChat> createGroup({required String name}) async {
    final conversation = await _chatService.createConversation(
      title: name.trim().isEmpty ? 'Group' : name.trim(),
      assistantId: null,
      conversationKind: Conversation.kindGroup,
      setAsCurrent: false,
    );

    final group = GroupChat(
      name: name.trim().isEmpty ? 'Group' : name.trim(),
      conversationId: conversation.id,
      directorSystemPrompt: GroupChat.defaultDirectorSystemPrompt,
      maxAssistantMessagesPerRound: 3,
      assistantDetailInjectionMode:
          AssistantDetailInjectionMode.endOfEveryUserMessage,
      assistantDetailInjectionN: 5,
    );

    await _chatService.repo.putGroupChat(group);
    final members = [GroupChatMember.user(groupChatId: group.id, sortOrder: 0)];
    await _chatService.repo.putGroupMembers(group.id, members);

    _groups.insert(0, group);
    _membersByGroup[group.id] = members;
    notifyListeners();
    return group;
  }

  Future<void> updateGroup(GroupChat group) async {
    final updated = group.copyWith(updatedAt: DateTime.now());
    await _chatService.repo.putGroupChat(updated);
    final idx = _groups.indexWhere((g) => g.id == updated.id);
    if (idx >= 0) {
      _groups[idx] = updated;
    } else {
      _groups.add(updated);
    }
    // Keep conversation title in sync with group name.
    final conv = _chatService.getConversation(updated.conversationId);
    if (conv != null && conv.title != updated.name) {
      conv.title = updated.name;
      await _chatService.repo.putConversation(conv);
    }
    notifyListeners();
  }

  Future<void> touchUpdatedAt(String groupChatId) async {
    final g = getById(groupChatId);
    if (g == null) return;
    await updateGroup(g.copyWith(updatedAt: DateTime.now()));
  }

  Future<void> setMembers(String groupChatId, List<String> assistantIds) async {
    final unique = assistantIds.toSet().toList();
    if (unique.length > groupChatMemberHardCap) {
      throw StateError('member_hard_cap');
    }
    final members = <GroupChatMember>[
      GroupChatMember.user(groupChatId: groupChatId, sortOrder: 0),
    ];
    for (var i = 0; i < unique.length; i++) {
      members.add(
        GroupChatMember.assistant(
          groupChatId: groupChatId,
          assistantId: unique[i],
          sortOrder: i + 1,
        ),
      );
    }
    await _chatService.repo.putGroupMembers(groupChatId, members);
    _membersByGroup[groupChatId] = members;
    notifyListeners();
  }

  Future<void> addAssistants(
    String groupChatId,
    List<String> assistantIds,
  ) async {
    final current = assistantIdsOf(groupChatId).toSet();
    for (final id in assistantIds) {
      current.add(id);
    }
    if (current.length > groupChatMemberHardCap) {
      throw StateError('member_hard_cap');
    }
    await setMembers(groupChatId, current.toList());
  }

  Future<void> removeAssistant(String groupChatId, String assistantId) async {
    final ids = assistantIdsOf(groupChatId)
      ..removeWhere((id) => id == assistantId);
    await setMembers(groupChatId, ids);
  }

  Future<void> removeAssistantFromAllGroups(String assistantId) async {
    await _chatService.repo.removeAssistantFromAllGroups(assistantId);
    for (final entry in _membersByGroup.entries.toList()) {
      final next = entry.value
          .where((m) => m.assistantId != assistantId)
          .toList();
      if (next.length != entry.value.length) {
        _membersByGroup[entry.key] = next;
      }
    }
    notifyListeners();
  }

  Future<List<DirectorMessage>> directorMessages(String groupChatId) {
    return _chatService.repo.getDirectorMessages(groupChatId);
  }

  Future<void> persistGroupState(GroupChat group) async {
    await _chatService.repo.putGroupChat(group);
    final idx = _groups.indexWhere((g) => g.id == group.id);
    if (idx >= 0) _groups[idx] = group;
    notifyListeners();
  }

  /// Full delete with trash packaging.
  Future<void> deleteGroup(String groupChatId) async {
    final group = getById(groupChatId);
    if (group == null) return;

    final members = membersOf(groupChatId);
    final directorMsgs = await _chatService.repo.getDirectorMessages(
      groupChatId,
    );
    final store = _chatService.deletedRecordsStore;
    final batchId = const Uuid().v4();
    final deletedAt = DateTime.now();

    if (store != null) {
      final recovery = jsonEncode({
        'groupChat': group.toJson(),
        'members': members.map((m) => m.toJson()).toList(),
        'directorMessages': directorMsgs.map((m) => m.toJson()).toList(),
        'conversationId': group.conversationId,
      });
      await store.recordDeletion(
        id: groupChatId,
        type: DeletionEntityType.groupChat,
        recoveryJson: recovery,
        batchId: batchId,
        deletedAt: deletedAt,
      );
    }

    // Delete group row first (cascades members + director); then conversation
    // with allowGroup so trash for conversation may also run.
    await _chatService.repo.deleteGroupChat(groupChatId);
    try {
      await _chatService.deleteConversation(
        group.conversationId,
        allowGroup: true,
      );
    } catch (e) {
      debugPrint('[GroupChatProvider] delete conversation: $e');
      // Conversation may already be cascade-deleted if FK fired; ensure cache.
      await _chatService.repo.deleteConversation(group.conversationId);
    }

    _groups.removeWhere((g) => g.id == groupChatId);
    _membersByGroup.remove(groupChatId);
    notifyListeners();
  }
}
