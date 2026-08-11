package com.cup11.cuplivo

import android.util.Log
import java.io.BufferedInputStream
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.Locale
import java.util.zip.GZIPInputStream

/**
 * Streaming unpacker for Ubuntu base rootfs archives (.tar.gz).
 *
 * Android's toybox tar often refuses the hardlinks used by Ubuntu base
 * archives (link(2) returns EACCES), so entries are materialized manually:
 * hardlinks degrade to a plain copy, and relative symlink targets must stay
 * inside the rootfs (absolute guest targets are kept for proot). Cuplivo's
 * own ustar reader — written from scratch, not derived from other launchers.
 */
object RootfsExtractor {
  private const val TAG = "RootfsExtractor"
  private const val BLOCK_BYTES = 512
  private const val IO_CHUNK = 64 * 1024

  /** Entry types a ustar header can describe. */
  private enum class EntryKind {
    REGULAR,
    DIRECTORY,
    SYMLINK,
    HARDLINK,
    GNU_LONG_NAME,
    GNU_LONG_LINK,
    PAX_EXTENDED,
    OTHER,
  }

  /** A decoded tar header, possibly with GNU long-name/PAX overrides applied. */
  private class TarEntry(
    val name: String,
    val mode: Int,
    val size: Long,
    val modTime: Long,
    val kind: EntryKind,
    val linkName: String,
  ) {
    /** Records are padded to the next 512-byte block boundary. */
    fun padBytes(): Long {
      val remainder = size % BLOCK_BYTES
      return if (remainder == 0L) 0L else BLOCK_BYTES - remainder
    }

    fun withOverrides(overriddenName: String?, overriddenLink: String?): TarEntry {
      if (overriddenName == null && overriddenLink == null) return this
      return TarEntry(
        name = overriddenName ?: name,
        mode = mode,
        size = size,
        modTime = modTime,
        kind = kind,
        linkName = overriddenLink ?: linkName,
      )
    }
  }

  fun extract(archive: File, targetDir: File) {
    require(archive.exists() && archive.length() > 0L) {
      "archive missing or empty: ${archive.absolutePath}"
    }
    targetDir.mkdirs()
    val fileName = archive.name.lowercase(Locale.US)
    require(
      fileName.endsWith(".tar.gz") ||
        fileName.endsWith(".tgz") ||
        fileName.endsWith(".tar"),
    ) {
      "unsupported archive format: ${archive.name} (only tar.gz supported)"
    }

    val buffered = BufferedInputStream(archive.inputStream(), IO_CHUNK)
    val input: InputStream =
      if (fileName.endsWith(".tar")) buffered else GZIPInputStream(buffered, IO_CHUNK)
    try {
      unpack(input, targetDir)
    } finally {
      input.close()
    }
  }

  private fun unpack(input: InputStream, targetDir: File) {
    val scanner = TarScanner(input)
    var extracted = 0
    while (true) {
      val entry = scanner.nextEntry() ?: break
      materialize(scanner, targetDir, entry)
      extracted++
      if (extracted % 500 == 0) {
        Log.d(TAG, "extracted $extracted entries… (${entry.name})")
      }
    }
    Log.i(TAG, "extract complete: $extracted entries → ${targetDir.absolutePath}")
  }

  /**
   * Writes one entry to disk. The data section of non-regular entries (usually
   * empty) is discarded after dispatch, then the stream is re-aligned.
   */
  private fun materialize(scanner: TarScanner, targetDir: File, entry: TarEntry) {
    val target = targetDir.safeDestination(entry.name)
    target.parentFile?.mkdirs()
    when (entry.kind) {
      EntryKind.DIRECTORY -> target.mkdirs()
      EntryKind.SYMLINK -> createSymlink(targetDir, target, entry.linkName)
      EntryKind.HARDLINK -> createHardLink(targetDir, target, entry.linkName)
      EntryKind.REGULAR -> {
        target.outputStream().use { out -> scanner.copyPayload(out, entry.size) }
        applyPermissions(target, entry.mode)
      }
      EntryKind.GNU_LONG_NAME,
      EntryKind.GNU_LONG_LINK,
      EntryKind.PAX_EXTENDED,
      EntryKind.OTHER -> Unit
    }
    if (entry.kind != EntryKind.REGULAR) {
      scanner.skipOver(entry.size)
    }
    scanner.alignToBlock(entry.size)
    if (entry.modTime > 0 && entry.kind != EntryKind.SYMLINK) {
      try {
        target.setLastModified(entry.modTime * 1000)
      } catch (_: Exception) {
      }
    }
  }

  /** Reads raw ustar blocks and resolves GNU long-name/PAX indirections. */
  private class TarScanner(private val source: InputStream) {
    private val header = ByteArray(BLOCK_BYTES)
    private var overriddenName: String? = null
    private var overriddenLink: String? = null

