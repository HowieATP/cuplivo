/// Shared layout constants for the Home chat UI (desktop/tablet).
class ChatLayoutConstants {
  /// Max readable width for the chat message list area.
  static const double maxContentWidth = 860.0;

  /// Max width for the chat input bar area.
  static const double maxInputWidth = 860.0;

  /// Duration of the fade-then-collapse deletion animation. The widget wraps
  /// flagged slots ([MessageListView] `removingSlotIds`) with
  /// [_SlotRemovalAnimator]; wiring the controller-side wait/release flow is
  /// still pending, so today removals apply instantly.
  static const Duration slotRemovalAnimationDuration = Duration(
    milliseconds: 240,
  );
}
