import 'dart:async';

class MessageLocateTarget {
  const MessageLocateTarget({
    required this.conversationId,
    required this.messageId,
  });

  final String conversationId;
  final String messageId;
}

/// Mirrors DesktopSettingsNavigationBus.
/// DOCUMENTED STOPGAP (ADR-0005): delete once HomePageController is promoted
/// to a root provider. Then Storage page can `context.read<HomePageController>()`
/// and call `openGlobalSearchResult()` directly.
class MessageLocateBus {
  MessageLocateBus._();

  static final MessageLocateBus instance = MessageLocateBus._();

  final StreamController<MessageLocateTarget> _controller =
      StreamController<MessageLocateTarget>.broadcast();

  Stream<MessageLocateTarget> get stream => _controller.stream;

  void fire({required String conversationId, required String messageId}) {
    _controller.add(
      MessageLocateTarget(conversationId: conversationId, messageId: messageId),
    );
  }
}
