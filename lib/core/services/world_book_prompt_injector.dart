import 'package:flutter/foundation.dart';

import '../models/world_book.dart';

/// Applies world-book entries to an already assembled API message list.
class WorldBookPromptInjector {
  const WorldBookPromptInjector._();

  static void inject({
    required List<Map<String, dynamic>> messages,
    required Iterable<WorldBook> books,
    required Iterable<String> activeBookIds,
  }) {
    final activeSet = activeBookIds.toSet();
    if (activeSet.isEmpty) return;

    final activeBooks = books
        .where((book) => book.enabled && activeSet.contains(book.id))
        .toList(growable: false);
    if (activeBooks.isEmpty) return;

    String extractContextForDepth(int scanDepth) {
      final depth = scanDepth <= 0 ? 1 : scanDepth;
      final parts = <String>[];
      for (var i = messages.length - 1; i >= 0 && parts.length < depth; i--) {
        final role = (messages[i]['role'] ?? '').toString();
        if (role != 'user' && role != 'assistant') continue;
        final content = (messages[i]['content'] ?? '').toString().trim();
        if (content.isEmpty) continue;
        parts.add(content);
      }
      return parts.reversed.join('\n');
    }

    bool isTriggered(WorldBookEntry entry, String context) {
      if (!entry.enabled) return false;
      if (entry.constantActive) return true;
      if (entry.keywords.isEmpty) return false;

      for (final raw in entry.keywords) {
        final keyword = raw.trim();
        if (keyword.isEmpty) continue;
        if (entry.useRegex) {
          try {
            final regex = RegExp(keyword, caseSensitive: entry.caseSensitive);
            if (regex.hasMatch(context)) return true;
          } on FormatException catch (error) {
            debugPrint(
              '[WorldBookPromptInjector] Invalid regex "$keyword": $error',
            );
          }
        } else if (entry.caseSensitive) {
          if (context.contains(keyword)) return true;
        } else if (context.toLowerCase().contains(keyword.toLowerCase())) {
          return true;
        }
      }
      return false;
    }

    final contextCache = <int, String>{};
    final triggered = <({WorldBookEntry entry, int sequence})>[];
    var sequence = 0;
    for (final book in activeBooks) {
      for (final entry in book.entries) {
        final depth = (entry.scanDepth <= 0 ? 1 : entry.scanDepth)
            .clamp(1, 200)
            .toInt();
        final context = contextCache.putIfAbsent(
          depth,
          () => extractContextForDepth(depth),
        );
        if (isTriggered(entry, context)) {
          triggered.add((entry: entry, sequence: sequence));
        }
        sequence++;
      }
    }
    if (triggered.isEmpty) return;

    triggered.sort((a, b) {
      final priority = b.entry.priority.compareTo(a.entry.priority);
      return priority != 0 ? priority : a.sequence.compareTo(b.sequence);
    });

    String joinContents(Iterable<WorldBookEntry> entries) => entries
        .map((entry) => entry.content.trim())
        .where((content) => content.isNotEmpty)
        .join('\n');

    List<Map<String, dynamic>> createMergedMessages(
      List<WorldBookEntry> entries,
    ) {
      final byRole = <WorldBookInjectionRole, List<WorldBookEntry>>{};
      for (final entry in entries) {
        if (entry.content.trim().isEmpty) continue;
        byRole.putIfAbsent(entry.role, () => <WorldBookEntry>[]).add(entry);
      }
      final result = <Map<String, dynamic>>[];
      for (final role in byRole.keys) {
        final merged = joinContents(byRole[role]!);
        if (merged.isEmpty) continue;
        result.add({
          'role': role == WorldBookInjectionRole.assistant
              ? 'assistant'
              : 'user',
          'content': role == WorldBookInjectionRole.assistant
              ? merged
              : '<system>\n$merged\n</system>',
        });
      }
      return result;
    }

    int findSafeInsertIndex(int target) {
      var index = target.clamp(0, messages.length);
      while (index > 0 && index < messages.length) {
        if ((messages[index]['role'] ?? '').toString() != 'tool') break;
        index--;
      }
      return index;
    }

    final byPosition = <WorldBookInjectionPosition, List<WorldBookEntry>>{};
    for (final item in triggered) {
      byPosition
          .putIfAbsent(item.entry.position, () => <WorldBookEntry>[])
          .add(item.entry);
    }

    final before = joinContents(
      byPosition[WorldBookInjectionPosition.beforeSystemPrompt] ??
          const <WorldBookEntry>[],
    );
    final after = joinContents(
      byPosition[WorldBookInjectionPosition.afterSystemPrompt] ??
          const <WorldBookEntry>[],
    );
    if (before.isNotEmpty || after.isNotEmpty) {
      final systemIndex = messages.indexWhere(
        (message) => (message['role'] ?? '').toString() == 'system',
      );
      if (systemIndex >= 0) {
        final original = (messages[systemIndex]['content'] ?? '').toString();
        messages[systemIndex]['content'] = [
          if (before.isNotEmpty) before,
          original,
          if (after.isNotEmpty) after,
        ].join('\n');
      } else {
        messages.insert(0, {
          'role': 'system',
          'content': [
            if (before.isNotEmpty) before,
            if (after.isNotEmpty) after,
          ].join('\n'),
        });
      }
    }

    final top = byPosition[WorldBookInjectionPosition.topOfChat];
    if (top != null && top.isNotEmpty) {
      var index = messages.indexWhere(
        (message) => (message['role'] ?? '').toString() == 'user',
      );
      if (index < 0) index = messages.length;
      messages.insertAll(findSafeInsertIndex(index), createMergedMessages(top));
    }

    final bottom = byPosition[WorldBookInjectionPosition.bottomOfChat];
    if (bottom != null && bottom.isNotEmpty) {
      final target = messages.isEmpty ? 0 : messages.length - 1;
      messages.insertAll(
        findSafeInsertIndex(target),
        createMergedMessages(bottom),
      );
    }

    final atDepth = byPosition[WorldBookInjectionPosition.atDepth];
    if (atDepth != null && atDepth.isNotEmpty) {
      final byDepth = <int, List<WorldBookEntry>>{};
      for (final entry in atDepth) {
        final depth = (entry.injectDepth <= 0 ? 1 : entry.injectDepth)
            .clamp(1, 200)
            .toInt();
        byDepth.putIfAbsent(depth, () => <WorldBookEntry>[]).add(entry);
      }
      final depths = byDepth.keys.toList(growable: false)
        ..sort((a, b) => b.compareTo(a));
      for (final depth in depths) {
        final index = findSafeInsertIndex(
          (messages.length - depth).clamp(0, messages.length),
        );
        messages.insertAll(index, createMergedMessages(byDepth[depth]!));
      }
    }
  }
}
