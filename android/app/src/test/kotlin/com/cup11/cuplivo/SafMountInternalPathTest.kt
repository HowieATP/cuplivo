package com.cup11.cuplivo

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression coverage for issue #528: the SAF mount mirror lives under the
 * Flutter DOCUMENTS directory (`getDir("flutter")` -> `/data/user/0/<pkg>/
 * app_flutter`), which is a sibling of `filesDir`. The old whitelist only
 * accepted paths inside `filesDir`, so every `copyToPath` / `copyFromPath`
 * call was rejected with bad_args and no file ever synced.
 *
 * These tests pin the corrected whitelist against the path_provider layout.
 */
class SafMountInternalPathTest {

  // Simulated Android internal-storage layout for one package.
  private val dataRoot = "/data/user/0/com.cup11.cuplivo"
  private val filesDir = "$dataRoot/files"
  private val appFlutterDir = "$dataRoot/app_flutter"
  private val cacheDir = "$dataRoot/cache"

  private fun pluginRoots(): List<File> =
    listOf(File(filesDir), File(appFlutterDir), File(cacheDir))

  private fun allowed(path: String): Boolean =
    SafMountPlugin.isInsideInternalRoots(File(path).canonicalFile, pluginRoots())

  @Test
  fun acceptsMirrorFileUnderFlutterDocumentsDirectory() {
    // THE regression: SAF mirrors live at <documents>/saf_mounts/<mountId>/…
    // where <documents> == getDir("flutter"), NOT filesDir.
    assertTrue(
      allowed("$appFlutterDir/saf_mounts/9f1c2c3e-1111-4aaa-9bbb-2c2c2c2c2c2c/docs/a.txt"),
    )
  }

  @Test
  fun acceptsCopyTempUnderSafStateDirectory() {
    assertTrue(
      allowed("$appFlutterDir/saf_mounts/.state/mount-id_copy_tmp"),
    )
  }

  @Test
  fun acceptsFilesInsideFilesDirectory() {
    assertTrue(allowed("$filesDir/proot/bin/proot"))
    assertTrue(allowed("$filesDir/some_plugin_store/data.json"))
  }

  @Test
  fun acceptsFilesInsideCacheDirectory() {
    assertTrue(allowed("$cacheDir/saf_copy_scratch/part.bin"))
  }

  @Test
  fun rejectsSharedStoragePaths() {
    assertFalse(allowed("/storage/emulated/0/Documents/a.txt"))
    assertFalse(allowed("/sdcard/Download/x.bin"))
  }

  @Test
  fun rejectsSiblingAppDirectories() {
    assertFalse(allowed("/data/user/0/com.other.app/files/data.db"))
    assertFalse(allowed("/data/user/0/com.other.app/app_flutter/saf_mounts/x/f"))
  }

  @Test
  fun rejectsParentDirectoriesAndForeignRoots() {
    assertFalse(allowed("$dataRoot/shared_prefs/settings.xml"))
    assertFalse(allowed("/etc/passwd"))
  }

  @Test
  fun rejectsTraversalResolvedOutsideTheRoots() {
    // parseInternalFile canonicalizes before checking; a ".."-spelled path
    // that escapes every root must be rejected after resolution.
    val escaped = File("$filesDir/../../com.other/files/leak.txt").canonicalFile
    assertFalse(SafMountPlugin.isInsideInternalRoots(escaped, pluginRoots()))
  }

  @Test
  fun rejectsTheRootDirectoriesThemselves() {
    // Only strict containment counts: streaming a directory itself is not a
    // valid operation and a bare root must never pass.
    assertFalse(SafMountPlugin.isInsideInternalRoots(File(filesDir), pluginRoots()))
    assertFalse(
      SafMountPlugin.isInsideInternalRoots(File(appFlutterDir), pluginRoots()),
    )
    assertFalse(
      SafMountPlugin.isInsideInternalRoots(File(cacheDir), pluginRoots()),
    )
  }
}
