import Foundation

enum HarnessHelp {
    static func printUsage() {
        print(
            """
                        droidmatch-harness commands:
                          adb-path              Print the adb executable selected by the harness.
                          devices               List adb-visible devices.
                          forward               Create an adb forward to an Android endpoint.
                          framed-echo           Send one length-prefixed frame and require the same frame back.
                          handshake-smoke       Send ClientHello and require ServerHello.
                          m1-smoke              Run handshake, heartbeat, device info, root listing, and diagnostics on one connection.
                          dual-download-smoke   Keep two downloads active, route interleaved chunks, and prove heartbeat responsiveness.
                          mixed-transfer-smoke  Verify heartbeat with download/upload open, then complete both on one async session.
                          list-dir              Handshake, then run ListDirRequest for a logical DroidMatch path.
                          list-dir-all          Exhaust opaque pagination and verify aggregate entry identity/count.
                          list-dir-expect-error
                                                Handshake, run ListDirRequest, and require a response error.
                          delete-path           Handshake, then delete one logical path (use --recursive for directories).
                          download-open-expect-error
                                                Handshake, open a download, and require a remote open error.
                          download-once         Handshake, open a download transfer, read one chunk, and ack it.
                          download-cancel       Handshake, open a download transfer, read one chunk, then cancel it.
                          download-pause        Handshake, open a download transfer, read one chunk, then pause it.
                          download              Handshake, download all chunks for one logical DroidMatch path.
                          upload                Handshake, upload one local file to a logical DroidMatch path.
                          upload-open-expect-error
                                                Handshake, open an upload with a requested offset, and require a remote error.
                          frame-self-test       Verify local length-prefixed frame encode/decode.
                        \(String())
                        examples:
                          droidmatch-harness forward --serial ABC123 --remote-port 39001
                          droidmatch-harness framed-echo --port 49152 --payload hello
                          droidmatch-harness handshake-smoke --port 49152
                          droidmatch-harness m1-smoke --port 49152
                          droidmatch-harness dual-download-smoke --port 49152 --source-path-a dm://app-sandbox/a.bin --source-path-b dm://app-sandbox/b.bin
                          droidmatch-harness mixed-transfer-smoke --port 49152 --download-source-path dm://app-sandbox/a.bin --download-destination /tmp/a.bin --upload-source /tmp/b.bin --upload-destination-path dm://app-sandbox/b.bin
                          droidmatch-harness list-dir --port 49152 --path dm://media-images/
                          droidmatch-harness list-dir-all --port 49152 --path dm://app-sandbox/stress/ --page-size 1000 --expected-total 1005
                          droidmatch-harness list-dir-expect-error --port 49152 --path dm://saf-missing/ --expected-error-code notFound
                          droidmatch-harness delete-path --port 49152 --path dm://saf-abc123/photo.jpg
                          droidmatch-harness download-open-expect-error --port 49152 --source-path dm://app-sandbox/missing.bin --expected-error-code notFound
                          droidmatch-harness download-once --port 49152 --source-path dm://media-images/media/42
                          droidmatch-harness download-cancel --port 49152 --source-path dm://media-images/media/42
                          droidmatch-harness download-pause --port 49152 --source-path dm://media-images/media/42
                          droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg
                          droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg --stop-after-bytes 1
                          droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg --resume
                          droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg --retry-on-transport-loss
                          droidmatch-harness download --port 49152 --source-path dm://media-images/media/42 --destination /tmp/photo.jpg --retry-on-transport-loss --max-retry-attempts 3 --retry-backoff-ms 500
                          droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg
                          droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg --stop-after-bytes 1
                          droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg --resume
                          droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg --retry-on-transport-loss
                          droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://app-sandbox/photo.jpg --retry-on-transport-loss --max-retry-attempts 3 --retry-backoff-ms 500
                          droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://media-images/photo.jpg
                          droidmatch-harness upload-open-expect-error --port 49152 --source /tmp/photo.jpg --destination-path dm://media-images/photo.jpg --requested-offset 1 --expected-error-code unsupportedCapability
                          droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://saf-abc123/photo.jpg --stop-after-bytes 1
                          droidmatch-harness upload --port 49152 --source /tmp/photo.jpg --destination-path dm://saf-abc123/photo.jpg --resume
                        """
        )
    }
}
