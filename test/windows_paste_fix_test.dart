import 'dart:ui';

import 'package:Cuplivo/desktop/windows_paste_fix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const junkPhysical = 0x1600000000;
  const cleanPhysicalCtrl = 0x700e0;
  const cleanPhysicalV = 0x70019;
  const logicalCtrl = 0x200000100;
  const logicalV = 0x76;

  late WindowsPasteFix fix;

  KeyData makeKey({
    required KeyEventType type,
    required int physical,
    required int logical,
    bool synthesized = false,
  }) {
    return KeyData(
      timeStamp: Duration.zero,
      type: type,
      physical: physical,
      logical: logical,
      character: null,
      synthesized: synthesized,
    );
  }

  KeyData ctrlDown({bool synthesized = false, int physical = junkPhysical}) =>
      makeKey(
        type: KeyEventType.down,
        physical: physical,
        logical: logicalCtrl,
        synthesized: synthesized,
      );

  KeyData ctrlUp({bool synthesized = false, int physical = junkPhysical}) =>
      makeKey(
        type: KeyEventType.up,
        physical: physical,
        logical: logicalCtrl,
        synthesized: synthesized,
      );

  KeyData vDown({int physical = junkPhysical}) =>
      makeKey(type: KeyEventType.down, physical: physical, logical: logicalV);

  KeyData vUp({int physical = junkPhysical}) =>
      makeKey(type: KeyEventType.up, physical: physical, logical: logicalV);

  setUp(() {
    fix = WindowsPasteFix.instance;
    fix.resetState();
  });

  group('normal hardware keys passthrough', () {
    test('regular key passes through and resets state', () {
      final key = makeKey(
        type: KeyEventType.down,
        physical: 0x70004,
        logical: 0x61,
      );
      final result = fix.rewrite(key);
      expect(result, same(key));
    });

    test('regular key resets mid-sequence state', () {
      fix.rewrite(ctrlDown());
      expect(fix.rewrite(ctrlDown()), isNotNull);
    });
  });

  group('all-zero garbage events', () {
    test('swallows all-zero event', () {
      final key = makeKey(type: KeyEventType.down, physical: 0, logical: 0);
      expect(fix.rewrite(key), isNull);
    });
  });

  group('full Win+V 6-step sequence', () {
    test('rewrites complete sequence correctly', () {
      final step1 = fix.rewrite(ctrlDown(synthesized: false));
      expect(step1, isNotNull);
      expect(step1!.type, KeyEventType.down);
      expect(step1.physical, cleanPhysicalCtrl);
      expect(step1.logical, logicalCtrl);
      expect(step1.synthesized, isFalse);

      final step2 = fix.rewrite(ctrlUp(synthesized: true));
      expect(step2, isNull);

      final step3 = fix.rewrite(vDown());
      expect(step3, isNotNull);
      expect(step3!.type, KeyEventType.down);
      expect(step3.physical, cleanPhysicalV);
      expect(step3.logical, logicalV);
      expect(step3.synthesized, isFalse);

      final step4 = fix.rewrite(vUp());
      expect(step4, isNotNull);
      expect(step4!.type, KeyEventType.up);
      expect(step4.physical, cleanPhysicalV);
      expect(step4.logical, logicalV);
      expect(step4.synthesized, isFalse);

      final step5 = fix.rewrite(ctrlDown(synthesized: true));
      expect(step5, isNull);

      final step6 = fix.rewrite(ctrlUp(synthesized: true));
      expect(step6, isNotNull);
      expect(step6!.type, KeyEventType.up);
      expect(step6.physical, cleanPhysicalCtrl);
      expect(step6.logical, logicalCtrl);
      expect(step6.synthesized, isFalse);
    });

    test('state resets after complete sequence', () {
      fix.rewrite(ctrlDown(synthesized: false));
      fix.rewrite(ctrlUp(synthesized: true));
      fix.rewrite(vDown());
      fix.rewrite(vUp());
      fix.rewrite(ctrlDown(synthesized: true));
      fix.rewrite(ctrlUp(synthesized: true));

      final next = fix.rewrite(ctrlDown(synthesized: false));
      expect(next, isNotNull);
      expect(next!.physical, cleanPhysicalCtrl);
    });
  });

  group('broken sequence reset', () {
    test('step 0: V down instead of Ctrl down resets', () {
      final result = fix.rewrite(vDown());
      expect(result, isNotNull);
      expect(result!.physical, junkPhysical);
    });

    test('step 1: Ctrl down instead of Ctrl up resets and passes through', () {
      fix.rewrite(ctrlDown(synthesized: false));
      final result = fix.rewrite(ctrlDown(synthesized: false));
      expect(result, isNotNull);
      expect(result!.physical, junkPhysical);
    });

    test('step 2: Ctrl down instead of V down resets and passes through', () {
      fix.rewrite(ctrlDown(synthesized: false));
      fix.rewrite(ctrlUp(synthesized: true));
      final result = fix.rewrite(ctrlDown(synthesized: false));
      expect(result, isNotNull);
      expect(result!.physical, junkPhysical);
    });

    test('step 3: Ctrl down instead of V up resets and passes through', () {
      fix.rewrite(ctrlDown(synthesized: false));
      fix.rewrite(ctrlUp(synthesized: true));
      fix.rewrite(vDown());
      final result = fix.rewrite(ctrlDown(synthesized: false));
      expect(result, isNotNull);
      expect(result!.physical, junkPhysical);
    });

    test('step 4: V down instead of Ctrl down resets', () {
      fix.rewrite(ctrlDown(synthesized: false));
      fix.rewrite(ctrlUp(synthesized: true));
      fix.rewrite(vDown());
      fix.rewrite(vUp());
      final result = fix.rewrite(vDown());
      expect(result, isNotNull);
      expect(result!.physical, junkPhysical);
    });

    test('step 5: V up instead of Ctrl up resets', () {
      fix.rewrite(ctrlDown(synthesized: false));
      fix.rewrite(ctrlUp(synthesized: true));
      fix.rewrite(vDown());
      fix.rewrite(vUp());
      fix.rewrite(ctrlDown(synthesized: true));
      final result = fix.rewrite(vUp());
      expect(result, isNotNull);
      expect(result!.physical, junkPhysical);
    });
  });

  group('repeated sequences', () {
    test('two consecutive Win+V sequences both rewrite correctly', () {
      for (var i = 0; i < 2; i++) {
        final s1 = fix.rewrite(ctrlDown(synthesized: false));
        expect(s1!.physical, cleanPhysicalCtrl, reason: 'iter $i step1');

        expect(
          fix.rewrite(ctrlUp(synthesized: true)),
          isNull,
          reason: 'iter $i step2',
        );

        final s3 = fix.rewrite(vDown());
        expect(s3!.physical, cleanPhysicalV, reason: 'iter $i step3');

        final s4 = fix.rewrite(vUp());
        expect(s4!.physical, cleanPhysicalV, reason: 'iter $i step4');

        expect(
          fix.rewrite(ctrlDown(synthesized: true)),
          isNull,
          reason: 'iter $i step5',
        );

        final s6 = fix.rewrite(ctrlUp(synthesized: true));
        expect(s6!.physical, cleanPhysicalCtrl, reason: 'iter $i step6');
      }
    });
  });
}
