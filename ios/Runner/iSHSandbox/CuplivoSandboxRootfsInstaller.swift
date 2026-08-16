//
//  CuplivoSandboxRootfsInstaller.swift
//  Runner
//
//  Extracts the bundled Alpine fakefs rootfs zip into the shared sandbox
//  directory. ZIP reader adapted from OpenMinis/MinisApp RootfsManager.swift
//  (GPL-3.0, see ios/sandbox/NOTICE); deflate via Apple's Compression
//  framework, no third-party dependencies.
//

import Foundation
import Compression

enum SandboxRootfsInstallerError: Error, LocalizedError {
  case bundleResourceMissing
  case archiveOpenFailed
  case cancelled
  case unsafeEntryPath(String)
  case extractionFailed(String)

  var errorDescription: String? {
    switch self {
    case .bundleResourceMissing: return "alpine-rootfs.zip not found in bundle"
    case .archiveOpenFailed: return "Failed to open rootfs zip archive"
    case .cancelled: return "Rootfs installation cancelled"
    case .unsafeEntryPath(let p): return "Unsafe zip entry path: \(p)"
    case .extractionFailed(let m): return m
    }
  }
}

final class CuplivoSandboxRootfsInstaller {
  static let resourceName = "alpine-rootfs"

  /// Install the bundled rootfs zip into `destDir` atomically: the archive is
  /// first extracted into a sibling staging directory and structurally
  /// verified, then replaced with a backup for recovery. A failed
  /// or cancelled install never deletes the previously usable rootfs.
  static func install(to destDir: URL, isCancelled: () -> Bool = { false }) throws {
    guard let zipURL = Bundle.main.url(forResource: resourceName, withExtension: "zip") else {
      throw SandboxRootfsInstallerError.bundleResourceMissing
    }
    guard let archive = SandboxZipArchive(url: zipURL) else {
      throw SandboxRootfsInstallerError.archiveOpenFailed
    }

    let fm = FileManager.default
    let parent = destDir.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    try recoverInterruptedInstall(to: destDir, fileManager: fm)

    let staging = parent.appendingPathComponent(
      "\(destDir.lastPathComponent).staging-\(UUID().uuidString)"
    )

    do {
      if isCancelled() {
        throw SandboxRootfsInstallerError.cancelled
      }
      try fm.createDirectory(at: staging, withIntermediateDirectories: true)
      try extract(archive: archive, into: staging, isCancelled: isCancelled)
      try commitStagedRootfs(
        staging,
        to: destDir,
        isCancelled: isCancelled,
        fileManager: fm
      )
      cleanupArtifactsIfDestinationUsable(at: destDir, fileManager: fm)
      NSLog(
        "CuplivoSandboxRootfsInstaller: installed \(archive.entries.count) entries to \(destDir.path)"
      )
    } catch {
      removeArtifact(staging, fileManager: fm)
      throw error
    }
  }

  static func commitStagedRootfs(
    _ staging: URL,
    to destDir: URL,
    isCancelled: () -> Bool = { false },
    fileManager fm: FileManager = .default
  ) throws {
    try verifyRootfs(at: staging)
    if isCancelled() {
      throw SandboxRootfsInstallerError.cancelled
    }

    guard fm.fileExists(atPath: destDir.path) else {
      try fm.moveItem(at: staging, to: destDir)
      return
    }

    let backupName = "\(destDir.lastPathComponent).backup-\(UUID().uuidString)"
    let backup = destDir.deletingLastPathComponent().appendingPathComponent(backupName)
    do {
      _ = try fm.replaceItemAt(
        destDir,
        withItemAt: staging,
        backupItemName: backupName,
        options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
      )
    } catch {
      NSLog(
        "CuplivoSandboxRootfsInstaller: atomic replace failed; "
          + "original/backup retained when available: \(error)"
      )
      throw error
    }
    removeArtifact(backup, fileManager: fm)
  }

  static func recoverInterruptedInstall(
    to destDir: URL,
    fileManager fm: FileManager = .default
  ) throws {
    let parent = destDir.deletingLastPathComponent()
    let candidates: [URL]
    do {
      candidates = try fm.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: [.isRegularFileKey]
      )
    } catch {
      throw SandboxRootfsInstallerError.extractionFailed(
        "Failed to inspect interrupted rootfs installs: \(error.localizedDescription)"
      )
    }

    if isUsableRootfs(at: destDir) {
      cleanupArtifacts(candidates, for: destDir, fileManager: fm)
      return
    }

    let backupPrefix = "\(destDir.lastPathComponent).backup-"
    let usableBackups = candidates.filter {
      $0.lastPathComponent.hasPrefix(backupPrefix) && isUsableRootfs(at: $0)
    }
    guard usableBackups.count <= 1 else {
      throw SandboxRootfsInstallerError.extractionFailed(
        "Multiple usable rootfs backups found; refusing ambiguous recovery"
      )
    }
    guard let backup = usableBackups.first else {
      return
    }

