import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/providers/grok_device_code_controller.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';

ProviderConfig _cfg({
  String id = 'Grok',
  String baseUrl = 'https://api.x.ai/v1',
  ProviderKind? providerType,
}) {
  return ProviderConfig(
    id: id,
    enabled: true,
    name: id,
    apiKey: 'sk-test',
    baseUrl: baseUrl,
    providerType: providerType ?? ProviderKind.openai,
  );
}

void main() {
  late GrokDeviceCodeController controller;

  setUp(() {
    controller = GrokDeviceCodeController();
    GrokDeviceCodeController.debugOverrideInstance(controller);
  });

  tearDown(() {
    controller.resetForTest();
    GrokDeviceCodeController.debugOverrideInstance(GrokDeviceCodeController());
  });

  group('isGrokHost / showEntryFor', () {
    test('matches api.x.ai, x.ai, and *.x.ai hosts', () {
      expect(GrokDeviceCodeController.isGrokHost(_cfg()), isTrue);
      expect(
        GrokDeviceCodeController.isGrokHost(_cfg(baseUrl: 'https://x.ai/v1')),
        isTrue,
      );
      expect(
        GrokDeviceCodeController.isGrokHost(
          _cfg(baseUrl: 'https://proxy.x.ai/v1'),
        ),
        isTrue,
      );
      expect(
        GrokDeviceCodeController.isGrokHost(
          _cfg(baseUrl: 'https://api.openai.com/v1'),
        ),
        isFalse,
      );
    });

    test('showEntryFor requires openai kind and Grok id or host', () {
      expect(GrokDeviceCodeController.showEntryFor(_cfg()), isTrue);
      expect(
        GrokDeviceCodeController.showEntryFor(
          _cfg(id: 'Custom', baseUrl: 'https://api.x.ai/v1'),
        ),
        isTrue,
      );
      expect(
        GrokDeviceCodeController.showEntryFor(
          _cfg(id: 'OpenAI', baseUrl: 'https://api.openai.com/v1'),
        ),
        isFalse,
      );
      expect(
        GrokDeviceCodeController.showEntryFor(
          _cfg(providerType: ProviderKind.claude),
        ),
        isFalse,
      );
    });
  });

  group('dual-mode headers and ensureFresh', () {
    test('maybeGrokHeaders empty without credential (API key path)', () {
      expect(controller.maybeGrokHeaders(_cfg()), isEmpty);
    });

    test('maybeGrokHeaders emits bearer while credential exists', () {
      controller.credential = GrokOAuthCredential(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
      final h = controller.maybeGrokHeaders(_cfg());
      expect(h['Authorization'], 'Bearer access-token');
    });

    test(
      'maybeGrokHeaders still emits when stale (no silent API-key fallback)',
      () {
        controller.credential = GrokOAuthCredential(
          accessToken: 'stale-token',
          refreshToken: 'refresh-token',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        );
        final h = controller.maybeGrokHeaders(_cfg());
        expect(h['Authorization'], 'Bearer stale-token');
      },
    );

    test('ensureFreshOrThrow is no-op without credential', () async {
      await GrokDeviceCodeController.ensureFreshOrThrow(_cfg());
    });

    test('ensureFreshOrThrow no-op on non-grok host', () async {
      controller.credential = GrokOAuthCredential(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      await GrokDeviceCodeController.ensureFreshOrThrow(
        _cfg(baseUrl: 'https://api.openai.com/v1'),
      );
    });

    test('isFresh / isUsable grace window', () {
      controller.credential = GrokOAuthCredential(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(controller.isUsable, isTrue);
      expect(controller.isFresh, isFalse);
    });
  });
}
