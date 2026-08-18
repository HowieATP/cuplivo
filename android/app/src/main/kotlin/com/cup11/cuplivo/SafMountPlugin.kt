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
      val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
      try {
        appContext.contentResolver.takePersistableUriPermission(uri, flags)
      } catch (e: Exception) {
        // Some providers refuse persistable grants; the mount still works
        // for this session but will not survive a restart.
        android.util.Log.w(TAG, "takePersistableUriPermission failed: ${e.message}")
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
      "readFile" -> {
        val uri = parseUri(call, "uri", result) ?: return
        runBackground(result) { readFile(uri) }
      }
      "writeFile" -> {
        val uri = parseUri(call, "uri", result) ?: return
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
          result.error("bad_args", "bytes required", null)
          return
        }
        runBackground(result) { writeFile(uri, bytes) }
      }
      "createFile" -> {
        val parent = parseUri(call, "parentUri", result) ?: return
        val name = call.argument<String>("name")?.trim().orEmpty()
        if (name.isEmpty()) {
          result.error("bad_args", "name required", null)
          return
        }
        runBackground(result) { createFile(parent, name) }
      }
      "mkdir" -> {
        val parent = parseUri(call, "parentUri", result) ?: return
        val name = call.argument<String>("name")?.trim().orEmpty()
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

  private fun readFile(uri: Uri): ByteArray {
    val input = appContext.contentResolver.openInputStream(uri)
      ?: throw FileNotFoundException("Cannot open: $uri")
    return input.use { it.readBytes() }
  }

  private fun writeFile(uri: Uri, bytes: ByteArray) {
    // "rwt": read, write, truncate — overwrite in place without recreating
    // the document (keeps its identity and mtime behavior provider-side).
    val pfd = appContext.contentResolver.openFileDescriptor(uri, "rwt")
      ?: throw FileNotFoundException("Cannot open for write: $uri")
    pfd.use { descriptor ->
      FileOutputStream(descriptor.fileDescriptor).use { it.write(bytes) }
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
