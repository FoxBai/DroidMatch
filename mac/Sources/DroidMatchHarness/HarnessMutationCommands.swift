import DroidMatchCore
import Foundation

extension HarnessCommand {
    /// Deletes one logical path through a fresh product protocol session.
    ///
    /// The device smoke runner uses this command for direct-root SAF cleanup:
    /// the path is stable across sessions, while nested SAF document tokens are
    /// intentionally left to the session that created them.
    static func deletePath(_ arguments: [String]) async -> Int32 {
        do {
            let options = try CommandOptions(arguments)
            let host = try options.value("--host") ?? "127.0.0.1"
            let port = try options.requiredInt("--port")
            let timeout = try options.positiveFiniteDouble("--timeout-seconds") ?? 5
            let path = try options.requiredValue("--path")
            let recursive = options.flag("--recursive")

            return try await withAsyncControlClient(
                host: host,
                port: port,
                timeout: timeout
            ) { client in
                _ = try await client.handshake()
                try await client.deletePath(path, recursive: recursive)
                print(
                    "delete-path passed path=\(HarnessPrivacy.redactedPath) "
                        + "recursive=\(recursive)"
                )
                return 0
            }
        } catch {
            fputs("delete-path failed: \(HarnessPrivacy.errorLabel(error))\n", stderr)
            return 1
        }
    }
}
