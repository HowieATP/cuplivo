import 'dart:async';

import 'scroll_controller.dart' as scroll_ctrl;

class ConversationViewportAnchor {
  const ConversationViewportAnchor({
    required this.messageId,
    required this.offset,
  });

  final String messageId;
  final double offset;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'messageId': messageId,
    'offset': offset,
  };
}

abstract interface class ConversationViewportPort {
  bool get isUserScrolling;
  bool isNearBottom([double tolerance = 56]);
  bool hasEnoughContentToScroll([double minimumExtent = 56]);
  void handleUserScrollIntent();
  void onStreamTick();
  void scrollToTop({bool animate = true});
  void scrollToBottom({bool animate = true});
  Future<void> scrollToMessageId({
    required String targetId,
    required int targetIndex,
  });
  Future<bool> jumpToPreviousQuestion({
    required List<dynamic> messages,
    required int Function(String id) indexOfId,
  });
  Future<bool> jumpToNextQuestion({
    required List<dynamic> messages,
    required int Function(String id) indexOfId,
  });
  Future<ConversationViewportAnchor?> captureAnchor();
  Future<void> restoreAnchor(ConversationViewportAnchor anchor);
  ConversationViewportAnchor? savedAnchorForConversation(String conversationId);
}

class FlutterConversationViewportPort implements ConversationViewportPort {
  const FlutterConversationViewportPort(this.controller);

  final scroll_ctrl.ChatScrollController controller;

  @override
  bool get isUserScrolling => controller.isUserScrolling;

  @override
  bool isNearBottom([double tolerance = 56]) =>
      controller.isNearBottom(tolerance);

  @override
  bool hasEnoughContentToScroll([double minimumExtent = 56]) =>
      controller.hasEnoughContentToScroll(minimumExtent);

  @override
  void handleUserScrollIntent() => controller.handleUserScrollIntent();

  @override
  void onStreamTick() => controller.autoScrollToBottomIfNeeded();

  @override
  void scrollToTop({bool animate = true}) =>
      controller.scrollToTop(animate: animate);

  @override
  void scrollToBottom({bool animate = true}) =>
      controller.scrollToBottom(animate: animate);

  @override
  Future<void> scrollToMessageId({
    required String targetId,
    required int targetIndex,
  }) => controller.scrollToMessageId(
    targetId: targetId,
    targetIndex: targetIndex,
  );

  @override
  Future<bool> jumpToPreviousQuestion({
    required List<dynamic> messages,
    required int Function(String id) indexOfId,
  }) => controller.jumpToPreviousQuestion(
    messages: messages,
    indexOfId: indexOfId,
  );

  @override
  Future<bool> jumpToNextQuestion({
    required List<dynamic> messages,
    required int Function(String id) indexOfId,
  }) => controller.jumpToNextQuestion(messages: messages, indexOfId: indexOfId);

  @override
  Future<ConversationViewportAnchor?> captureAnchor() async {
    final messageId = controller.lastJumpUserMessageId;
    if (messageId == null || !controller.scrollController.hasClients) {
      return null;
    }
    return ConversationViewportAnchor(
      messageId: messageId,
      offset: controller.scrollController.offset,
    );
  }

  @override
  Future<void> restoreAnchor(ConversationViewportAnchor anchor) async {
    if (!controller.scrollController.hasClients) return;
    controller.scrollController.jumpTo(
      anchor.offset.clamp(
        controller.scrollController.position.minScrollExtent,
        controller.scrollController.position.maxScrollExtent,
      ),
    );
  }

  @override
  ConversationViewportAnchor? savedAnchorForConversation(
    String conversationId,
  ) => null;
}

typedef WebViewportCommandSender =
    Future<void> Function(Map<String, dynamic> command);

class WebConversationViewportPort implements ConversationViewportPort {
  WebViewportCommandSender? _sender;
  bool _isUserScrolling = false;
  double _pixels = 0;
  double _maxExtent = 0;
  ConversationViewportAnchor? _anchor;
  String? _activeConversationId;
  final Map<String, ConversationViewportAnchor> _savedAnchors =
      <String, ConversationViewportAnchor>{};

