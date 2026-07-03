# 2026-07-03 03:16:23Z ADB Device Smoke

status: passed
date: 2026-07-03 03:16:23Z
device slot: D
manufacturer/model: NIO N2301
android version/api: Android 14 / API 34
build channel: local debug APK from git dfda3cd
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
visible time: device already authorized over USB before script start
first list time: 966 ms for `dm://app-sandbox/`
100MB download: pause-check passed for `dm://app-sandbox/dm-1mb-pause-zero.bin`; 100MB size not asserted
100MB upload: not implemented
resume result: not run
cancel result: not run
pause result: `download-pause` passed after the first chunk for `dm://app-sandbox/dm-1mb-pause-zero.bin`
permission cases: launcher entry resolved to `DiagnosticsActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:58e1aad1>`
- remote port: `39001`
- local port: `59040`
- launcher: `app.droidmatch/app.droidmatch.m1.DiagnosticsActivity`
- m1-smoke failures: `0`
- timed list path: `dm://app-sandbox/`
- auto-prepared app-sandbox 1MiB zero-file download-pause smoke
- prepared app sandbox file: `dm-1mb-pause-zero.bin`
- prepared app sandbox bytes: `1048576`
- prepared app sandbox cleanup: scheduled on script exit

## Install Output

```text
Performing Streamed Install
Success
```

## Prepare App Sandbox Output

```text
mkdir:

dd:
1+0 records in
1+0 records out
1048576 bytes (1.0 M) copied, 0.001 s, 0.9 G/s
verify:
-rw-rw-rw- 1 u0_a220 u0_a220 1048576 2026-07-03 11:16 files/droidmatch-sandbox/dm-1mb-pause-zero.bin
```

## Launcher Resolve Output

```text
priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false
app.droidmatch/.m1.DiagnosticsActivity
```

## Activity Start Output

```text
Starting: Intent { cmp=app.droidmatch/.m1.DebugHarnessActivity (has extras) }
Status: ok
LaunchState: COLD
Activity: app.droidmatch/.m1.DebugHarnessActivity
TotalTime: 175
WaitTime: 178
Complete
```

## Forward Output

