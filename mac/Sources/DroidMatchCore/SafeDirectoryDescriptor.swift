import Darwin
import Foundation

package enum SafeDirectoryDescriptorError: Error, Sendable, Equatable {
    case invalidAbsolutePath
    case unsafeComponent
}

/// Opens an absolute directory one component at a time without ever following
/// a symbolic link. Every next component is resolved relative to the already
/// pinned descriptor, closing ancestor-rebinding races during traversal.
package enum SafeDirectoryDescriptor {
    package static func openAbsolute(
        _ url: URL,
        createIntermediateDirectories: Bool = false,
        creationMode: mode_t = 0o777
    ) throws -> Int32 {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.utf8.contains(0) else {
            throw SafeDirectoryDescriptorError.invalidAbsolutePath
        }
        let components = canonicalSystemAliasURL(url).pathComponents
        guard components.first == "/" else {
            throw SafeDirectoryDescriptorError.invalidAbsolutePath
        }

        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        do {
            for component in components.dropFirst() {
                guard !component.isEmpty,
                      component != ".",
                      component != "..",
                      !component.utf8.contains(0),
                      !component.contains("/") else {
                    throw SafeDirectoryDescriptorError.invalidAbsolutePath
                }
                var next = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                if next < 0, errno == ENOENT, createIntermediateDirectories {
                    let createStatus = component.withCString {
                        Darwin.mkdirat(descriptor, $0, creationMode)
                    }
                    if createStatus != 0, errno != EEXIST {
                        throw currentPOSIXError()
                    }
                    next = component.withCString {
                        Darwin.openat(
                            descriptor,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                }
                guard next >= 0 else {
                    if errno == ELOOP || errno == ENOTDIR {
                        throw SafeDirectoryDescriptorError.unsafeComponent
                    }
                    throw currentPOSIXError()
                }
                Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Darwin exposes these root-level compatibility aliases on every normal
    /// macOS installation. Resolve only this immutable system allowlist; user
    /// and volume symlinks remain rejected component by component.
    package static func canonicalSystemAliasURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        for (alias, target) in [
            ("/var", "/private/var"),
            ("/tmp", "/private/tmp"),
            ("/etc", "/private/etc"),
        ] where path == alias || path.hasPrefix(alias + "/") {
            return URL(fileURLWithPath: target + path.dropFirst(alias.count))
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
