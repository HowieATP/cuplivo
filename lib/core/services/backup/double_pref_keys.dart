import 'package:shared_preferences/shared_preferences.dart';

import '../../database/business_preferences.dart';

/// Pref keys that must always be persisted as `double`.
///
/// Mirrors kelivo-helper's `DOUBLE_KEYS`: a RikkaHub backup migrated by
/// kelivo-helper may carry these as `int` (e.g. `tts_speech_rate_v1: 1`),
/// which crashes `SharedPreferences.getDouble`. When adding or removing keys
/// here, apply the identical change to kelivo-helper's `DOUBLE_KEYS`.
const List<String> doublePrefKeys = <String>[
  'tts_speech_rate_v1',
  'tts_pitch_v1',
  'display_chat_background_mask_strength_v1',
  'display_chat_input_background_opacity_light_v1',
  'display_chat_input_background_opacity_dark_v1',
  'desktop_sidebar_width_v1',
  'desktop_right_sidebar_width_v1',
];

/// Reads a double pref tolerantly: kelivo-helper-migrated RikkaHub backups
/// may inject these keys as `int`, which would make `getDouble` throw.
double prefDouble(SharedPreferences prefs, String key, double fallback) {
  final v = prefs.get(key);
  if (v is num) return v.toDouble();
  return fallback;
}

/// Same tolerant read over the business facade (SQLite KV, no int/double
/// platform coercion — `getDouble` already coerces int storage).
double businessPrefDouble(
  BusinessPreferences prefs,
  String key,
  double fallback,
) {
  final v = prefs.getDouble(key);
  if (v != null) return v;
  return fallback;
}
