import DroidMatchCore
import Foundation

/// Shared command-line contract for the device harness.
///
/// Keeping parsing and user-facing failures separate from probe execution makes
/// command additions reviewable without touching transport behavior.
enum HarnessError: Error, CustomStringConvertible {
    case missingOption(String)
    case missingOptionValue(String)
    case invalidInt(option: String, value: String)
    case invalidUInt32(option: String, value: String)
    case invalidDouble(option: String, value: String)
    case invalidHex(String)
    case noReadyDevice
    case multipleReadyDevices([String])
    case invalidOptionCombination(String)
    case missingResumeRecord(String)
    case partialDownloadStopped(bytesWritten: Int64, partialPath: String, sidecarPath: String)
    case partialUploadStopped(bytesSent: Int64, sidecarPath: String)
    case resumeSourceMismatch(expected: String, actual: String)
    case resumeDestinationMismatch(expected: String, actual: String)
    case resumeSourceChanged(String)
    case resumeOffsetRejected(requested: Int64, accepted: Int64)
    case localFileSizeUnavailable(String)
    case transferDidNotComplete(String)
    case invalidErrorCode(String)
    case expectedDownloadOpenErrorNotReceived(String)
    case expectedRemoteOpenErrorNotReceived(String)
    case expectedListDirErrorNotReceived(String)
    case unexpectedRemoteErrorCode(
        expected: Droidmatch_V1_ErrorCode,
        actual: Droidmatch_V1_ErrorCode,
        message: String
    )
    case unexpectedRemoteErrorMessage(expectedSubstring: String, actual: String)

    var description: String {
        switch self {
        case let .missingOption(option):
            return "missing required option \(option)"
        case let .missingOptionValue(option):
            return "missing value for option \(option)"
        case let .invalidInt(option, value):
            return "invalid integer for \(option): \(value)"
        case let .invalidUInt32(option, value):
            return "invalid uint32 for \(option): \(value)"
        case let .invalidDouble(option, value):
            return "invalid number for \(option): \(value)"
        case let .invalidHex(value):
            return "invalid hex payload: \(value)"
        case .noReadyDevice:
            return "no adb device in device state; pass --serial after authorizing one"
        case let .multipleReadyDevices(serials):
            return "multiple adb devices are ready (\(serials.joined(separator: ", "))); pass --serial"
        case let .invalidOptionCombination(message):
            return message
        case let .missingResumeRecord(path):
            return "cannot resume without resume metadata sidecar: \(path)"
        case let .partialDownloadStopped(bytesWritten, partialPath, sidecarPath):
            return "partial download stopped after \(bytesWritten) bytes; partial=\(partialPath) sidecar=\(sidecarPath)"
        case let .partialUploadStopped(bytesSent, sidecarPath):
            return "partial upload stopped after \(bytesSent) bytes; sidecar=\(sidecarPath)"
        case let .resumeSourceMismatch(expected, actual):
            return "resume metadata source_path mismatch: expected \(expected), got \(actual)"
        case let .resumeDestinationMismatch(expected, actual):
            return "resume metadata destination_path mismatch: expected \(expected), got \(actual)"
        case let .resumeSourceChanged(path):
            return "resume metadata source file changed: \(path)"
        case let .resumeOffsetRejected(requested, accepted):
            return "remote rejected resume offset: requested \(requested), accepted \(accepted)"
        case let .localFileSizeUnavailable(path):
            return "could not determine local file size: \(path)"
        case let .transferDidNotComplete(direction):
            return "\(direction) did not complete"
        case let .invalidErrorCode(value):
            return "invalid error code: \(value)"
        case let .expectedDownloadOpenErrorNotReceived(sourcePath):
            return "remote accepted download open unexpectedly for \(sourcePath)"
        case let .expectedRemoteOpenErrorNotReceived(destinationPath):
            return "remote accepted upload open unexpectedly for \(destinationPath)"
        case let .expectedListDirErrorNotReceived(path):
            return "remote returned list-dir success unexpectedly for \(path)"
        case let .unexpectedRemoteErrorCode(expected, actual, message):
            return "expected remote error \(expected), got \(actual): \(message)"
        case let .unexpectedRemoteErrorMessage(expectedSubstring, actual):
            return "expected remote error message to contain \"\(expectedSubstring)\", got \"\(actual)\""
        }
    }
}

struct CommandOptions {
    private let values: [String: String]
    private let flags: Set<String>

    init(_ arguments: [String]) throws {
        var parsed: [String: String] = [:]
        var parsedFlags = Set<String>()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--") else {
                throw HarnessError.missingOption(option)
            }
            let valueIndex = index + 1
            if valueIndex >= arguments.count || arguments[valueIndex].hasPrefix("--") {
                parsedFlags.insert(option)
                index += 1
            } else {
                parsed[option] = arguments[valueIndex]
                index += 2
            }
        }
        values = parsed
        flags = parsedFlags
    }

    func value(_ option: String) throws -> String? {
        values[option]
    }

    func flag(_ option: String) -> Bool {
        flags.contains(option)
    }

    func requiredValue(_ option: String) throws -> String {
        guard let rawValue = values[option] else {
            throw HarnessError.missingOption(option)
        }
        return rawValue
    }

    func requiredInt(_ option: String) throws -> Int {
        guard let rawValue = values[option] else {
            throw HarnessError.missingOption(option)
        }
        guard let value = Int(rawValue) else {
            throw HarnessError.invalidInt(option: option, value: rawValue)
        }
        return value
    }

    func int(_ option: String) throws -> Int? {
        guard let rawValue = values[option] else {
            return nil
        }
        guard let value = Int(rawValue) else {
            throw HarnessError.invalidInt(option: option, value: rawValue)
        }
        return value
    }

    func uint32(_ option: String) throws -> UInt32? {
        guard let rawValue = values[option] else {
            return nil
        }
        guard let value = UInt32(rawValue) else {
            throw HarnessError.invalidUInt32(option: option, value: rawValue)
        }
        return value
    }

    func double(_ option: String) throws -> Double? {
        guard let rawValue = values[option] else {
            return nil
        }
        guard let value = Double(rawValue) else {
            throw HarnessError.invalidDouble(option: option, value: rawValue)
        }
        return value
    }
}

