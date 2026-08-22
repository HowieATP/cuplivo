import Flutter
import UIKit
import XCTest
@testable import Runner

final class CuplivoSandboxRootfsInstallerTests: XCTestCase {
  private let fm = FileManager.default
  private var tempDirectory: URL!

  override func setUpWithError() throws {
    tempDirectory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDirectory, fm.fileExists(atPath: tempDirectory.path) {
      try fm.removeItem(at: tempDirectory)
    }
  }

  func testCommitReplacesExistingRootfsAndCleansBackup() throws {
    let destination = tempDirectory.appendingPathComponent("alpine-rootfs")
    let staging = tempDirectory.appendingPathComponent("alpine-rootfs.staging-test")
    try makeRootfs(at: destination, marker: "old")
    try makeRootfs(at: staging, marker: "new")

    try CuplivoSandboxRootfsInstaller.commitStagedRootfs(staging, to: destination)

    XCTAssertEqual(try marker(at: destination), "new")
    XCTAssertFalse(fm.fileExists(atPath: staging.path))
    XCTAssertFalse(try artifactNames().contains { $0.hasPrefix("alpine-rootfs.backup-") })
  }

  func testInvalidStagingPreservesExistingRootfs() throws {
    let destination = tempDirectory.appendingPathComponent("alpine-rootfs")
    let staging = tempDirectory.appendingPathComponent("alpine-rootfs.staging-test")
    try makeRootfs(at: destination, marker: "old")
    try makeRootfs(at: staging, marker: "new")
    let busybox = staging.appendingPathComponent("data/bin/busybox")
    try fm.removeItem(at: busybox)
    try fm.createDirectory(at: busybox, withIntermediateDirectories: true)

    XCTAssertThrowsError(
      try CuplivoSandboxRootfsInstaller.commitStagedRootfs(staging, to: destination)
    )

    XCTAssertEqual(try marker(at: destination), "old")
  }

  func testCancelledCommitPreservesExistingRootfs() throws {
    let destination = tempDirectory.appendingPathComponent("alpine-rootfs")
    let staging = tempDirectory.appendingPathComponent("alpine-rootfs.staging-test")
    try makeRootfs(at: destination, marker: "old")
    try makeRootfs(at: staging, marker: "new")

    XCTAssertThrowsError(
      try CuplivoSandboxRootfsInstaller.commitStagedRootfs(
        staging,
        to: destination,
        isCancelled: { true }
      )
    ) { error in
      guard let installerError = error as? SandboxRootfsInstallerError,
        case .cancelled = installerError
      else {
        XCTFail("Expected cancellation, got \(error)")
        return
      }
    }

    XCTAssertEqual(try marker(at: destination), "old")
  }

  func testInterruptedInstallRestoresOnlyUsableBackup() throws {
    let destination = tempDirectory.appendingPathComponent("alpine-rootfs")
    let backup = tempDirectory.appendingPathComponent("alpine-rootfs.backup-test")
    let staging = tempDirectory.appendingPathComponent("alpine-rootfs.staging-test")
    try makeRootfs(at: backup, marker: "old")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)

    try CuplivoSandboxRootfsInstaller.recoverInterruptedInstall(to: destination)

    XCTAssertEqual(try marker(at: destination), "old")
    XCTAssertFalse(fm.fileExists(atPath: backup.path))
    XCTAssertFalse(fm.fileExists(atPath: staging.path))
  }

  func testUsableDestinationWinsAndCleansStaleArtifacts() throws {
    let destination = tempDirectory.appendingPathComponent("alpine-rootfs")
    let backup = tempDirectory.appendingPathComponent("alpine-rootfs.backup-test")
    let staging = tempDirectory.appendingPathComponent("alpine-rootfs.staging-test")
    try makeRootfs(at: destination, marker: "current")
    try makeRootfs(at: backup, marker: "old")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)

    try CuplivoSandboxRootfsInstaller.recoverInterruptedInstall(to: destination)

    XCTAssertEqual(try marker(at: destination), "current")
    XCTAssertFalse(fm.fileExists(atPath: backup.path))
    XCTAssertFalse(fm.fileExists(atPath: staging.path))
  }

  func testMultipleUsableBackupsArePreserved() throws {
    let destination = tempDirectory.appendingPathComponent("alpine-rootfs")
    let first = tempDirectory.appendingPathComponent("alpine-rootfs.backup-first")
    let second = tempDirectory.appendingPathComponent("alpine-rootfs.backup-second")
    try makeRootfs(at: first, marker: "first")
    try makeRootfs(at: second, marker: "second")

    XCTAssertThrowsError(
      try CuplivoSandboxRootfsInstaller.recoverInterruptedInstall(to: destination)
    )

    XCTAssertTrue(fm.fileExists(atPath: first.path))
    XCTAssertTrue(fm.fileExists(atPath: second.path))
    XCTAssertFalse(fm.fileExists(atPath: destination.path))
  }

  func testVerifyRejectsDirectoryInPlaceOfRequiredFile() throws {
    let rootfs = tempDirectory.appendingPathComponent("alpine-rootfs")
    try makeRootfs(at: rootfs, marker: "current")
    let meta = rootfs.appendingPathComponent("meta.db")
    try fm.removeItem(at: meta)
    try fm.createDirectory(at: meta, withIntermediateDirectories: true)

    XCTAssertThrowsError(try CuplivoSandboxRootfsInstaller.verifyRootfs(at: rootfs))
  }

  private func makeRootfs(at url: URL, marker: String) throws {
    try fm.createDirectory(
      at: url.appendingPathComponent("data/bin"),
      withIntermediateDirectories: true
    )
    try fm.createDirectory(
      at: url.appendingPathComponent("data/root"),
      withIntermediateDirectories: true
    )
    try Data([0]).write(to: url.appendingPathComponent("meta.db"))
    try Data([0]).write(to: url.appendingPathComponent("data/bin/busybox"))
    try Data("aarch64".utf8).write(to: url.appendingPathComponent(".arch"))
    try Data(marker.utf8).write(to: url.appendingPathComponent("data/root/marker"))
  }

  private func marker(at rootfs: URL) throws -> String {
    return try String(
      contentsOf: rootfs.appendingPathComponent("data/root/marker"),
      encoding: .utf8
    )
  }

  private func artifactNames() throws -> [String] {
    return try fm.contentsOfDirectory(
      at: tempDirectory,
      includingPropertiesForKeys: nil
    ).map(\.lastPathComponent)
  }
}
