package com.cup11.cuplivo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.net.Uri
import android.util.Log
import android.view.Display
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private companion object {
        const val CREATE_DOCUMENT_REQUEST_CODE = 4107
        const val DISPLAY_MODE_CHANNEL = "app.display_mode"
        const val DISPLAY_MODE_LOG_TAG = "CuplivoDisplayMode"
    }

    private val processTextChannelName = "app.process_text"
    private val fileSaveChannelName = "app.file_save"
    private var processTextChannel: MethodChannel? = null
    private var fileSaveChannel: MethodChannel? = null
    private var displayModeChannel: MethodChannel? = null
    private var pendingProcessText: String? = null
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSourcePath: String? = null

    /// Last requested high refresh rate preference, re-applied when the
    /// activity resumes or the display configuration changes.
    private var pendingHighRefreshRate: Boolean? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        processTextChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, processTextChannelName)
        processTextChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialText" -> {
                    val text = pendingProcessText ?: extractProcessText(intent)
                    pendingProcessText = null
                    result.success(text)
                }
                else -> result.notImplemented()
            }
        }
        fileSaveChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileSaveChannelName)
        fileSaveChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFileFromPath" -> handleSaveFileFromPath(call.arguments, result)
                else -> result.notImplemented()
            }
        }
        displayModeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DISPLAY_MODE_CHANNEL)
        displayModeChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setHighRefreshRate" -> handleSetHighRefreshRate(call.arguments, result)
                else -> result.notImplemented()
            }
        }
        pendingProcessText = extractProcessText(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extractProcessText(intent) ?: return
        val ch = processTextChannel
        if (ch != null) {
            ch.invokeMethod("onProcessText", text)
        } else {
            pendingProcessText = text
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CREATE_DOCUMENT_REQUEST_CODE) {
            return
        }

        val destUri = if (resultCode == Activity.RESULT_OK) data?.data else null
        handleSaveDestination(destUri)
    }

    override fun onResume() {
        super.onResume()
        pendingHighRefreshRate?.let { enabled ->
            try {
                applyHighRefreshRate(enabled)
            } catch (e: Exception) {
                Log.e(DISPLAY_MODE_LOG_TAG, "Failed to re-apply refresh rate preference on resume", e)
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        pendingHighRefreshRate?.let { enabled ->
            try {
                applyHighRefreshRate(enabled)
            } catch (e: Exception) {
                Log.e(DISPLAY_MODE_LOG_TAG, "Failed to re-apply refresh rate preference on config change", e)
            }
        }
    }

    private fun handleSetHighRefreshRate(arguments: Any?, result: MethodChannel.Result) {
        val enabled = (arguments as? Map<*, *>)?.get("enabled") as? Boolean ?: false
        pendingHighRefreshRate = enabled
        try {
            result.success(applyHighRefreshRate(enabled))
        } catch (e: Exception) {
            Log.e(DISPLAY_MODE_LOG_TAG, "Failed to apply high refresh rate (enabled=$enabled)", e)
            result.error("display_mode_failed", e.message, null)
        }
    }

    /**
     * Requests the mode with the highest refresh rate among the display modes
     * that share the current resolution. Enabling never changes the display
     * resolution. Disabling restores the system default mode
     * (preferredDisplayModeId = 0).
     */
    private fun applyHighRefreshRate(enabled: Boolean): Map<String, Any?> {
        val displayManager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val display = displayManager.getDisplay(Display.DEFAULT_DISPLAY)
            ?: throw IllegalStateException("Default display unavailable")
        val modes = display.supportedModes
        if (modes.isEmpty()) {
            Log.w(DISPLAY_MODE_LOG_TAG, "No supported display modes; cannot honor refresh rate preference")
            return mapOf(
                "supported" to false,
                "enabled" to false,
                "refreshRate" to null,
                "modeId" to null,
            )
        }
        val current = display.mode
        val sameResolution = modes.filter {
            it.physicalWidth == current.physicalWidth &&
                it.physicalHeight == current.physicalHeight
        }
        // Unify the branch types: modes is Array<Display.Mode> while filter
        // returns List<Display.Mode>; a bare if/else would widen to Any and
        // break maxByOrNull resolution.
        val candidates: List<Display.Mode> =
            if (sameResolution.isEmpty()) modes.toList() else sameResolution
        val best = candidates.maxByOrNull { it.refreshRate } ?: modes.first()
        val attributes = window.attributes
        attributes.preferredDisplayModeId = if (enabled) best.modeId else 0
        window.attributes = attributes
        Log.i(
            DISPLAY_MODE_LOG_TAG,
            "Refresh rate preference applied: enabled=$enabled " +
                "modeId=${if (enabled) best.modeId else 0} " +
                "refreshRate=${best.refreshRate}Hz",
        )
        return mapOf(
            "supported" to true,
            "enabled" to enabled,
            "refreshRate" to best.refreshRate.toDouble(),
            "modeId" to best.modeId,
        )
    }

    private fun extractProcessText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_PROCESS_TEXT) return null
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        return text?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun handleSaveFileFromPath(arguments: Any?, result: MethodChannel.Result) {
        if (pendingSaveResult != null) {
            result.error("busy", "Another save operation is already in progress.", null)
            return
        }

        val args = arguments as? Map<*, *>
        val rawSourcePath = args?.get("sourcePath")?.toString()?.trim().orEmpty()
        if (rawSourcePath.isEmpty()) {
            result.error("invalid_args", "Missing sourcePath.", null)
            return
        }

        val sourceFile = File(rawSourcePath)
        if (!sourceFile.exists() || !sourceFile.isFile) {
            result.error("not_found", "Source file does not exist.", null)
            return
        }

        val suggestedFileName = args?.get("fileName")?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
            ?: sourceFile.name

        pendingSaveResult = result
        pendingSaveSourcePath = sourceFile.absolutePath

        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/zip"
                putExtra(Intent.EXTRA_TITLE, suggestedFileName)
            }
            startActivityForResult(intent, CREATE_DOCUMENT_REQUEST_CODE)
        } catch (e: ActivityNotFoundException) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            result.error("launch_failed", e.message, null)
        }
    }

    private fun handleSaveDestination(destUri: Uri?) {
        val result = pendingSaveResult ?: return
        val sourcePath = pendingSaveSourcePath

        if (destUri == null || sourcePath.isNullOrBlank()) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            result.success(false)
            return
        }

        Thread {
            try {
                contentResolver.openOutputStream(destUri)?.use { outputStream ->
                    FileInputStream(File(sourcePath)).use { inputStream ->
                        inputStream.copyTo(outputStream, DEFAULT_BUFFER_SIZE)
                    }
                } ?: throw IllegalStateException("Unable to open destination stream.")

                runOnUiThread {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    result.success(true)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    result.error("save_failed", e.message, null)
                }
            }
        }.start()
    }
}
