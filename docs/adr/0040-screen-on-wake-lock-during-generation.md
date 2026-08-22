# ADR-0040: Screen-on Wake Lock During Generation

Mobile chat generation holds the screen on (`wakelock_plus`, Android
`FLAG_KEEP_SCREEN_ON` / iOS `idleTimerDisabled`) so the user can watch the
stream without the display sleeping — the classic chat-app behavior. Always-on
(no user setting): the cost of an interrupted stream outweighs battery.

## Why the engine, not the page layer

The lock is acquired inside `GenerationEngine._runSlot` and released in its
`finally`, via an injectable refcounted `WakeLockManager`
(`lib/core/services/wake_lock_manager.dart`). The naive alternative would
toggle the lock in page-level stream adapters, which exist in parallel for
page / Multi-AI / group-chat / subagent. The engine is the single choke point;
a refcount over running slots makes Multi-AI (N slots) the natural case and
single AI the degenerate case — the same argument as ADR-0034. Images-API
image generation streams through the engine's chunk loop and is covered
automatically.

## Considered and rejected

- **CPU / background lock**: already owned by `AndroidBackgroundManager`
  (flutter_background foreground service, Android-only, user-toggled). The
  wake lock only keeps the *screen* on; the two mechanisms are orthogonal.
- **Desktop**: `wakelock_plus` nominally supports Windows/macOS/Linux, but an
  actively watched stream implies a live monitor. Excluded to avoid plugin
  surface on three more platforms.
- **User toggle**: rejected — always-on. A leaked hold (refcount bug) is a
  battery bug the tests cover, not a preference.
- **App-lifecycle hook**: rejected — the Android window flag is
  foreground-scoped by construction; backgrounding naturally ends the
  screen-on state. An observer would be dead code.
- **Hand-rolled platform channels**: rejected per repo protocol (prefer
  mature third-party libraries).

## Consequences

- New dependency `wakelock_plus`.
- Future generation paths outside the engine (new layer-① consumers) silently
  lack the lock — the engine-boundary rule must be respected.
- The refcount's failure mode is a leaked hold (screen never sleeps, battery);
  the test set covers done / error / cancel / pre-start-abort / `failRound`
  settlement paths.
