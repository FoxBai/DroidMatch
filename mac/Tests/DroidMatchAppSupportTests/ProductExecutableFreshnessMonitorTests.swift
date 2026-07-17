import Darwin
import Foundation
import Testing
@testable import DroidMatchAppSupport

@Test @MainActor
func executableFreshnessMonitorDetectsReplacementAndRemoval() async throws {
    let currentProcessMonitor = ProductExecutableFreshnessMonitor()
    currentProcessMonitor.checkNow()
    #expect(!currentProcessMonitor.replacementDetected)

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let executable = root.appendingPathComponent("DroidMatch")
    try Data("first".utf8).write(to: executable, options: .withoutOverwriting)
    var replacementNotifications = 0
    let replacementMonitor = ProductExecutableFreshnessMonitor(
        executableURL: executable,
        pollIntervalNanoseconds: 1_000_000,
        bindToCurrentProcessExecutable: false,
        onReplacement: { replacementNotifications += 1 }
    )
    replacementMonitor.checkNow()
    #expect(!replacementMonitor.replacementDetected)

    let candidate = root.appendingPathComponent("DroidMatch.next")
    try Data("second".utf8).write(to: candidate, options: .withoutOverwriting)
    #expect(rename(candidate.path, executable.path) == 0)
    replacementMonitor.start()
    for _ in 0..<100 where !replacementMonitor.replacementDetected {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(replacementMonitor.replacementDetected)
    #expect(replacementNotifications == 1)
    replacementMonitor.checkNow()
    replacementMonitor.start()
    #expect(replacementNotifications == 1)

    let removable = root.appendingPathComponent("DroidMatch.removable")
    try Data("third".utf8).write(to: removable, options: .withoutOverwriting)
    let removalMonitor = ProductExecutableFreshnessMonitor(
        executableURL: removable,
        bindToCurrentProcessExecutable: false
    )
    try FileManager.default.removeItem(at: removable)
    removalMonitor.checkNow()
    #expect(removalMonitor.replacementDetected)

    let stopped = root.appendingPathComponent("DroidMatch.stopped")
    try Data("fourth".utf8).write(to: stopped, options: .withoutOverwriting)
    let stoppedMonitor = ProductExecutableFreshnessMonitor(
        executableURL: stopped,
        pollIntervalNanoseconds: 1_000_000,
        bindToCurrentProcessExecutable: false
    )
    stoppedMonitor.start()
    stoppedMonitor.stop()
    try FileManager.default.removeItem(at: stopped)
    try await Task.sleep(nanoseconds: 5_000_000)
    #expect(!stoppedMonitor.replacementDetected)

    let linked = root.appendingPathComponent("DroidMatch.linked")
    #expect(symlink(executable.path, linked.path) == 0)
    let linkedMonitor = ProductExecutableFreshnessMonitor(
        executableURL: linked,
        bindToCurrentProcessExecutable: false
    )
    #expect(linkedMonitor.replacementDetected)
}