    /** Next real entry, or null at end-of-archive. */
    fun nextEntry(): TarEntry? {
      while (true) {
        ensureAlive()
        if (!readHeaderBlock()) return null
        val decoded = decodeHeader()
        val entry = decoded.withOverrides(overriddenName, overriddenLink)
        overriddenName = null
        overriddenLink = null

        if (entry.name.isBlank()) {
          skipOver(entry.size + entry.padBytes())
          continue
        }

        when (entry.kind) {
          EntryKind.GNU_LONG_NAME -> {
            overriddenName = readPayload(entry.size)
              .toString(Charsets.UTF_8)
              .trimEnd('\u0000', '\n')
            alignToBlock(entry.size)
            continue
          }
          EntryKind.GNU_LONG_LINK -> {
            overriddenLink = readPayload(entry.size)
              .toString(Charsets.UTF_8)
              .trimEnd('\u0000', '\n')
            alignToBlock(entry.size)
            continue
          }
          EntryKind.PAX_EXTENDED -> {
            val fields = parsePaxFields(readPayload(entry.size).toString(Charsets.UTF_8))
            overriddenName = fields["path"]
            overriddenLink = fields["linkpath"]
            alignToBlock(entry.size)
            continue
          }
          else -> Unit
        }
        return entry
      }
    }

    /** True when a real header was read; false on clean EOF. */
    private fun readHeaderBlock(): Boolean {
      val read = fill(header)
      if (read == 0) return false
      if (read < BLOCK_BYTES) {
        throw EOFException("Unexpected EOF while reading tar header")
      }
      return header.any { it != 0.toByte() }
    }

    private fun decodeHeader(): TarEntry {
      val name = fieldString(0, 100)
      val prefix = fieldString(345, 155)
      val fullName = listOf(prefix, name)
        .filter { it.isNotBlank() }
        .joinToString("/")

      val kind = when ((header[156].toInt() and 0xFF).toChar()) {
        '0', '\u0000' -> EntryKind.REGULAR
        '5' -> EntryKind.DIRECTORY
        '2' -> EntryKind.SYMLINK
        '1' -> EntryKind.HARDLINK
        'L' -> EntryKind.GNU_LONG_NAME
        'K' -> EntryKind.GNU_LONG_LINK
        'x', 'g' -> EntryKind.PAX_EXTENDED
        else -> EntryKind.OTHER
      }

      return TarEntry(
        name = if (fullName.isBlank()) "" else normalizeEntryName(fullName),
        mode = numericField(100, 8).toInt(),
        size = numericField(124, 12),
        modTime = numericField(136, 12),
        kind = kind,
        linkName = fieldString(157, 100),
      )
    }

    /** NUL-padded text field. */
    private fun fieldString(offset: Int, length: Int): String {
      var end = offset + length
      for (i in offset until offset + length) {
        if (header[i] == 0.toByte()) {
          end = i
          break
        }
      }
      return String(header, offset, end - offset, Charsets.UTF_8).trim()
    }

    /** Octal size/mode/mtime field, with GNU base-256 for large values. */
    private fun numericField(offset: Int, length: Int): Long {
      val firstByte = header[offset].toInt() and 0xFF
      if (firstByte and 0x80 != 0) {
        var value = 0L
        for (i in 1 until length) {
          value = (value shl 8) or (header[offset + i].toInt() and 0xFF).toLong()
        }
        return value
      }
      var text = ""
      for (i in offset until offset + length) {
        val b = header[i].toInt()
        if (b == 0) break
        text += (b and 0xFF).toChar()
      }
      text = text.trim().lowercase(Locale.US)
      val digits = text.filter { it in '0'..'7' }
      return if (digits.isEmpty()) 0L else digits.toLong(8)
    }

    /** Whole-record payload read (GNU long names / PAX data). */
    private fun readPayload(size: Long): ByteArray {
      require(size <= Int.MAX_VALUE) { "Tar entry too large to buffer: $size" }
      val buffer = ByteArray(size.toInt())
      val read = fill(buffer)
      if (read != buffer.size) {
        throw EOFException("Unexpected EOF while reading tar entry")
      }
      return buffer
    }

    fun copyPayload(out: OutputStream, size: Long) {
      val chunk = ByteArray(IO_CHUNK)
      var remaining = size
      while (remaining > 0) {
        ensureAlive()
        val want = minOf(chunk.size.toLong(), remaining).toInt()
        val read = source.read(chunk, 0, want)
        if (read < 0) throw EOFException("Unexpected EOF while extracting tar entry")
        out.write(chunk, 0, read)
        remaining -= read
      }
    }

