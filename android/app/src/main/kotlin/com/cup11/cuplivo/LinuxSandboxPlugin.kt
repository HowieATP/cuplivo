package com.cup11.cuplivo

import android.content.Context
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit
import java.util.zip.ZipFile

/**
 * Android bridge for the Linux sandbox (proot when the native libs ship).
 *
 * Rootfs download and apt orchestration live in Dart; this plugin only
 * extracts the archive and runs commands inside the guest.
 */
class LinuxSandboxPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var appContext: Context

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "cuplivo/linux_sandbox")
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "isSupported" -> {
        Thread {
          val supported = hasProot()
          android.os.Handler(android.os.Looper.getMainLooper()).post {
            result.success(supported)
          }
        }.start()
      }
      "getAbi" -> result.success(primaryAbi())
      "extractRootfs" -> {
        val workspace = call.argument<String>("workspacePath")
        val archivePath = call.argument<String>("archivePath")
        if (workspace.isNullOrBlank() || archivePath.isNullOrBlank()) {
          result.error("bad_args", "workspacePath and archivePath required", null)
          return
        }
        Thread {
          try {
            extractRootfs(workspace, archivePath)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
              result.success(null)
            }
          } catch (e: Exception) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
              result.error(
                "extract_failed",
                e.message ?: e.javaClass.simpleName,
                null,
              )
            }
          }
        }.start()
      }
      // Backward-compatible alias: if callers still pass url, reject clearly.
      "installRootfs" -> {
        val workspace = call.argument<String>("workspacePath")
        val archivePath = call.argument<String>("archivePath")
        val url = call.argument<String>("url")
        if (!archivePath.isNullOrBlank() && !workspace.isNullOrBlank()) {
          Thread {
            try {
              extractRootfs(workspace, archivePath)
              android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.success(null)
              }
            } catch (e: Exception) {
              android.os.Handler(android.os.Looper.getMainLooper()).post {
                result.error(
                  "extract_failed",
                  e.message ?: e.javaClass.simpleName,
                  null,
                )
              }
            }
          }.start()
        } else {
          result.error(
            "bad_args",
            "installRootfs now expects archivePath (download in Dart). url=${url ?: "null"}",
            null,
          )
        }
      }
      "exec" -> {
        val workspace = call.argument<String>("workspacePath")
        val command = call.argument<String>("command")
        val cwd = call.argument<String>("cwd")
        val timeoutMs = (call.argument<Number>("timeoutMs") ?: 30_000).toLong()
        if (workspace.isNullOrBlank() || command.isNullOrBlank()) {
          result.error("bad_args", "workspacePath and command required", null)
          return
        }
        Thread {
          try {
            val map = GuestCommandRunner(appContext).execute(
              workspacePath = workspace,
              command = command,
              cwd = cwd,
              timeoutMs = timeoutMs,
            )
            android.os.Handler(android.os.Looper.getMainLooper()).post {
              result.success(map)
            }
          } catch (e: Exception) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
              result.error("exec_failed", e.message, null)
            }
          }
        }.start()
      }
      else -> result.notImplemented()
    }
  }

  private fun primaryAbi(): String {
    val abis = Build.SUPPORTED_ABIS
    if (abis.isNotEmpty()) {
      val a = abis[0]
      if (a.contains("arm64")) return "arm64-v8a"
      if (a.contains("x86_64") || a.contains("amd64")) return "x86_64"
      return a
    }
    return "arm64-v8a"
  }

  private fun hasProot(): Boolean {
    val exec = NativeLibResolver.resolve(appContext, EXEC_LIB)
    val loader = NativeLibResolver.resolve(appContext, LOADER_LIB)
    val ok = exec != null && loader != null
    if (!ok) {
      Log.w(
        TAG,
        "proot runtime missing: exec=${exec?.absolutePath} loader=${loader?.absolutePath}",
      )
    }
    return ok
  }

  private fun extractRootfs(workspacePath: String, archivePath: String) {
    val archive = File(archivePath)
    if (!archive.exists() || archive.length() == 0L) {
      throw IllegalStateException("archive missing or empty: $archivePath")
    }
    val sandbox = File(workspacePath, ".sandbox")
    val linuxTmp = File(sandbox, "linux.tmp")
    val linux = File(sandbox, "linux")
    sandbox.mkdirs()
    if (linuxTmp.exists()) linuxTmp.deleteRecursively()
    linuxTmp.mkdirs()

    try {
      // Streaming extractor with hardlink→copy fallback (system tar fails on
      // Android with "Permission denied" for Ubuntu base hardlinks).
      RootfsExtractor.extract(archive, linuxTmp)

      val sh = File(linuxTmp, "bin/sh")
      if (!sh.exists()) {
        // Some tarballs nest a single top-level dir
        val children = linuxTmp.listFiles()?.filter { it.isDirectory } ?: emptyList()
        if (children.size == 1 && File(children[0], "bin/sh").exists()) {
          val nested = children[0]
          nested.listFiles()?.forEach { child ->
            val dest = File(linuxTmp, child.name)
            if (!child.renameTo(dest)) {
              child.copyRecursively(dest, overwrite = true)
              child.deleteRecursively()
            }
          }
          nested.deleteRecursively()
        }
      }
      if (!File(linuxTmp, "bin/sh").exists()) {
        throw IllegalStateException("extract produced no bin/sh")
      }
      patchRootfs(linuxTmp)
      if (linux.exists()) linux.deleteRecursively()
      if (!linuxTmp.renameTo(linux)) {
        linuxTmp.copyRecursively(linux, overwrite = true)
        linuxTmp.deleteRecursively()
      }
      File(sandbox, "tmp").mkdirs()
    } catch (e: Exception) {
      try {
        if (linuxTmp.exists()) linuxTmp.deleteRecursively()
      } catch (_: Exception) {
      }
      throw e
    }
  }

  /** Minimal Android-friendly rootfs fixes (DNS / tmp / apt locks). */
  private fun patchRootfs(linuxDir: File) {
    try {
      patchDns(linuxDir)
      ensureGuestDirs(linuxDir)
      writeAptConfig(linuxDir)
    } catch (e: Exception) {
      Log.w(TAG, "patchRootfs: ${e.message}")
    }
  }

  /** Rewrite resolv.conf unless it already points at a usable DNS. */
  private fun patchDns(linuxDir: File) {
    val etc = File(linuxDir, "etc")
    etc.mkdirs()
    val resolv = File(etc, "resolv.conf")
    val body = if (resolv.isFile) resolv.readText() else ""
    val hasNameserver = body.lineSequence().any { it.trimStart().startsWith("nameserver") }
    val pointsAtStub = body.contains("127.0.0.53") || body.contains("systemd")
    if (hasNameserver && !pointsAtStub) return
    resolv.writeText(
      buildString {
        PUBLIC_DNS.forEach { append("nameserver $it\n") }
      },
    )
  }

  private fun ensureGuestDirs(linuxDir: File) {
    listOf("tmp", "var/tmp", "root").forEach { path ->
      File(linuxDir, path).mkdirs()
    }
  }

  /**
   * Make every apt invocation inside the guest wait for a held dpkg/apt lock
   * instead of failing instantly. Covers commands run through the LLM shell
   * tool (which bypasses the Dart-side install queue): a concurrent install
   * just waits, then proceeds.
   */
  private fun writeAptConfig(linuxDir: File) {
    val confDir = File(linuxDir, "etc/apt/apt.conf.d")
    confDir.mkdirs()
    File(confDir, "99cuplivo").writeText(
      "// Cuplivo Linux sandbox: wait for dpkg/apt locks instead of failing.\n" +
        "Acquire::Lock::Timeout \"600\";\n" +
        "Acquire::Retries \"3\";\n",
    )
  }
}

