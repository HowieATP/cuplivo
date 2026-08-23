package com.cup11.cuplivo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream

/**
 * Android SAF (Storage Access Framework) bridge for external-directory
 * mounts (ADR-0037).
 *
 * The user picks a directory via ACTION_OPEN_DOCUMENT_TREE; the grant is
 * persisted with takePersistableUriPermission. All IO goes through
 * ContentResolver / DocumentFile — content URIs never expose a host path.
 * The Dart side keeps a mirror directory in two-way sync.
 */
class SafMountPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

  private lateinit var channel: MethodChannel
  private lateinit var appContext: Context
  private var activity: Activity? = null
  private val mainHandler = Handler(Looper.getMainLooper())

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    channel = MethodChannel(
      binding.binaryMessenger,
      "cuplivo/saf_mount",
      StandardMethodCodec.INSTANCE,
    )
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    // The engine is being torn down mid-pick (process death / engine
    // recreation while the system picker is open): fail the outstanding
    // Dart future instead of letting it hang forever. The picker itself is
    // not timeout-wrapped by design (it is interactive).
    val pending = sharedPendingPickResult
    if (pending != null) {
      sharedPendingPickResult = null
      mainHandler.post {
        pending.error("engine_detached", "SAF picker cancelled by engine teardown", null)
      }
    }
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    binding.addActivityResultListener(activityResultListener)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
    activity = null
  }

  private val activityResultListener =
    PluginRegistry.ActivityResultListener { requestCode: Int, resultCode: Int, data: Intent? ->
      if (requestCode != PICK_TREE_REQUEST_CODE) return@ActivityResultListener false
      val pending = sharedPendingPickResult
      if (pending == null) return@ActivityResultListener true
      sharedPendingPickResult = null
      if (resultCode != Activity.RESULT_OK || data?.data == null) {
        mainHandler.post { pending.success(null) }
        return@ActivityResultListener true
      }
      val uri = data.data!!
      val requiredFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
      val grantedFlags = data.flags and requiredFlags
      if (grantedFlags != requiredFlags) {
        mainHandler.post {
          pending.error(
            "access_denied",
            "The selected directory did not grant persistent read/write access",
            null,
          )
        }
        return@ActivityResultListener true
      }
      try {
        appContext.contentResolver.takePersistableUriPermission(uri, grantedFlags)
      } catch (e: Exception) {
        android.util.Log.w(TAG, "takePersistableUriPermission failed: ${e.message}")
        mainHandler.post {
          pending.error(
            "access_denied",
            "The selected directory cannot grant persistent read/write access",
            null,
          )
        }
        return@ActivityResultListener true
      }
      val doc = DocumentFile.fromTreeUri(appContext, uri)
      val displayName = doc?.name?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment.orEmpty()
      mainHandler.post {
        pending.success(mapOf("uri" to uri.toString(), "displayName" to displayName))
      }
      true
    }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "pickTree" -> pickTree(result)
      "list" -> {
        val uri = parseUri(call, "uri", result) ?: return
        runBackground(result) { list(uri) }
      }
      "copyToPath" -> {
        val uri = parseUri(call, "uri", result) ?: return
        val target = parseInternalFile(call, "targetPath", result) ?: return
        runBackground(result) { copyToPath(uri, target) }
      }
      "copyFromPath" -> {
        val uri = parseUri(call, "uri", result) ?: return
        val source = parseInternalFile(call, "sourcePath", result) ?: return
        runBackground(result) { copyFromPath(uri, source) }
      }
      "createFile" -> {
        val parent = parseUri(call, "parentUri", result) ?: return
        val name = call.argument<String>("name").orEmpty()
        if (name.isEmpty()) {
          result.error("bad_args", "name required", null)
          return
        }
        runBackground(result) { createFile(parent, name) }
      }
      "mkdir" -> {
        val parent = parseUri(call, "parentUri", result) ?: return
        val name = call.argument<String>("name").orEmpty()
        if (name.isEmpty()) {
          result.error("bad_args", "name required", null)
          return
        }
        runBackground(result) { mkdir(parent, name) }
      }
      "delete" -> {
        val uri = parseUri(call, "uri", result) ?: return
        runBackground(result) { delete(uri) }
      }
      "checkAccess" -> {
        val uri = parseUri(call, "uri", result) ?: return
        runBackground(result) { checkAccess(uri) }
      }
      else -> result.notImplemented()
    }
  }

  private fun pickTree(result: MethodChannel.Result) {
    val act = activity
    if (act == null) {
      result.error("no_activity", "Activity not attached", null)
      return
    }
    if (sharedPendingPickResult != null) {
      result.error("busy", "Another SAF pick is in progress", null)
      return
    }
    sharedPendingPickResult = result
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
      addFlags(
        Intent.FLAG_GRANT_READ_URI_PERMISSION or
          Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
          Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
          Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
      )
    }
    try {
      act.startActivityForResult(intent, PICK_TREE_REQUEST_CODE)
    } catch (e: ActivityNotFoundException) {
      sharedPendingPickResult = null
      result.error("launch_failed", e.message, null)
    }
  }

  // ------------------------------------------------------------------
  // Background IO
  // ------------------------------------------------------------------

  private fun runBackground(result: MethodChannel.Result, block: () -> Any?) {
    Thread {
      try {
        val value = block()
        mainHandler.post { result.success(value) }
      } catch (e: SecurityException) {
        mainHandler.post { result.error("access_denied", e.message, null) }
      } catch (e: FileNotFoundException) {
        mainHandler.post { result.error("uri_not_found", e.message, null) }
      } catch (e: Exception) {
        mainHandler.post { result.error("access_failed", e.message ?: e.javaClass.simpleName, null) }
      }
    }.start()
  }

  private fun parseUri(
    call: MethodCall,
    key: String,
    result: MethodChannel.Result,
  ): Uri? {
    val raw = call.argument<String>(key)?.trim().orEmpty()
    val uri = Uri.parse(raw)
    if (raw.isEmpty() || uri.scheme != "content") {
      result.error("bad_args", "$key must be a content URI", null)
      return null
    }
    return uri
  }

  /**
   * Canonical roots of the app-private internal storage that the Dart side
   * may legitimately stream files through (path_provider layout on Android):
   *
   * - [Context.filesDir]            -> /data/user/0/<pkg>/files
   *   (`getApplicationSupportDirectory`, databases, plugin stores)
   * - [Context.getDir]("flutter")   -> /data/user/0/<pkg>/app_flutter
   *   (`getApplicationDocumentsDirectory`: SAF mirrors, uploads, images, …)
   * - [Context.cacheDir]            -> /data/user/0/<pkg>/cache
   *   (transient scratch)
   *
   * The SAF mirror lives under the DOCUMENTS directory (`app_flutter/
   * saf_mounts/`), which is a SIBLING of filesDir — NOT inside it. A
   * whitelist of filesDir alone rejects every mirror/temp path with
   * bad_args, so no file is ever copied in either direction (issue #528:
   * partial enumeration, zero-file sync, "sync failed — will retry").
   */
  private fun internalRoots(): List<File> = listOf(
    appContext.filesDir,
    appContext.getDir("flutter", Context.MODE_PRIVATE),
    appContext.cacheDir,
  ).map { it.canonicalFile }

  private fun parseInternalFile(
    call: MethodCall,
    key: String,
    result: MethodChannel.Result,
  ): File? {
    val raw = call.argument<String>(key).orEmpty()
    if (raw.isBlank()) {
      result.error("bad_args", "$key required", null)
      return null
    }
    return try {
      val file = File(raw).canonicalFile
      // A path exactly equal to one of the roots has nothing to stream;
      // require it to be strictly INSIDE a root so ".."-spelled roots and
      // the root directories themselves are rejected.
      if (!isInsideInternalRoots(file, internalRoots())) {
        android.util.Log.w(
          TAG,
          "Rejected $key outside app-internal storage: ${file.path}",
        )
        result.error("bad_args", "$key must stay inside app storage", null)
        null
      } else {
        file
      }
    } catch (e: Exception) {
      result.error("bad_args", "$key could not be resolved: ${e.message}", null)
      null
    }
  }

  private fun list(uri: Uri): List<Map<String, Any?>> {
    val doc = DocumentFile.fromTreeUri(appContext, uri)
      ?: throw FileNotFoundException("Cannot resolve tree: $uri")
    return doc.listFiles().map { child ->
      mapOf(
        "name" to (child.name ?: ""),
        "isDirectory" to child.isDirectory,
        "lastModified" to child.lastModified(),
        "size" to child.length(),
        "uri" to child.uri.toString(),
      )
    }
  }

  private fun copyToPath(uri: Uri, target: File) {
    val input = appContext.contentResolver.openInputStream(uri)
      ?: throw FileNotFoundException("Cannot open: $uri")
    target.parentFile?.mkdirs()
    input.use { source ->
      FileOutputStream(target).use { destination -> source.copyTo(destination) }
    }
  }

  private fun copyFromPath(uri: Uri, source: File) {
    if (!source.isFile) throw FileNotFoundException("Cannot open: $source")
    // "rwt": read, write, truncate — overwrite in place without recreating
    // the document (keeps its identity and mtime behavior provider-side).
    val pfd = appContext.contentResolver.openFileDescriptor(uri, "rwt")
      ?: throw FileNotFoundException("Cannot open for write: $uri")
    pfd.use { descriptor ->
      FileInputStream(source).use { input ->
        FileOutputStream(descriptor.fileDescriptor).use { output -> input.copyTo(output) }
      }
    }
  }

  private fun createFile(parentUri: Uri, name: String): String {
    val parent = DocumentFile.fromTreeUri(appContext, parentUri)
      ?: throw FileNotFoundException("Cannot resolve parent: $parentUri")
    val mime = mimeForName(name)
    val created = parent.createFile(mime, name)
      ?: throw IllegalStateException("Provider refused createFile($name)")
    return created.uri.toString()
  }

  private fun mkdir(parentUri: Uri, name: String): String {
    val parent = DocumentFile.fromTreeUri(appContext, parentUri)
      ?: throw FileNotFoundException("Cannot resolve parent: $parentUri")
    val created = parent.createDirectory(name)
      ?: throw IllegalStateException("Provider refused createDirectory($name)")
    return created.uri.toString()
  }

  private fun delete(uri: Uri): Boolean {
    val doc = DocumentFile.fromSingleUri(appContext, uri)
      ?: return false
    return doc.delete()
  }

  private fun checkAccess(uri: Uri): Boolean {
    return try {
      val treeId = DocumentsContract.getTreeDocumentId(uri)
      val rootDoc = DocumentsContract.buildDocumentUriUsingTree(uri, treeId)
      val projection = arrayOf(OpenableColumns.DISPLAY_NAME)
      val queried = appContext.contentResolver.query(rootDoc, projection, null, null, null)?.use { cursor ->
        cursor.moveToFirst()
      } ?: false
      if (queried) return true
      // Some providers refuse a DISPLAY_NAME query on the root document yet
      // still grant access — probe with the real operation (a tree listing)
      // so a valid mount is not marked unavailable.
      val doc = DocumentFile.fromTreeUri(appContext, uri) ?: return false
      try {
        doc.listFiles()
        true
      } catch (e: Exception) {
        false
      }
    } catch (e: Exception) {
      false
    }
  }

  private fun mimeForName(name: String): String {
    val ext = name.substringAfterLast('.', "")
    return if (ext.isEmpty()) {
      "application/octet-stream"
    } else {
      MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.lowercase())
        ?: "application/octet-stream"
    }
  }

  companion object {
    private const val TAG = "SafMountPlugin"
    private const val PICK_TREE_REQUEST_CODE = 4201

    /**
     * True when [file] (already canonicalized) sits strictly inside one of
     * [roots] (canonical app-internal directories). Pure so it can be unit
     * tested without an Android context.
     */
    @JvmStatic
    fun isInsideInternalRoots(file: File, roots: List<File>): Boolean {
      return roots.any { root ->
        file.path.startsWith(root.path + File.separator)
      }
    }

    /**
     * The outstanding pickTree result, shared across plugin instances.
     * A pick is a full-screen interactive flow that can outlive the engine
     * that started it (rotation / engine recreation while the system picker
     * is open): a per-instance field would be dropped on recreation and the
     * Dart future would hang forever. The shared holder lets a reattached
     * instance still complete (or fail, on teardown) the original future.
     */
    @Volatile
    var sharedPendingPickResult: MethodChannel.Result? = null
  }
}
