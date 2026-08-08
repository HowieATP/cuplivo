import 'package:Cuplivo/core/providers/update_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the expected iOS release asset naming (arm64 device + x86_64 sim).
Map<String, dynamic> _releaseWithSplitIpas() {
  return {
    'tag_name': 'v2.6.3',
    'published_at': '2026-08-08T00:00:00Z',
    'body': 'notes',
    'assets': [
      {
        'name': 'Cuplivo_ios_2.6.3+29_arm64.ipa',
        'browser_download_url':
            'https://example.com/Cuplivo_ios_2.6.3+29_arm64.ipa',
      },
      {
        'name': 'Cuplivo_ios_2.6.3+29_x86_64.ipa',
        'browser_download_url':
            'https://example.com/Cuplivo_ios_2.6.3+29_x86_64.ipa',
      },
    ],
  };
}

void main() {
  group('parseIosIpaArch', () {
    test('extracts known arch tags from ipa asset names', () {
      expect(parseIosIpaArch('Cuplivo_ios_2.6.3+29_arm64.ipa'), 'arm64');
      expect(parseIosIpaArch('Cuplivo_ios_2.6.3+29_x86_64.ipa'), 'x86_64');
    });

    test('returns null when no arch tag is present', () {
      expect(parseIosIpaArch('Cuplivo_ios_2.6.3+29.ipa'), isNull);
      expect(parseIosIpaArch('Cuplivo_android_2.6.3.apk'), isNull);
    });
  });

  group('selectIosDownloadUrl', () {
    const byArch = {
      'arm64': 'https://example.com/arm64.ipa',
      'x86_64': 'https://example.com/x86_64.ipa',
    };

    test('prefers the device arch', () {
      expect(
        selectIosDownloadUrl(ipaByArch: byArch, deviceArch: 'arm64'),
        'https://example.com/arm64.ipa',
      );
      expect(
        selectIosDownloadUrl(ipaByArch: byArch, deviceArch: 'x86_64'),
        'https://example.com/x86_64.ipa',
      );
    });

    test('falls back to arm64 when device arch is unknown', () {
      expect(
        selectIosDownloadUrl(ipaByArch: byArch),
        'https://example.com/arm64.ipa',
      );
    });

    test('uses universal ipa when no arch-tagged ipas match', () {
      expect(
        selectIosDownloadUrl(
          ipaByArch: const {},
          universalUrl: 'https://example.com/universal.ipa',
        ),
        'https://example.com/universal.ipa',
      );
    });
  });

  group('UpdateInfo.fromGithubRelease ios ipa selection', () {
    test('arm64 device picks the arm64 ipa', () {
      final info = UpdateInfo.fromGithubRelease(
        _releaseWithSplitIpas(),
        iosArch: 'arm64',
      );
      expect(info.downloads['ios'], contains('arm64.ipa'));
      expect(info.version, '2.6.3');
    });

    test('x86_64 simulator picks the x86_64 ipa', () {
      final info = UpdateInfo.fromGithubRelease(
        _releaseWithSplitIpas(),
        iosArch: 'x86_64',
      );
      expect(info.downloads['ios'], contains('x86_64.ipa'));
    });

    test('unknown arch falls back to arm64 (not last-wins x86_64)', () {
      final info = UpdateInfo.fromGithubRelease(_releaseWithSplitIpas());
      expect(info.downloads['ios'], contains('arm64.ipa'));
    });

    test('untagged ipa is selected when no arch tags present', () {
      final info = UpdateInfo.fromGithubRelease({
        'tag_name': 'v1.0.0',
        'assets': [
          {
            'name': 'Cuplivo_ios_1.0.0.ipa',
            'browser_download_url': 'https://example.com/universal.ipa',
          },
        ],
      });
      expect(info.downloads['ios'], 'https://example.com/universal.ipa');
    });

    test('empty assets leaves ios download unset', () {
      final info = UpdateInfo.fromGithubRelease({
        'tag_name': 'v1.0.0',
        'assets': <Map<String, dynamic>>[],
      });
      expect(info.downloads.containsKey('ios'), isFalse);
    });
  });
}