/** Runs one command inside the proot guest and captures capped output. */
private class GuestCommandRunner(private val appContext: Context) {
  fun execute(
    workspacePath: String,
    command: String,
    cwd: String?,
    timeoutMs: Long,
  ): Map<String, Any?> {
    val exec = NativeLibResolver.resolve(appContext, EXEC_LIB)
      ?: throw IllegalStateException("proot missing (filesDir cache and APK copy both failed)")
    val loader = NativeLibResolver.resolve(appContext, LOADER_LIB)
      ?: throw IllegalStateException("proot loader missing")
    val linux = File(workspacePath, ".sandbox/linux")
    val tmp = File(workspacePath, ".sandbox/tmp")
    tmp.mkdirs()
    val guestCwd = when {
      cwd.isNullOrBlank() -> "/workspace"
      cwd.startsWith("/workspace") -> cwd
      else -> "/workspace/${cwd.trimStart('/')}"
    }

    val builder = ProcessBuilder(
      buildGuestCommand(
        proot = exec,
        linuxDir = linux,
        guestCwd = guestCwd,
        hostWorkspace = workspacePath,
        command = command,
      ),
    )
    builder.directory(File(workspacePath))
    val env = builder.environment()
    env["PROOT_LOADER"] = loader.absolutePath
    env["PROOT_TMP_DIR"] = tmp.absolutePath
    env["TMPDIR"] = tmp.absolutePath
    return OutputDrainer.capture(builder.start(), timeoutMs)
  }
}