```text
[0/1] Planning build
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
[2/88] Compiling SwiftProtobuf Message+BinaryAdditions_Data.swift
[3/88] Compiling SwiftProtobuf Message+FieldMask.swift
[4/88] Compiling SwiftProtobuf Message+JSONAdditions.swift
[5/88] Compiling SwiftProtobuf Message+JSONAdditions_Data.swift
[6/88] Compiling SwiftProtobuf Message+JSONArrayAdditions.swift
[7/88] Compiling SwiftProtobuf Message+JSONArrayAdditions_Data.swift
[8/88] Compiling SwiftProtobuf Message+TextFormatAdditions.swift
[9/88] Compiling SwiftProtobuf Message.swift
[10/88] Compiling SwiftProtobuf MessageExtension.swift
[11/88] Compiling SwiftProtobuf NameMap.swift
[12/88] Compiling SwiftProtobuf PathDecoder.swift
[13/88] Compiling SwiftProtobuf PathVisitor.swift
[14/88] Compiling SwiftProtobuf BytecodeInterpreter.swift
[15/88] Compiling SwiftProtobuf BytecodeReader.swift
[16/88] Compiling SwiftProtobuf CustomJSONCodable.swift
[17/88] Compiling SwiftProtobuf Decoder.swift
[18/88] Compiling SwiftProtobuf DoubleParser.swift
[19/88] Compiling SwiftProtobuf Enum.swift
[20/88] Compiling SwiftProtobuf ExtensibleMessage.swift
[21/88] Compiling SwiftProtobuf ExtensionFieldValueSet.swift
[22/88] Compiling SwiftProtobuf ExtensionFields.swift
[23/88] Compiling SwiftProtobuf ExtensionMap.swift
[24/88] Compiling SwiftProtobuf FieldTag.swift
[25/88] Compiling SwiftProtobuf FieldTypes.swift
[26/99] Compiling SwiftProtobuf ProtoNameProviding.swift
[27/99] Compiling SwiftProtobuf ProtobufAPIVersionCheck.swift
[28/99] Compiling SwiftProtobuf ProtobufMap.swift
[29/99] Compiling SwiftProtobuf SelectiveVisitor.swift
[30/99] Compiling SwiftProtobuf SimpleExtensionMap.swift
[31/99] Compiling SwiftProtobuf StringUtils.swift
[32/99] Compiling SwiftProtobuf SwiftProtobufContiguousBytes.swift
[33/99] Compiling SwiftProtobuf SwiftProtobufError.swift
[34/99] Compiling SwiftProtobuf TextFormatDecoder.swift
[35/99] Compiling SwiftProtobuf TextFormatDecodingError.swift
[36/99] Compiling SwiftProtobuf TextFormatDecodingOptions.swift
[37/99] Compiling SwiftProtobuf TextFormatEncoder.swift
[38/99] Emitting module SwiftProtobuf
[39/99] Compiling SwiftProtobuf JSONDecoder.swift
[40/99] Compiling SwiftProtobuf JSONDecodingError.swift
[41/99] Compiling SwiftProtobuf JSONDecodingOptions.swift
[42/99] Compiling SwiftProtobuf JSONEncoder.swift
[43/99] Compiling SwiftProtobuf JSONEncodingError.swift
[44/99] Compiling SwiftProtobuf JSONEncodingOptions.swift
[45/99] Compiling SwiftProtobuf JSONEncodingVisitor.swift
[46/99] Compiling SwiftProtobuf JSONMapEncodingVisitor.swift
[47/99] Compiling SwiftProtobuf JSONScanner.swift
[48/99] Compiling SwiftProtobuf MathUtils.swift
[49/99] Compiling SwiftProtobuf Message+AnyAdditions.swift
[50/99] Compiling SwiftProtobuf Message+BinaryAdditions.swift
[51/99] Compiling SwiftProtobuf TextFormatEncodingOptions.swift
[52/99] Compiling SwiftProtobuf TextFormatEncodingVisitor.swift
[53/99] Compiling SwiftProtobuf TextFormatScanner.swift
[54/99] Compiling SwiftProtobuf TimeUtils.swift
[55/99] Compiling SwiftProtobuf UnknownStorage.swift
[56/99] Compiling SwiftProtobuf UnsafeRawPointer+Shims.swift
[57/99] Compiling SwiftProtobuf Varint.swift
[58/99] Compiling SwiftProtobuf Version.swift
[59/99] Compiling SwiftProtobuf Visitor.swift
[60/99] Compiling SwiftProtobuf WireFormat.swift
[61/99] Compiling SwiftProtobuf ZigZag.swift
[62/99] Compiling SwiftProtobuf any.pb.swift
[63/99] Compiling SwiftProtobuf Google_Protobuf_Any+Extensions.swift
[64/99] Compiling SwiftProtobuf Google_Protobuf_Any+Registry.swift
[65/99] Compiling SwiftProtobuf Google_Protobuf_Duration+Extensions.swift
[66/99] Compiling SwiftProtobuf Google_Protobuf_FieldMask+Extensions.swift
[67/99] Compiling SwiftProtobuf Google_Protobuf_ListValue+Extensions.swift
[68/99] Compiling SwiftProtobuf Google_Protobuf_NullValue+Extensions.swift
[69/99] Compiling SwiftProtobuf Google_Protobuf_Struct+Extensions.swift
[70/99] Compiling SwiftProtobuf Google_Protobuf_Timestamp+Extensions.swift
[71/99] Compiling SwiftProtobuf Google_Protobuf_Value+Extensions.swift
[72/99] Compiling SwiftProtobuf Google_Protobuf_Wrappers+Extensions.swift
[73/99] Compiling SwiftProtobuf HashVisitor.swift
[74/99] Compiling SwiftProtobuf Internal.swift
[75/99] Compiling SwiftProtobuf AnyMessageStorage.swift
[76/99] Compiling SwiftProtobuf AnyUnpackError.swift
[77/99] Compiling SwiftProtobuf AsyncMessageSequence.swift
[78/99] Compiling SwiftProtobuf BinaryDecoder.swift
[79/99] Compiling SwiftProtobuf BinaryDecodingError.swift
[80/99] Compiling SwiftProtobuf BinaryDecodingOptions.swift
[81/99] Compiling SwiftProtobuf BinaryDelimited.swift
[82/99] Compiling SwiftProtobuf BinaryEncoder.swift
[83/99] Compiling SwiftProtobuf BinaryEncodingError.swift
[84/99] Compiling SwiftProtobuf BinaryEncodingOptions.swift
[85/99] Compiling SwiftProtobuf BinaryEncodingSizeVisitor.swift
[86/99] Compiling SwiftProtobuf BinaryEncodingVisitor.swift
[87/99] Compiling SwiftProtobuf api.pb.swift
[88/99] Compiling SwiftProtobuf descriptor.pb.swift
[89/99] Compiling SwiftProtobuf duration.pb.swift
[90/99] Compiling SwiftProtobuf empty.pb.swift
[91/99] Compiling SwiftProtobuf field_mask.pb.swift
[92/99] Compiling SwiftProtobuf source_context.pb.swift
[93/99] Compiling SwiftProtobuf struct.pb.swift
[94/99] Compiling SwiftProtobuf timestamp.pb.swift
[95/99] Compiling SwiftProtobuf type.pb.swift
[96/99] Compiling SwiftProtobuf wrappers.pb.swift
[97/99] Compiling SwiftProtobuf resource_bundle_accessor.swift
Build of product 'droidmatch-harness' complete! (5.10s)
serial=<serial-redacted:58e1aad1> local_port=59040 remote_port=39001
```

## M1 Smoke Output

```text
## attempt 1/1 passed
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
m1 smoke passed server=DroidMatchAndroid device="NIO N2301" sdk=34 battery=100 heartbeat_ms=277259373 roots=3 service_state=rpc.session.open events=8 errors=0
```

## Timed ListDir Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
list-dir passed path=dm://app-sandbox/ entries=1 next_page_token=<none>
entries redacted: 1
```

## Pause Download Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
download-pause passed transfer_id=1488C64E-3961-4BAD-89AF-A21CC3C4C551 first_chunk_bytes=262144 total=1048576 pause_ok=true resumable_offset=262144
```
