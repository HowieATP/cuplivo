import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/model_provider.dart';

void main() {
  group('ModelRegistry.infer — Qwen 3.x vision detection', () {
    test('qwen3.5-plus has vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'qwen3.5-plus', displayName: 'qwen3.5-plus'),
      );
      expect(info.input, contains(Modality.image));
    });

    test('qwen3.6-plus has vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'qwen3.6-plus', displayName: 'qwen3.6-plus'),
      );
      expect(info.input, contains(Modality.image));
    });

    test('qwen3.6-flash has vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'qwen3.6-flash', displayName: 'qwen3.6-flash'),
      );
      expect(info.input, contains(Modality.image));
    });

    test('qwen3.6-35b-a3b has vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'qwen3.6-35b-a3b', displayName: 'qwen3.6-35b-a3b'),
      );
      expect(info.input, contains(Modality.image));
    });

    test('qwen3.7-max does NOT have vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'qwen3.7-max', displayName: 'qwen3.7-max'),
      );
      expect(info.input, isNot(contains(Modality.image)));
    });

    test('qwen3-plus does NOT have vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'qwen3-plus', displayName: 'qwen3-plus'),
      );
      expect(info.input, isNot(contains(Modality.image)));
    });

    test('qwen3.8-plus has vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'qwen3.8-plus', displayName: 'qwen3.8-plus'),
      );
      expect(info.input, contains(Modality.image));
    });

    test('qwen3.8-flash has vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'qwen3.8-flash', displayName: 'qwen3.8-flash'),
      );
      expect(info.input, contains(Modality.image));
    });

    test('qwen3.8-max has vision (unlike qwen3.7-max)', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'qwen3.8-max', displayName: 'qwen3.8-max'),
      );
      expect(info.input, contains(Modality.image));
    });

    test('qwen3-8b does NOT have vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'Qwen/Qwen3-8B', displayName: 'Qwen/Qwen3-8B'),
      );
      expect(info.input, isNot(contains(Modality.image)));
    });
  });

  group('ModelRegistry.infer — Doubao seed-2 vision/tool/reasoning', () {
    test('doubao-seed-2.0-pro has vision, tool, and reasoning', () {
      final info = ModelRegistry.infer(
        ModelInfo(
          id: 'doubao-seed-2.0-pro',
          displayName: 'doubao-seed-2.0-pro',
        ),
      );
      expect(info.input, contains(Modality.image));
      expect(info.abilities, contains(ModelAbility.tool));
      expect(info.abilities, contains(ModelAbility.reasoning));
    });

    test('doubao-seed-2.1-turbo has vision, tool, and reasoning', () {
      final info = ModelRegistry.infer(
        ModelInfo(
          id: 'doubao-seed-2.1-turbo',
          displayName: 'doubao-seed-2.1-turbo',
        ),
      );
      expect(info.input, contains(Modality.image));
      expect(info.abilities, contains(ModelAbility.tool));
      expect(info.abilities, contains(ModelAbility.reasoning));
    });
  });

  group('ModelRegistry.infer — existing 1.x doubao still works', () {
    test('doubao-pro-1.6 keeps vision, tool, and reasoning', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'doubao-pro-1.6', displayName: 'doubao-pro-1.6'),
      );
      expect(info.input, contains(Modality.image));
      expect(info.abilities, contains(ModelAbility.tool));
      expect(info.abilities, contains(ModelAbility.reasoning));
    });

    test('doubao-seed-1.8 keeps vision, tool, and reasoning', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'doubao-seed-1.8', displayName: 'doubao-seed-1.8'),
      );
      expect(info.input, contains(Modality.image));
      expect(info.abilities, contains(ModelAbility.tool));
      expect(info.abilities, contains(ModelAbility.reasoning));
    });
  });

  group('ModelRegistry.infer — Muse family vision/tool/reasoning', () {
    test('muse-spark base has vision, tool, and reasoning', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'muse-spark', displayName: 'muse-spark'),
      );
      expect(info.input, contains(Modality.image));
      expect(info.abilities, contains(ModelAbility.tool));
      expect(info.abilities, contains(ModelAbility.reasoning));
    });

    test('muse-spark-1.2 has vision, tool, and reasoning', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'muse-spark-1.2', displayName: 'muse-spark-1.2'),
      );
      expect(info.input, contains(Modality.image));
      expect(info.abilities, contains(ModelAbility.tool));
      expect(info.abilities, contains(ModelAbility.reasoning));
    });

    test('muse-glimmer-30b has vision, tool, and reasoning', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'muse-glimmer-30b', displayName: 'muse-glimmer-30b'),
      );
      expect(info.input, contains(Modality.image));
      expect(info.abilities, contains(ModelAbility.tool));
      expect(info.abilities, contains(ModelAbility.reasoning));
    });

    test('provider-prefixed muse models keep vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(
          id: 'meta/muse-glimmer-30b',
          displayName: 'meta/muse-glimmer-30b',
        ),
      );
      expect(info.input, contains(Modality.image));
    });

    test('muse-spark-2.0 does NOT have vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'muse-spark-2.0', displayName: 'muse-spark-2.0'),
      );
      expect(info.input, isNot(contains(Modality.image)));
    });
  });

  group('ModelRegistry.infer — DeepSeek v4 vision variants', () {
    test('deepseek-v4-flash-vision has vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(
          id: 'deepseek-v4-flash-vision',
          displayName: 'deepseek-v4-flash-vision',
        ),
      );
      expect(info.input, contains(Modality.image));
    });

    test('deepseek-v4-flash-vision-exp has vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(
          id: 'deepseek-v4-flash-vision-exp',
          displayName: 'deepseek-v4-flash-vision-exp',
        ),
      );
      expect(info.input, contains(Modality.image));
    });

    test('deepseek-v4-flash does NOT have vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'deepseek-v4-flash', displayName: 'deepseek-v4-flash'),
      );
      expect(info.input, isNot(contains(Modality.image)));
    });
  });

  group('ModelRegistry.infer — Dots3-Note vision', () {
    test('dots3-note has vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'dots3-note', displayName: 'dots3-note'),
      );
      expect(info.input, contains(Modality.image));
    });

    test('dots-3-note has vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'dots-3-note', displayName: 'dots-3-note'),
      );
      expect(info.input, contains(Modality.image));
    });
  });

  group('ModelRegistry.infer — GLM 5.3 capability parity with 5.2', () {
    test('glm-5.3 has tool and reasoning but no vision', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'glm-5.3', displayName: 'glm-5.3'),
      );
      expect(info.input, isNot(contains(Modality.image)));
      expect(info.output, const [Modality.text]);
      expect(
        info.abilities,
        containsAll([ModelAbility.tool, ModelAbility.reasoning]),
      );
    });
  });

  group('ModelRegistry.infer — Grok 4.6 / Gemini 3.7 Flash parity', () {
    test('grok-4.6 has vision, tool, and reasoning like grok-4.5', () {
      final info = ModelRegistry.infer(
        ModelInfo(id: 'grok-4.6', displayName: 'grok-4.6'),
      );
      expect(info.input, contains(Modality.image));
      expect(info.abilities, contains(ModelAbility.tool));
      expect(info.abilities, contains(ModelAbility.reasoning));
    });

    test(
      'gemini-3.7-flash has vision, tool, and reasoning like gemini-3.6',
      () {
        final info = ModelRegistry.infer(
          ModelInfo(id: 'gemini-3.7-flash', displayName: 'gemini-3.7-flash'),
        );
        expect(info.input, contains(Modality.image));
        expect(info.abilities, contains(ModelAbility.tool));
        expect(info.abilities, contains(ModelAbility.reasoning));
      },
    );
  });
}
