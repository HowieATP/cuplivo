import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/model/utils/ocr_model_capability.dart';

Future<void> _waitForSettingsLoad() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

ProviderConfig _configWithOcrCandidates() {
  return ProviderConfig(
    id: 'OcrProvider',
    enabled: true,
    name: 'OCR Provider',
    apiKey: 'test-key',
    baseUrl: 'https://example.test',
    models: const [
      'vision-model',
      'text-model',
      'gpt-4.1',
      'gpt-4.1-text-only',
    ],
    modelOverrides: const {
      'vision-model': {
        'name': 'Vision Model',
        'input': ['text', 'image'],
      },
      'text-model': {
        'name': 'Text Model',
        'input': ['text'],
      },
      'gpt-4.1-text-only': {
        'apiModelId': 'gpt-4.1',
        'input': ['text'],
      },
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('modelSupportsOcrImageInput', () {
    test('accepts models tagged with image input', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();
      await settings.setProviderConfig(
        'OcrProvider',
        _configWithOcrCandidates(),
      );

      expect(
        modelSupportsOcrImageInput(settings, 'OcrProvider', 'vision-model'),
        isTrue,
      );
    });

    test('rejects models tagged as text-only', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();
      await settings.setProviderConfig(
        'OcrProvider',
        _configWithOcrCandidates(),
      );

      expect(
        modelSupportsOcrImageInput(settings, 'OcrProvider', 'text-model'),
        isFalse,
      );
    });

    test('accepts models whose current inferred tag has image input', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();
      await settings.setProviderConfig(
        'OcrProvider',
        _configWithOcrCandidates(),
      );

      expect(
        modelSupportsOcrImageInput(settings, 'OcrProvider', 'gpt-4.1'),
        isTrue,
      );
    });

    test('honors text-only tag overrides over inferred vision tags', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();

      await _waitForSettingsLoad();
      await settings.setProviderConfig(
        'OcrProvider',
        _configWithOcrCandidates(),
      );

      expect(
        modelSupportsOcrImageInput(
          settings,
          'OcrProvider',
          'gpt-4.1-text-only',
        ),
        isFalse,
      );
    });
  });

  group('resolveOcrActive', () {
    Future<SettingsProvider> newSettings({required bool withOcrModel}) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitForSettingsLoad();
      await settings.setProviderConfig(
        'OcrProvider',
        _configWithOcrCandidates(),
      );
      if (withOcrModel) {
        await settings.setOcrModel('OcrProvider', 'vision-model');
      }
      return settings;
    }

    Future<bool> resolve({
      required bool withOcrModel,
      String? ocrMode,
      required String modelId,
    }) async {
      final settings = await newSettings(withOcrModel: withOcrModel);
      final assistant = ocrMode == null
          ? null
          : Assistant(id: 'a1', name: 'A', ocrMode: ocrMode);
      return resolveOcrActive(
        settings: settings,
        assistant: assistant,
        providerKey: 'OcrProvider',
        modelId: modelId,
      );
    }

    test('never is false even with an OCR model for any model', () async {
      expect(
        await resolve(
          withOcrModel: true,
          ocrMode: 'never',
          modelId: 'text-model',
        ),
        isFalse,
      );
      expect(
        await resolve(
          withOcrModel: true,
          ocrMode: 'never',
          modelId: 'vision-model',
        ),
        isFalse,
      );
    });

    test(
      'always is true for vision and text models when OCR model set',
      () async {
        expect(
          await resolve(
            withOcrModel: true,
            ocrMode: 'always',
            modelId: 'vision-model',
          ),
          isTrue,
        );
        expect(
          await resolve(
            withOcrModel: true,
            ocrMode: 'always',
            modelId: 'text-model',
          ),
          isTrue,
        );
      },
    );

    test('always without an OCR model is false', () async {
      expect(
        await resolve(
          withOcrModel: false,
          ocrMode: 'always',
          modelId: 'text-model',
        ),
        isFalse,
      );
    });

    test('auto OCRs only when the model lacks vision input', () async {
      expect(
        await resolve(
          withOcrModel: true,
          ocrMode: 'auto',
          modelId: 'vision-model',
        ),
        isFalse,
      );
      expect(
        await resolve(
          withOcrModel: true,
          ocrMode: 'auto',
          modelId: 'text-model',
        ),
        isTrue,
      );
    });

    test(
      'auto without an OCR model is false even for text-only models',
      () async {
        expect(
          await resolve(
            withOcrModel: false,
            ocrMode: 'auto',
            modelId: 'text-model',
          ),
          isFalse,
        );
      },
    );

    test('missing assistant falls back to auto mode', () async {
      expect(
        await resolve(withOcrModel: true, modelId: 'vision-model'),
        isFalse,
      );
      expect(await resolve(withOcrModel: true, modelId: 'text-model'), isTrue);
    });
  });
}
