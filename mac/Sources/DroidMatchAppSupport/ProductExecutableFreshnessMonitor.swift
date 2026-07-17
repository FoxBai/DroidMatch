import Combine
import Darwin
import Foundation
import MachO

/// Detects when transactional App publication replaces the executable backing
/// the current process. A running process cannot adopt those new bytes, so it
/// must stop device work and ask the user to launch the published copy.
@MainActor
package final class ProductExecutableFreshnessMonitor: ObservableObject {
    @Published package private(set) var replacementDetected: Bool

    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private let executableURL: URL
    private let originalIdentity: Identity?
    private let pollIntervalNanoseconds: UInt64
    private let onReplacement: @MainActor () -> Void
    private var pollingTask: Task<Void, Never>?
    private var didNotifyReplacement = false

    package init(
        executableURL: URL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]),
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        bindToCurrentProcessExecutable: Bool = true,
        onReplacement: @escaping @MainActor () -> Void = {}
    ) {
        self.executableURL = executableURL
        originalIdentity = bindToCurrentProcessExecutable
            ? Self.currentProcessExecutableIdentity()
            : Self.identity(at: executableURL)
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.onReplacement = onReplacement
        replacementDetected = originalIdentity == nil
        notifyReplacementIfNeeded()
    }

    package func start() {
        checkNow()
        guard pollingTask == nil, !replacementDetected else { return }
        let interval = pollIntervalNanoseconds
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self else { return }
                self.checkNow()
                if self.replacementDetected { return }
            }
        }
    }

    package func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Missing, non-regular, or identity-changed executable paths all require a
    /// restart. Once stale, this process can never become current again.
    package func checkNow() {
        guard !replacementDetected else { return }
        replacementDetected = Self.identity(at: executableURL) != originalIdentity
        if replacementDetected {
            stop()
            notifyReplacementIfNeeded()
        }
    }

    private func notifyReplacementIfNeeded() {
        guard replacementDetected, !didNotifyReplacement else { return }
        didNotifyReplacement = true
        onReplacement()
    }

    private static func identity(at url: URL) -> Identity? {
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return Identity(
            device: UInt64(UInt32(truncatingIfNeeded: metadata.st_dev)),
            inode: UInt64(metadata.st_ino)
        )
    }

    /// Reads the vnode backing dyld image zero directly from the current
    /// process's mapped region. Statting only the canonical path would race an
    /// App swap that occurs after exec but before this object initializes.
    private static func currentProcessExecutableIdentity() -> Identity? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var region = proc_regionwithpathinfo()
        let result = withUnsafeMutablePointer(to: &region) { pointer in
            proc_pidinfo(
                getpid(),
                PROC_PIDREGIONPATHINFO,
                UInt64(UInt(bitPattern: header)),
                pointer,
                Int32(MemoryLayout<proc_regionwithpathinfo>.size)
            )
        }
        guard result == MemoryLayout<proc_regionwithpathinfo>.size else { return nil }
        let metadata = region.prp_vip.vip_vi.vi_stat
        guard metadata.vst_mode & S_IFMT == S_IFREG else { return nil }
        return Identity(
            device: UInt64(UInt32(truncatingIfNeeded: metadata.vst_dev)),
            inode: metadata.vst_ino
        )
    }
}