  void attach(WebViewportCommandSender sender) => _sender = sender;

  void detach(WebViewportCommandSender sender) {
    if (identical(_sender, sender)) _sender = null;
  }

  void activateConversation(String conversationId) {
    if (_activeConversationId == conversationId) return;
    _activeConversationId = conversationId;
    _isUserScrolling = false;
    _pixels = 0;
    _maxExtent = 0;
    _anchor = _savedAnchors[conversationId];
  }

  void updateMetrics(Map<String, dynamic> metrics) {
    final conversationId = metrics['conversationId']?.toString();
    final messageId = metrics['anchorMessageId']?.toString();
    ConversationViewportAnchor? measuredAnchor;
    if (messageId != null && messageId.isNotEmpty) {
      measuredAnchor = ConversationViewportAnchor(
        messageId: messageId,
        offset: (metrics['anchorOffset'] as num?)?.toDouble() ?? 0,
      );
      if (conversationId != null && conversationId.isNotEmpty) {
        _savedAnchors[conversationId] = measuredAnchor;
      }
    } else if (conversationId != null && conversationId.isNotEmpty) {
      _savedAnchors.remove(conversationId);
    }
    if (_activeConversationId == null &&
        conversationId != null &&
        conversationId.isNotEmpty) {
      _activeConversationId = conversationId;
    }
    if (conversationId != null &&
        conversationId.isNotEmpty &&
        conversationId != _activeConversationId) {
      return;
    }
    _isUserScrolling = metrics['isUserScrolling'] == true;
    _pixels = (metrics['pixels'] as num?)?.toDouble() ?? _pixels;
    _maxExtent = (metrics['maxExtent'] as num?)?.toDouble() ?? _maxExtent;
    _anchor = measuredAnchor;
  }

  Future<void> _command(String command, [Map<String, dynamic>? payload]) async {
    final sender = _sender;
    if (sender == null) return;
    await sender(<String, dynamic>{
      'type': 'viewportCommand',
      'command': command,
      if (payload != null) 'payload': payload,
    });
  }

  @override
  bool get isUserScrolling => _isUserScrolling;

  @override
  bool isNearBottom([double tolerance = 56]) =>
      _maxExtent - _pixels <= tolerance;

  @override
  bool hasEnoughContentToScroll([double minimumExtent = 56]) =>
      _maxExtent >= minimumExtent;

  @override
  void handleUserScrollIntent() {
    _isUserScrolling = true;
  }

  @override
  void onStreamTick() {
    if (!_isUserScrolling && isNearBottom()) {
      unawaited(_command('bottom', <String, dynamic>{'animate': false}));
    }
  }

  @override
  void scrollToTop({bool animate = true}) =>
      unawaited(_command('top', <String, dynamic>{'animate': animate}));

  @override
  void scrollToBottom({bool animate = true}) =>
      unawaited(_command('bottom', <String, dynamic>{'animate': animate}));

  @override
  Future<void> scrollToMessageId({
    required String targetId,
    required int targetIndex,
  }) => _command('message', <String, dynamic>{'messageId': targetId});

  @override
  Future<bool> jumpToPreviousQuestion({
    required List<dynamic> messages,
    required int Function(String id) indexOfId,
  }) async {
    if (_sender == null) return false;
    await _command('previousQuestion');
    return true;
  }

  @override
  Future<bool> jumpToNextQuestion({
    required List<dynamic> messages,
    required int Function(String id) indexOfId,
  }) async {
    if (_sender == null) return false;
    await _command('nextQuestion');
    return true;
  }

  @override
  Future<ConversationViewportAnchor?> captureAnchor() async => _anchor;

  @override
  Future<void> restoreAnchor(ConversationViewportAnchor anchor) {
    _anchor = anchor;
    return _command('restoreAnchor', anchor.toJson());
  }

  @override
  ConversationViewportAnchor? savedAnchorForConversation(
    String conversationId,
  ) => _savedAnchors[conversationId];
}
