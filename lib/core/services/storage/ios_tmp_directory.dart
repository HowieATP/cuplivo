import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Resolves the real iOS app temp directory (`<container>/tmp`).
///
/// path_provider's `getTemporaryDirectory()` returns the Caches directory on
/// iOS (NSCachesDirectory — the same directory as
/// `getApplicationCacheDirectory()`), so the real tmp dir is unreachable from
/// Dart without the platform channel. Several writers copy files into it and
/// never clean up — the paste-image channel (`pasted_*.png`), file_picker
/// (imported file copies and .m4a recordings), image_cropper (crop output),
/// image_picker_ios (camera/gallery copies). This is the main growing gap
/// between the in-app storage number and the iOS Settings number.
abstract final class IosTmpDirectory {
  IosTmpDirectory._();

  static const MethodChannel _channel = MethodChannel('app.ios_tmp_directory');

  /// Returns the real iOS tmp directory path, or null when unavailable
  /// (non-iOS platform, or the channel failed). Null means "no tmp dir to
  /// scan or clear".
  static Future<String?> getPath() async {
    try {
      final path = await _channel.invokeMethod<String>('getPath');
      if (path == null || path.isEmpty) return null;
      return path;
    } on MissingPluginException {
      // Channel only exists on iOS. Expected on other platforms, not an error.
      return null;
    } on PlatformException catch (e) {
      debugPrint('[IosTmpDirectory] channel failed: $e');
      return null;
    }
  }
}
