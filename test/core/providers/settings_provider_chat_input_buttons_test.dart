import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults: no customization (sentinel unset)', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsProvider();
    await settings.loaded;

    expect(settings.chatInputButtonOrder, isEmpty);
    expect(settings.chatInputMoreButtonIds, isEmpty);
    expect(settings.chatInputButtonsCustomized, isFalse);
  });

  test('persists order and more ids across loads', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsProvider();
    await settings.loaded;

    await settings.setChatInputButtonOrder(['model', 'camera', 'search']);
    await settings.setChatInputMoreButtonIds(['camera', 'photos']);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('chat_input_buttons_v1'), [
      'model',
      'camera',
      'search',
    ]);
    expect(prefs.getStringList('chat_input_more_buttons_v1'), [
      'camera',
      'photos',
    ]);

    final reloaded = SettingsProvider();
    await reloaded.loaded;
    expect(reloaded.chatInputButtonOrder, ['model', 'camera', 'search']);
    expect(reloaded.chatInputMoreButtonIds, ['camera', 'photos']);
    expect(reloaded.chatInputButtonsCustomized, isTrue);
  });

  test('more ids stay sorted and deduped', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsProvider();
    await settings.loaded;

    await settings.setChatInputMoreButtonIds(['photos', 'camera', 'camera']);

    expect(settings.chatInputMoreButtonIds, ['camera', 'photos']);
    final reloaded = SettingsProvider();
    await reloaded.loaded;
    expect(reloaded.chatInputMoreButtonIds, ['camera', 'photos']);
  });

  test('order dedupes but keeps saved sequence', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsProvider();
    await settings.loaded;

    await settings.setChatInputButtonOrder(['a', 'b', 'a']);

    expect(settings.chatInputButtonOrder, ['a', 'b']);
  });

  test('reset clears both keys and reverts to unset', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsProvider();
    await settings.loaded;

    await settings.setChatInputButtonOrder(['model', 'camera']);
    await settings.setChatInputMoreButtonIds(['camera']);
    await settings.resetChatInputButtons();

    expect(settings.chatInputButtonsCustomized, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('chat_input_buttons_v1'), isNull);
    expect(prefs.getStringList('chat_input_more_buttons_v1'), isNull);
  });

  test('customized flag turns true when only one side is set', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsProvider();
    await settings.loaded;

    await settings.setChatInputMoreButtonIds(['camera']);
    expect(settings.chatInputButtonsCustomized, isTrue);
  });
}
