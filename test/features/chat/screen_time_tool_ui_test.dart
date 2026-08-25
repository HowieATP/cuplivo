import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/chat/widgets/screen_time_tool_ui.dart';

void main() {
  group('ScreenTimeResult.tryParse', () {
    test('parses a valid payload with apps, minutes and range', () {
      final result = ScreenTimeResult.tryParse(
        '{"error":null,"start":"2026-08-23T00:00:00","end":"2026-08-23T23:59:59",'
        '"total_minutes":95,"apps":['
        '{"app_name":"YouTube","total_ms":3600000,"total_minutes":60},'
        '{"package":"com.wechat","app_name":"WeChat","total_ms":2100000,"total_minutes":35}'
        ']}',
      );

      expect(result, isNotNull);
      expect(result!.totalMinutes, 95);
      expect(result.hasApps, isTrue);
      expect(result.isNoPermission, isFalse);
      expect(result.apps, hasLength(2));
      expect(result.apps.first.name, 'YouTube');
      expect(result.apps.first.totalMinutes, 60);
      expect(result.apps.last.name, 'WeChat');
      expect(result.start, '2026-08-23T00:00:00');
    });

    test('detects the NO_PERMISSION payload', () {
      final result = ScreenTimeResult.tryParse(
        '{"error":"NO_PERMISSION","message":"open settings"}',
      );

      expect(result, isNotNull);
      expect(result!.isNoPermission, isTrue);
      expect(result.hasApps, isFalse);
    });

    test('returns null for empty or non-JSON content', () {
      expect(ScreenTimeResult.tryParse(null), isNull);
      expect(ScreenTimeResult.tryParse(''), isNull);
      expect(ScreenTimeResult.tryParse('   '), isNull);
      expect(ScreenTimeResult.tryParse('not json'), isNull);
      expect(ScreenTimeResult.tryParse('[1,2,3]'), isNull);
    });

    test('tolerates garbage entries inside the app list', () {
      final result = ScreenTimeResult.tryParse(
        '{"total_minutes":5,"apps":[null,{"total_ms":60000},{"package":"x"}]}',
      );

      expect(result, isNotNull);
      expect(result!.hasApps, isTrue);
      expect(result.apps, hasLength(1));
      expect(result.apps.single.name, 'x');
      expect(result.apps.single.totalMinutes, 0);
    });

    test(
      'falls back to plain text name when app_name and package are empty',
      () {
        final result = ScreenTimeResult.tryParse('{"apps":[{"total_ms":0}]}');

        expect(result, isNotNull);
        expect(result!.apps, isEmpty);
      },
    );
  });

  group('ScreenTime formatting', () {
    test('formatScreenTimeMinutes', () {
      expect(formatScreenTimeMinutes(0), '0m');
      expect(formatScreenTimeMinutes(59), '59m');
      expect(formatScreenTimeMinutes(60), '1h');
      expect(formatScreenTimeMinutes(95), '1h 35m');
    });

    test('formatScreenTimeRange falls back to the raw value', () {
      expect(formatScreenTimeRange('not a date'), 'not a date');
      final formatted = formatScreenTimeRange('2026-08-23T13:04:00Z');
      expect(formatted, matches(RegExp(r'^\d{2}-\d{2} \d{2}:\d{2}$')));
    });
  });
}
