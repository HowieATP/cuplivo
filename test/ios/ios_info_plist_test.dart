import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the iOS ProMotion unlock key.
///
/// Flutter 3.44 configures its own CADisplayLink from this Info.plist key;
/// losing it would silently cap the app at 60Hz on ProMotion devices even
/// though the engine supports variable refresh rates.
void main() {
  test('Info.plist keeps CADisableMinimumFrameDurationOnPhone=true', () {
    final plist = File('ios/Runner/Info.plist');
    expect(
      plist.existsSync(),
      isTrue,
      reason: 'ios/Runner/Info.plist must exist in the repo',
    );
    final content = plist.readAsStringSync();
    expect(
      content,
      contains('<key>CADisableMinimumFrameDurationOnPhone</key>'),
      reason:
          'the ProMotion unlock key must not be dropped by iOS '
          'project regeneration or merges',
    );
    expect(
      content,
      matches(
        RegExp(
          r'<key>\s*CADisableMinimumFrameDurationOnPhone\s*</key>\s*'
          r'<\s*true\s*/\s*>',
        ),
      ),
      reason:
          'the key must be <true/> so Flutter can drive the display at '
          'its dynamic refresh rate',
    );
  });
}