    /** Drop `size` bytes from the record payload. */
    fun skipOver(size: Long) {
      var remaining = size
      while (remaining > 0) {
        ensureAlive()
        val skipped = source.skip(remaining)
        if (skipped > 0) {
          remaining -= skipped
        } else if (source.read() >= 0) {
          remaining--
        } else {
          throw EOFException("Unexpected EOF while skipping tar data")
        }
      }
    }

    /** Skip the block padding that follows each record. */
    fun alignToBlock(size: Long) {
      val padding = size % BLOCK_BYTES
      if (padding != 0L) {
        skipOver(BLOCK_BYTES - padding)
      }
    }

    private fun fill(buffer: ByteArray): Int {
      var offset = 0
      while (offset < buffer.size) {
        val read = source.read(buffer, offset, buffer.size - offset)
        if (read < 0) break
        offset += read
      }
      return offset
    }

    private fun ensureAlive() {
      if (Thread.currentThread().isInterrupted) {
        throw InterruptedException("Rootfs extract cancelled")
      }
    }
  }

  private fun parsePaxFields(text: String): Map<String, String> {
    val result = mutableMapOf<String, String>()
    var index = 0
    while (index < text.length) {
      val space = text.indexOf(' ', index)
      if (space < 0) break
      val length = text.substring(index, space).toIntOrNull() ?: break
      val end = (index + length).coerceAtMost(text.length)
      val record = text.substring(space + 1, end).trimEnd('\n')
      val equals = record.indexOf('=')
      if (equals > 0) {
        result[record.substring(0, equals)] = record.substring(equals + 1)
      }
      index += length
    }
    return result
  }

  private fun createSymlink(root: File, target: File, linkName: String) {
    if (linkName.isBlank()) return
    val linkTarget: File = if (File(linkName).isAbsolute) {
      // Absolute guest targets (e.g. /usr/lib/x) must survive for proot.
      File(linkName)
    } else {
      val resolved = File(target.parentFile ?: root, linkName).canonicalFile
      val rootFile = root.canonicalFile
      require(
        resolved.path == rootFile.path ||
          resolved.path.startsWith(rootFile.path + File.separator),
      ) {
        "Symlink escapes rootfs: ${target.name} -> $linkName"
      }
      File(
        (target.parentFile ?: root).toPath()
          .relativize(resolved.toPath())
          .toString(),
      )
    }
    try {
      if (target.exists()) target.delete()
      Files.createSymbolicLink(target.toPath(), linkTarget.toPath())
    } catch (e: Exception) {
      Log.w(TAG, "symlink failed ${target.name} -> $linkName: ${e.message}")
    }
  }

  private fun createHardLink(root: File, target: File, linkName: String) {
    if (linkName.isBlank()) return
    val source = try {
      root.safeDestination(linkName)
    } catch (e: Exception) {
      Log.w(TAG, "hardlink source invalid $linkName: ${e.message}")
      return
    }
    if (!source.exists()) {
      Log.w(TAG, "hardlink source missing: $linkName")
      return
    }
    if (target.exists()) target.delete()
    try {
      Files.createLink(target.toPath(), source.toPath())
    } catch (e: Exception) {
      when (e) {
        is IOException,
        is UnsupportedOperationException,
        is SecurityException,
        -> {
          // Android commonly rejects link(2); a copy keeps the rootfs usable.
          source.copyTo(target, overwrite = true)
          target.setReadable(source.canRead(), false)
          target.setWritable(source.canWrite(), true)
          target.setExecutable(source.canExecute(), false)
          Log.d(TAG, "hardlink→copy ${target.name} ← $linkName")
        }
        else -> throw e
      }
    }
  }

  private fun File.safeDestination(path: String): File {
    val normalized = normalizeEntryName(path)
    val root = canonicalFile
    val target = File(this, normalized).canonicalFile
    require(target.path == root.path || target.path.startsWith(root.path + File.separator)) {
      "Rootfs entry escapes target directory: $path"
    }
    return target
  }

  private fun applyPermissions(file: File, mode: Int) {
    try {
      file.setReadable(mode and 0b100_000_000 != 0, false)
      file.setWritable(mode and 0b010_000_000 != 0, true)
      file.setExecutable(mode and 0b001_000_000 != 0, false)
    } catch (_: Exception) {
    }
  }

  private fun normalizeEntryName(path: String): String {
    val normalized = path
      .replace('\\', '/')
      .trim()
      .trimStart('/')
      .removePrefix("./")
    require(normalized.isNotBlank()) { "Rootfs entry path is blank" }
    require(!normalized.contains('\u0000')) { "Rootfs entry path contains invalid character" }
    require(normalized.split('/').none { it == ".." }) {
      "Rootfs entry escapes target directory: $path"
    }
    return normalized
  }
}