/** Vendored proot native library resolution (cached copy → APK). */
private object NativeLibResolver {
  fun resolve(appContext: Context, libFileName: String): File? {
    val candidates = mutableListOf<File>()

    // 1) Previously copied fallback (survives restarts and app updates)
    candidates += File(appContext.filesDir, "proot/$libFileName")

    for (f in candidates) {
      if (f.isFile && f.length() > 0L) {
        makeExecutable(f)
        return f
      }
    }

    // 2) Copy out of APK / split APKs into app filesDir
    val copied = copyFromApk(appContext, libFileName)
    if (copied != null) {
      makeExecutable(copied)
      return copied
    }
    return null
  }

  private fun makeExecutable(file: File) {
    try {
      if (!file.canExecute()) {
        file.setExecutable(true, false)
      }
    } catch (e: Exception) {
      Log.w("LinuxSandbox", "setExecutable failed for ${file.absolutePath}: ${e.message}")
    }
  }

  private fun copyFromApk(appContext: Context, libFileName: String): File? {
    val abi = primaryAbi()
    val entryNames = listOf(
      "lib/$abi/$libFileName",
      "lib/${abi.replace('-', '_')}/$libFileName",
    )
    val apkPaths = mutableListOf<String>()
    val ai = appContext.applicationInfo
    if (!ai.sourceDir.isNullOrBlank()) apkPaths += ai.sourceDir
    ai.splitSourceDirs?.forEach { if (!it.isNullOrBlank()) apkPaths += it }

    val outDir = File(appContext.filesDir, "proot")
    outDir.mkdirs()
    val out = File(outDir, libFileName)

    for (apk in apkPaths) {
      try {
        ZipFile(apk).use { zip ->
          for (entryName in entryNames) {
            val entry = zip.getEntry(entryName) ?: continue
            zip.getInputStream(entry).use { input ->
              FileOutputStream(out).use { output -> input.copyTo(output) }
            }
            if (out.isFile && out.length() > 0L) {
              Log.i("LinuxSandbox", "copied $entryName from $apk → ${out.absolutePath}")
              return out
            }
          }
        }
      } catch (e: Exception) {
        Log.w("LinuxSandbox", "copyFromApk($apk, $libFileName): ${e.message}")
      }
    }
    Log.w(
      "LinuxSandbox",
      "copyFromApk: no $libFileName entry found (abi=$abi, entries=$entryNames, apks=$apkPaths)",
    )
    return null
  }

  private fun primaryAbi(): String {
    val abis = Build.SUPPORTED_ABIS
    if (abis.isNotEmpty()) {
      val a = abis[0]
      if (a.contains("arm64")) return "arm64-v8a"
      if (a.contains("x86_64") || a.contains("amd64")) return "x86_64"
      return a
    }
    return "arm64-v8a"
  }
}

/** Assemble the proot argv: flags, guest bindings, and a clean bash -lc. */
private fun buildGuestCommand(
  proot: File,
  linuxDir: File,
  guestCwd: String,
  hostWorkspace: String,
  command: String,
): List<String> {
  val argv = mutableListOf<String>()
  argv += proot.absolutePath
  argv += listOf(
    "--root-id",
    "--link2symlink",
    "--kill-on-exit",
    "-r",
    linuxDir.absolutePath,
    "-w",
    guestCwd,
    "-b",
    "$hostWorkspace:/workspace",
  )
  for (mount in KERNEL_FS_MOUNTS) {
    argv += listOf("-b", mount)
  }
  argv += listOf(
    "/usr/bin/env",
    "-i",
    "HOME=/root",
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "LANG=C.UTF-8",
    "TERM=xterm-256color",
    "/bin/bash",
    "-lc",
    command,
  )
  return argv
}

