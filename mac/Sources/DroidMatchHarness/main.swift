import DroidMatchCore
import Foundation

enum HarnessCommand {
    static func run(arguments: [String]) -> Int32 {
        let command = arguments.dropFirst().first ?? "help"

        switch command {
        case "adb-path":
            print(AdbClient.defaultAdbPath())
            return 0
        case "devices":
            return listDevices()
        case "frame-self-test":
            return frameSelfTest()
        case "help", "--help", "-h":
            printHelp()
            return 0
        default:
            fputs("unknown command: \(command)\n", stderr)
            printHelp()
            return 2
        }
    }

    private static func listDevices() -> Int32 {
        do {
            let client = AdbClient()
            let devices = try client.devices()
            if devices.isEmpty {
                print("no adb devices visible")
            } else {
                for device in devices {
                    let model = device.model.map { " model=\($0)" } ?? ""
                    print("\(device.serial) \(device.state)\(model)")
                }
            }
            return 0
        } catch {
            fputs("adb devices failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func frameSelfTest() -> Int32 {
        do {
            let payload = Data("droidmatch-frame-self-test".utf8)
            let codec = FrameCodec()
            var frame = try codec.encode(payload: payload)
            guard let decoded = try codec.decodeNext(from: &frame), decoded == payload, frame.isEmpty else {
                fputs("frame self-test failed\n", stderr)
                return 1
            }
            print("frame self-test passed crc32=\(String(Crc32.checksum(payload), radix: 16))")
            return 0
        } catch {
            fputs("frame self-test failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func printHelp() {
        print(
            """
            droidmatch-harness commands:
              adb-path          Print the adb executable selected by the harness.
              devices           List adb-visible devices.
              frame-self-test   Verify length-prefixed frame encode/decode.
            """
        )
    }
}

exit(HarnessCommand.run(arguments: CommandLine.arguments))
