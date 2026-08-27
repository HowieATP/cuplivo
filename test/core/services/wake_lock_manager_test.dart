import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/wake_lock_manager.dart';

void main() {
  late List<bool> calls;
  late WakeLockManager manager;

  WakeLockManager build({
    bool mobile = true,
    bool Function()? isEnabled,
    Future<void> Function(bool enabled)? applyLock,
  }) {
    calls = [];
    manager = WakeLockManager(
      isMobilePlatform: () => mobile,
      isEnabled: isEnabled,
      applyLock:
          applyLock ??
          (enabled) async {
            calls.add(enabled);
          },
    );
    return manager;
  }

  test('non-mobile platforms are a complete no-op', () async {
    build(mobile: false);
    manager.acquire();
    manager.acquire();
    manager.release();
    manager.reset();
    await pumpEventQueue();
    expect(calls, isEmpty);
    expect(manager.isHeld, isFalse);
  });

  test(
    'acquire enables the lock once, even for concurrent references',
    () async {
      build();
      manager.acquire();
      manager.acquire();
      await pumpEventQueue();
      expect(calls, [true]);
      expect(manager.isHeld, isTrue);
    },
  );

  test(
    'release disables the lock only when the last reference is released',
    () async {
      build();
      manager.acquire();
      manager.acquire();
      manager.release();
      await pumpEventQueue();
      expect(calls, [true]);
      expect(manager.isHeld, isTrue);

      manager.release();
      await pumpEventQueue();
      expect(calls, [true, false]);
      expect(manager.isHeld, isFalse);
    },
  );

  test(
    'spurious releases are ignored; the count never goes negative',
    () async {
      build();
      manager.release();
      manager.release();
      await pumpEventQueue();
      expect(calls, isEmpty);
      expect(manager.isHeld, isFalse);

      manager.acquire();
      manager.release();
      manager.release();
      await pumpEventQueue();
      expect(calls, [true, false]);
      expect(manager.isHeld, isFalse);
    },
  );

  test('reset drops every reference and forces the lock off', () async {
    build();
    manager.acquire();
    manager.acquire();
    manager.reset();
    await pumpEventQueue();
    expect(calls, [true, false]);
    expect(manager.isHeld, isFalse);

    // A late release after reset is a no-op — no extra platform call.
    manager.release();
    await pumpEventQueue();
    expect(calls, [true, false]);
  });

  test(
    'a disabled toggle never touches the platform, but refcount stays balanced',
    () async {
      build(isEnabled: () => false);
      manager.acquire();
      manager.acquire();
      manager.release();
      manager.reset();
      await pumpEventQueue();
      expect(calls, isEmpty);
      expect(manager.isHeld, isFalse);
    },
  );

  test(
    'a new enabled slot while an older disabled round runs turns the screen on',
    () async {
      var enabled = false;
      build(isEnabled: () => enabled);
      manager.acquire();
      await pumpEventQueue();
      expect(calls, isEmpty);
      expect(manager.isHeld, isTrue);

      enabled = true;
      manager.acquire();
      await pumpEventQueue();
      expect(calls, [true]);

      manager.release();
      manager.release();
      await pumpEventQueue();
      expect(calls, [true, false]);
      expect(manager.isHeld, isFalse);
    },
  );

  test(
    'full user flow: off round settles, then on round acquires the lock',
    () async {
      var enabled = false;
      build(isEnabled: () => enabled);
      manager.acquire();
      manager.release();
      await pumpEventQueue();
      expect(calls, isEmpty);

      enabled = true;
      manager.acquire();
      await pumpEventQueue();
      expect(calls, [true]);
      expect(manager.isHeld, isTrue);

      manager.release();
      await pumpEventQueue();
      expect(calls, [true, false]);
    },
  );

  test(
    'toggling off mid-generation keeps the lock until the last release',
    () async {
      var enabled = true;
      build(isEnabled: () => enabled);
      manager.acquire();
      await pumpEventQueue();
      expect(calls, [true]);
      expect(manager.isHeld, isTrue);

      enabled = false;
      manager.release();
      await pumpEventQueue();
      expect(calls, [true, false]);
      expect(manager.isHeld, isFalse);
    },
  );

  test(
    'a failing platform call is logged, never rethrown into generation',
    () async {
      build(
        applyLock: (enabled) async {
          calls.add(enabled);
          throw StateError('plugin channel dead');
        },
      );
      manager.acquire();
      manager.release();
      await pumpEventQueue();
      expect(calls, [true, false]);
      expect(manager.isHeld, isFalse);
    },
  );
}
