# 2026-07-03 04:16:06Z ADB Device Smoke

status: passed
date: 2026-07-03 04:16:06Z
device slot: D
manufacturer/model: NIO N2301
android version/api: Android 14 / API 34
build channel: local debug APK from git 62f7ade
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
visible time: device already authorized over USB before script start
first list time: 946 ms for `dm://app-sandbox/`
100MB download: not run
100MB upload: partial upload plus resume passed to `dm://app-sandbox/dm-1mb-upload-resume-zero.bin`; bytes 1048576 >= required 1048576
resume result: not run
cancel result: not run
pause result: not run
permission cases: launcher entry resolved to `DiagnosticsActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:58e1aad1>`
- remote port: `39001`
- local port: `62114`
- launcher: `app.droidmatch/app.droidmatch.m1.DiagnosticsActivity`
- m1-smoke failures: `0`
- timed list path: `dm://app-sandbox/`
- auto-prepared local 1MiB zero-file app-sandbox upload resume smoke
- upload destination: `dm://app-sandbox/dm-1mb-upload-resume-zero.bin`
- upload partial bytes: `1`
- upload destination cleanup: scheduled on script exit
- min upload bytes: `1048576`
- observed upload bytes: `1048576`

## Install Output

```text
Performing Streamed Install
Success
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
TotalTime: 178
WaitTime: 181
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
[14/99] Compiling SwiftProtobuf Google_Protobuf_Any+Extensions.swift
[15/99] Compiling SwiftProtobuf Google_Protobuf_Any+Registry.swift
[16/99] Compiling SwiftProtobuf Google_Protobuf_Duration+Extensions.swift
[17/99] Compiling SwiftProtobuf Google_Protobuf_FieldMask+Extensions.swift
[18/99] Compiling SwiftProtobuf Google_Protobuf_ListValue+Extensions.swift
[19/99] Compiling SwiftProtobuf Google_Protobuf_NullValue+Extensions.swift
[20/99] Compiling SwiftProtobuf Google_Protobuf_Struct+Extensions.swift
[21/99] Compiling SwiftProtobuf Google_Protobuf_Timestamp+Extensions.swift
[22/99] Compiling SwiftProtobuf Google_Protobuf_Value+Extensions.swift
[23/99] Compiling SwiftProtobuf Google_Protobuf_Wrappers+Extensions.swift
[24/99] Compiling SwiftProtobuf HashVisitor.swift
[25/99] Compiling SwiftProtobuf Internal.swift
[26/99] Compiling SwiftProtobuf JSONDecoder.swift
[27/99] Compiling SwiftProtobuf JSONDecodingError.swift
[28/99] Compiling SwiftProtobuf JSONDecodingOptions.swift
[29/99] Compiling SwiftProtobuf JSONEncoder.swift
[30/99] Compiling SwiftProtobuf JSONEncodingError.swift
[31/99] Compiling SwiftProtobuf JSONEncodingOptions.swift
[32/99] Compiling SwiftProtobuf JSONEncodingVisitor.swift
[33/99] Compiling SwiftProtobuf JSONMapEncodingVisitor.swift
[34/99] Compiling SwiftProtobuf JSONScanner.swift
[35/99] Compiling SwiftProtobuf MathUtils.swift
[36/99] Compiling SwiftProtobuf Message+AnyAdditions.swift
[37/99] Compiling SwiftProtobuf Message+BinaryAdditions.swift
[38/99] Compiling SwiftProtobuf BytecodeInterpreter.swift
[39/99] Compiling SwiftProtobuf BytecodeReader.swift
[40/99] Compiling SwiftProtobuf CustomJSONCodable.swift
[41/99] Compiling SwiftProtobuf Decoder.swift
[42/99] Compiling SwiftProtobuf DoubleParser.swift
[43/99] Compiling SwiftProtobuf Enum.swift
[44/99] Compiling SwiftProtobuf ExtensibleMessage.swift
[45/99] Compiling SwiftProtobuf ExtensionFieldValueSet.swift
[46/99] Compiling SwiftProtobuf ExtensionFields.swift
[47/99] Compiling SwiftProtobuf ExtensionMap.swift
[48/99] Compiling SwiftProtobuf FieldTag.swift
[49/99] Compiling SwiftProtobuf FieldTypes.swift
[50/99] Emitting module SwiftProtobuf
[51/99] Compiling SwiftProtobuf ProtoNameProviding.swift
[52/99] Compiling SwiftProtobuf ProtobufAPIVersionCheck.swift
[53/99] Compiling SwiftProtobuf ProtobufMap.swift
[54/99] Compiling SwiftProtobuf SelectiveVisitor.swift
[55/99] Compiling SwiftProtobuf SimpleExtensionMap.swift
[56/99] Compiling SwiftProtobuf StringUtils.swift
[57/99] Compiling SwiftProtobuf SwiftProtobufContiguousBytes.swift
[58/99] Compiling SwiftProtobuf SwiftProtobufError.swift
[59/99] Compiling SwiftProtobuf TextFormatDecoder.swift
[60/99] Compiling SwiftProtobuf TextFormatDecodingError.swift
[61/99] Compiling SwiftProtobuf TextFormatDecodingOptions.swift
[62/99] Compiling SwiftProtobuf TextFormatEncoder.swift
[63/99] Compiling SwiftProtobuf TextFormatEncodingOptions.swift
[64/99] Compiling SwiftProtobuf TextFormatEncodingVisitor.swift
[65/99] Compiling SwiftProtobuf TextFormatScanner.swift
[66/99] Compiling SwiftProtobuf TimeUtils.swift
[67/99] Compiling SwiftProtobuf UnknownStorage.swift
[68/99] Compiling SwiftProtobuf UnsafeRawPointer+Shims.swift
[69/99] Compiling SwiftProtobuf Varint.swift
[70/99] Compiling SwiftProtobuf Version.swift
[71/99] Compiling SwiftProtobuf Visitor.swift
[72/99] Compiling SwiftProtobuf WireFormat.swift
[73/99] Compiling SwiftProtobuf ZigZag.swift
[74/99] Compiling SwiftProtobuf any.pb.swift
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
Build of product 'droidmatch-harness' complete! (4.68s)
serial=<serial-redacted:58e1aad1> local_port=62114 remote_port=39001
```

## M1 Smoke Output

```text
## attempt 1/1 passed
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
m1 smoke passed server=DroidMatchAndroid device="NIO N2301" sdk=34 battery=100 heartbeat_ms=280840864 roots=3 service_state=rpc.session.open events=8 errors=0
```

## Timed ListDir Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
list-dir passed path=dm://app-sandbox/ entries=0 next_page_token=<none>
```

## Partial Upload Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
upload partial passed bytes=1 sidecar=<upload-source>.droidmatch-upload-transfer.json
```

## Resume Upload Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
upload passed transfer_id=FEB27666-44F6-47FF-ADEC-E3C35E172527 chunks=4 bytes=1048575 total=1048576 final_offset=1048576 resume=true source=<upload-source> destination=dm://app-sandbox/dm-1mb-upload-resume-zero.bin
```