/** Captures capped stdout/stderr and enforces the exec timeout. */
private object OutputDrainer {
  private const val MAX_CHARS = 128 * 1024
  private const val GRACE_AFTER_TERM_MS = 2_000L

  fun capture(process: Process, timeoutMs: Long): Map<String, Any?> {
    val stdout = LineDrain(process.inputStream)
    val stderr = LineDrain(process.errorStream)
    val finished = process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
    if (!finished) {
      // SIGTERM first so proot's --kill-on-exit can reap the guest
      // apt/dpkg; SIGKILL (destroyForcibly) cannot be intercepted and
      // would leave orphan apt processes still holding /var/lib/dpkg locks.
      process.destroy()
      if (!process.waitFor(GRACE_AFTER_TERM_MS, TimeUnit.MILLISECONDS)) {
        // SIGTERM did not finish the tree: kill surviving guest children
        // (orphaned apt/dpkg that keep the dpkg lock) before the SIGKILL.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          killDescendants(process.pid())
        }
        process.destroyForcibly()
      }
      stdout.joinFor(1_000)
      stderr.joinFor(1_000)
      return mapOf(
        "exitCode" to -1,
        "stdout" to stdout.text(),
        "stderr" to stderr.text(),
        "timedOut" to true,
      )
    }
    stdout.joinFor(1_000)
    stderr.joinFor(1_000)
    return mapOf(
      "exitCode" to process.exitValue(),
      "stdout" to stdout.text(),
      "stderr" to stderr.text(),
      "timedOut" to false,
    )
  }

  /**
   * Recursively SIGKILL all children of [pid] by walking /proc (the proot
   * guest processes are host processes, so the host view sees them). Called
   * before destroyForcibly so no apt/dpkg survives to hold the dpkg lock.
   * API 26+ (Process.pid and stat scanning); older devices skip the cleanup.
   */
  private fun killDescendants(pid: Long) {
    val children = mutableListOf<Long>()
    try {
      File("/proc").listFiles()?.forEach { dir ->
        val pidText = dir.name.toLongOrNull() ?: return@forEach
        val stat = File(dir, "stat")
        if (!stat.isFile) return@forEach
        val text = stat.readText()
        val open = text.indexOf('(')
        val close = text.lastIndexOf(')')
        if (open < 0 || close <= open) return@forEach
        val parts = text.substring(close + 1).trim().split(' ')
        // parts[0] = state, parts[1] = ppid
        if (parts.size > 1 && parts[1].toLongOrNull() == pid) {
          children += pidText
        }
      }
    } catch (e: Exception) {
      Log.w(TAG, "killDescendants scan: ${e.message}")
      return
    }
    children.forEach { child ->
      killDescendants(child)
      try {
        Process.killProcess(child.toInt())
      } catch (e: Exception) {
        Log.w(TAG, "killDescendants kill $child: ${e.message}")
      }
    }
  }

  private class LineDrain(private val stream: java.io.InputStream) : Thread() {
    private val collected = StringBuffer()

    init {
      start()
    }

    override fun run() {
      BufferedReader(InputStreamReader(stream)).use { reader ->
        var line: String?
        while (reader.readLine().also { line = it } != null) {
          if (collected.length < MAX_CHARS) {
            collected.appendLine(line)
          }
        }
      }
    }

    fun joinFor(millis: Long) = join(millis)

    fun text(): String = collected.toString()
  }
}

private const val TAG = "LinuxSandbox"
private const val EXEC_LIB = "libproot_exec.so"
private const val LOADER_LIB = "libproot_loader.so"
private val KERNEL_FS_MOUNTS = listOf("/dev", "/proc", "/sys")
private val PUBLIC_DNS = listOf("1.1.1.1", "8.8.8.8", "223.5.5.5")