    let displaced = parent.appendingPathComponent(
      "\(destDir.lastPathComponent).staging-recovery-\(UUID().uuidString)"
    )
    let hadDestination = fm.fileExists(atPath: destDir.path)
    if hadDestination {
      try fm.moveItem(at: destDir, to: displaced)
    }
    do {
      try fm.moveItem(at: backup, to: destDir)
    } catch {
      if hadDestination {
        do {
          try fm.moveItem(at: displaced, to: destDir)
        } catch let rollbackError {
          NSLog(
            "CuplivoSandboxRootfsInstaller: recovery rollback failed: \(rollbackError)"
          )
        }
      }
      throw SandboxRootfsInstallerError.extractionFailed(
        "Failed to restore rootfs backup: \(error.localizedDescription)"
      )
    }

    cleanupArtifactsIfDestinationUsable(at: destDir, fileManager: fm)
    NSLog("CuplivoSandboxRootfsInstaller: restored interrupted rootfs backup")
  }

  private static func extract(
    archive: SandboxZipArchive,
    into destDir: URL,
    isCancelled: () -> Bool
  ) throws {
    let fm = FileManager.default
    let destBase = destDir.standardizedFileURL.path
    for entry in archive.entries {
      if isCancelled() {
        throw SandboxRootfsInstallerError.cancelled
      }
      // Zip-slip guard: resolved path must stay inside destDir.
      let entryURL = destDir.appendingPathComponent(entry.path).standardizedFileURL
      guard entryURL.path == destBase || entryURL.path.hasPrefix(destBase + "/") else {
        throw SandboxRootfsInstallerError.unsafeEntryPath(entry.path)
      }
      if entry.isDirectory {
        try fm.createDirectory(at: entryURL, withIntermediateDirectories: true)
        continue
      }
      let parent = entryURL.deletingLastPathComponent()
      if !fm.fileExists(atPath: parent.path) {
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
      }
      guard let data = try archive.extractData(for: entry) else {
        throw SandboxRootfsInstallerError.extractionFailed("Failed to extract \(entry.path)")
      }
      if isCancelled() {
        throw SandboxRootfsInstallerError.cancelled
      }
      try data.write(to: entryURL)
    }
  }

  /// Lightweight structural validation of a staged rootfs before it replaces
  /// the live one. Complements the deeper ZIP-integrity work tracked
  /// separately: a truncated or mis-extracted fakefs must never be committed
  /// as the active rootfs.
  static func verifyRootfs(at dir: URL) throws {
    for probe in ["meta.db", "data/bin/busybox", ".arch"] {
      let url = dir.appendingPathComponent(probe)
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
      guard values?.isRegularFile == true else {
        throw SandboxRootfsInstallerError.extractionFailed(
          "staged rootfs missing regular file \(probe)"
        )
      }
    }
    let arch: String
    do {
      arch = try String(contentsOf: dir.appendingPathComponent(".arch"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      throw SandboxRootfsInstallerError.extractionFailed(
        "staged rootfs .arch unreadable: \(error.localizedDescription)"
      )
    }
    guard arch == "aarch64" else {
      throw SandboxRootfsInstallerError.extractionFailed(
        "staged rootfs arch mismatch (\(arch))"
      )
    }
  }

  private static func isUsableRootfs(at url: URL) -> Bool {
    do {
      try verifyRootfs(at: url)
      return true
    } catch {
      return false
    }
  }

  private static func cleanupArtifactsIfDestinationUsable(
    at destDir: URL,
    fileManager fm: FileManager
  ) {
    guard isUsableRootfs(at: destDir) else { return }
    do {
      let candidates = try fm.contentsOfDirectory(
        at: destDir.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
      )
      cleanupArtifacts(candidates, for: destDir, fileManager: fm)
    } catch {
      NSLog("CuplivoSandboxRootfsInstaller: artifact scan failed: \(error)")
    }
  }

  private static func cleanupArtifacts(
    _ candidates: [URL],
    for destDir: URL,
    fileManager fm: FileManager
  ) {
    let stagingPrefix = "\(destDir.lastPathComponent).staging-"
    let backupPrefix = "\(destDir.lastPathComponent).backup-"
    for url in candidates where url.standardizedFileURL != destDir.standardizedFileURL {
      let name = url.lastPathComponent
      if name.hasPrefix(stagingPrefix) || name.hasPrefix(backupPrefix) {
        removeArtifact(url, fileManager: fm)
      }
    }
  }

  private static func removeArtifact(_ url: URL, fileManager fm: FileManager) {
    guard fm.fileExists(atPath: url.path) else { return }
    do {
      try fm.removeItem(at: url)
    } catch {
      NSLog(
        "CuplivoSandboxRootfsInstaller: failed to clean \(url.lastPathComponent): \(error)"
      )
    }
  }
}

/// Minimal streaming ZIP reader (central directory scan, stored + deflate).
private final class SandboxZipArchive {
  struct Entry {
    let path: String
    let isDirectory: Bool
    let compressedSize: Int
    let uncompressedSize: Int
    let compressionMethod: UInt16
    let localHeaderOffset: UInt64
  }

  private let fileHandle: FileHandle
  private(set) var entries: [Entry] = []

  init?(url: URL) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    self.fileHandle = handle
    do {
      try parseZipFile()
    } catch {
      NSLog("CuplivoSandboxRootfsInstaller: zip parse error: \(error)")
      try? handle.close()
      return nil
    }
  }

  deinit {
    try? fileHandle.close()
  }

  private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    return UInt32(data[offset]) |
      (UInt32(data[offset + 1]) << 8) |
      (UInt32(data[offset + 2]) << 16) |
      (UInt32(data[offset + 3]) << 24)
  }

  private func parseZipFile() throws {
    fileHandle.seekToEndOfFile()
    let fileSize = fileHandle.offsetInFile

    let searchSize: UInt64 = Swift.min(fileSize, 65557)
    fileHandle.seek(toFileOffset: fileSize - searchSize)
    let searchData = fileHandle.readDataToEndOfFile()

    guard let eocdOffset = findEOCD(in: searchData) else {
      throw SandboxRootfsInstallerError.extractionFailed("Invalid ZIP (EOCD not found)")
    }
    let eocdStart = Int(fileSize - searchSize) + eocdOffset

    fileHandle.seek(toFileOffset: UInt64(eocdStart))
    let eocdData = fileHandle.readData(ofLength: 22)
    guard eocdData.count == 22 else {
      throw SandboxRootfsInstallerError.extractionFailed("Invalid ZIP (EOCD truncated)")
    }

    let centralDirOffset = readUInt32(eocdData, at: 16)
    let entryCount = readUInt16(eocdData, at: 10)

    fileHandle.seek(toFileOffset: UInt64(centralDirOffset))
    for _ in 0..<entryCount {
      guard let entry = readCentralDirectoryEntry() else { break }
      entries.append(entry)
    }
  }

  private func findEOCD(in data: Data) -> Int? {
    let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
    guard data.count >= 22 else { return nil }
    for i in stride(from: data.count - 22, through: 0, by: -1) {
      if data[i] == signature[0] && data[i + 1] == signature[1]
        && data[i + 2] == signature[2] && data[i + 3] == signature[3]
      {
        return i
      }
    }
    return nil
  }

  private func readCentralDirectoryEntry() -> Entry? {
    let headerData = fileHandle.readData(ofLength: 46)
    guard headerData.count == 46 else { return nil }

    let sig = readUInt32(headerData, at: 0)
    guard sig == 0x02014B50 else { return nil }

    let compressionMethod = readUInt16(headerData, at: 10)
    let compressedSize = readUInt32(headerData, at: 20)
    let uncompressedSize = readUInt32(headerData, at: 24)
    let fileNameLength = readUInt16(headerData, at: 28)
    let extraLength = readUInt16(headerData, at: 30)
    let commentLength = readUInt16(headerData, at: 32)
    let localHeaderOffset = readUInt32(headerData, at: 42)

    let fileNameData = fileHandle.readData(ofLength: Int(fileNameLength))
    let fileName = String(data: fileNameData, encoding: .utf8) ?? ""

    fileHandle.seek(toFileOffset: fileHandle.offsetInFile + UInt64(extraLength + commentLength))

    return Entry(
      path: fileName,
      isDirectory: fileName.hasSuffix("/"),
      compressedSize: Int(compressedSize),
      uncompressedSize: Int(uncompressedSize),
      compressionMethod: compressionMethod,
      localHeaderOffset: UInt64(localHeaderOffset)
    )
  }

  func extractData(for entry: Entry) throws -> Data? {
    fileHandle.seek(toFileOffset: entry.localHeaderOffset)

    let localHeader = fileHandle.readData(ofLength: 30)
    guard localHeader.count == 30 else { return nil }

    let fileNameLen = readUInt16(localHeader, at: 26)
    let extraLen = readUInt16(localHeader, at: 28)

    fileHandle.seek(toFileOffset: fileHandle.offsetInFile + UInt64(fileNameLen + extraLen))

    let compressedData = fileHandle.readData(ofLength: entry.compressedSize)

    if entry.compressionMethod == 0 {
      return compressedData
    } else if entry.compressionMethod == 8 {
      return decompressDeflate(compressedData, expectedSize: entry.uncompressedSize)
    } else {
      NSLog("CuplivoSandboxRootfsInstaller: unsupported compression method \(entry.compressionMethod)")
      return nil
    }
  }

  private func decompressDeflate(_ data: Data, expectedSize: Int) -> Data? {
    guard expectedSize > 0 else { return Data() }
    var decompressed = Data(count: expectedSize)
    let result = decompressed.withUnsafeMutableBytes { destPtr -> Int in
      data.withUnsafeBytes { srcPtr -> Int in
        let status = compression_decode_buffer(
          destPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
          expectedSize,
          srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
          data.count,
          nil,
          COMPRESSION_ZLIB
        )
        return status
      }
    }
    if result > 0 {
      decompressed.count = result
      return decompressed
    }
    return nil
  }
}
