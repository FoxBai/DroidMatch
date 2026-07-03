# 2026-07-03 03:58:28Z ADB Device Smoke

status: passed
date: 2026-07-03 03:58:28Z
device slot: D
manufacturer/model: NIO N2301
android version/api: Android 14 / API 34
build channel: local debug APK from git 3387dd4
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
visible time: device already authorized over USB before script start
first list time: 937 ms for `dm://app-sandbox/`
100MB download: not run
100MB upload: `upload` command passed to `dm://app-sandbox/dm-100mb-upload-zero.bin`; bytes 104857600 >= required 104857600
resume result: not run
cancel result: not run
pause result: not run
permission cases: launcher entry resolved to `DiagnosticsActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:58e1aad1>`
- remote port: `39001`
- local port: `60872`
- launcher: `app.droidmatch/app.droidmatch.m1.DiagnosticsActivity`
- m1-smoke failures: `0`
- timed list path: `dm://app-sandbox/`
- auto-prepared local 100MiB zero-file app-sandbox upload gate
- upload destination: `dm://app-sandbox/dm-100mb-upload-zero.bin`
- upload destination cleanup: scheduled on script exit
- min upload bytes: `104857600`
- observed upload bytes: `104857600`

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
TotalTime: 169
WaitTime: 171
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
[14/99] Compiling SwiftProtobuf BytecodeInterpreter.swift
[15/99] Compiling SwiftProtobuf BytecodeReader.swift
[16/99] Compiling SwiftProtobuf CustomJSONCodable.swift
[17/99] Compiling SwiftProtobuf Decoder.swift
[18/99] Compiling SwiftProtobuf DoubleParser.swift
[19/99] Compiling SwiftProtobuf Enum.swift
[20/99] Compiling SwiftProtobuf ExtensibleMessage.swift
[21/99] Compiling SwiftProtobuf ExtensionFieldValueSet.swift
[22/99] Compiling SwiftProtobuf ExtensionFields.swift
[23/99] Compiling SwiftProtobuf ExtensionMap.swift
[24/99] Compiling SwiftProtobuf FieldTag.swift
[25/99] Compiling SwiftProtobuf FieldTypes.swift
[26/99] Emitting module SwiftProtobuf
[27/99] Compiling SwiftProtobuf ProtoNameProviding.swift
[28/99] Compiling SwiftProtobuf ProtobufAPIVersionCheck.swift
[29/99] Compiling SwiftProtobuf ProtobufMap.swift
[30/99] Compiling SwiftProtobuf SelectiveVisitor.swift
[31/99] Compiling SwiftProtobuf SimpleExtensionMap.swift
[32/99] Compiling SwiftProtobuf StringUtils.swift
[33/99] Compiling SwiftProtobuf SwiftProtobufContiguousBytes.swift
[34/99] Compiling SwiftProtobuf SwiftProtobufError.swift
[35/99] Compiling SwiftProtobuf TextFormatDecoder.swift
[36/99] Compiling SwiftProtobuf TextFormatDecodingError.swift
[37/99] Compiling SwiftProtobuf TextFormatDecodingOptions.swift
[38/99] Compiling SwiftProtobuf TextFormatEncoder.swift
[39/99] Compiling SwiftProtobuf TextFormatEncodingOptions.swift
[40/99] Compiling SwiftProtobuf TextFormatEncodingVisitor.swift
[41/99] Compiling SwiftProtobuf TextFormatScanner.swift
[42/99] Compiling SwiftProtobuf TimeUtils.swift
[43/99] Compiling SwiftProtobuf UnknownStorage.swift
[44/99] Compiling SwiftProtobuf UnsafeRawPointer+Shims.swift
[45/99] Compiling SwiftProtobuf Varint.swift
[46/99] Compiling SwiftProtobuf Version.swift
[47/99] Compiling SwiftProtobuf Visitor.swift
[48/99] Compiling SwiftProtobuf WireFormat.swift
[49/99] Compiling SwiftProtobuf ZigZag.swift
[50/99] Compiling SwiftProtobuf any.pb.swift
[51/99] Compiling SwiftProtobuf JSONDecoder.swift
[52/99] Compiling SwiftProtobuf JSONDecodingError.swift
[53/99] Compiling SwiftProtobuf JSONDecodingOptions.swift
[54/99] Compiling SwiftProtobuf JSONEncoder.swift
[55/99] Compiling SwiftProtobuf JSONEncodingError.swift
[56/99] Compiling SwiftProtobuf JSONEncodingOptions.swift
[57/99] Compiling SwiftProtobuf JSONEncodingVisitor.swift
[58/99] Compiling SwiftProtobuf JSONMapEncodingVisitor.swift
[59/99] Compiling SwiftProtobuf JSONScanner.swift
[60/99] Compiling SwiftProtobuf MathUtils.swift
[61/99] Compiling SwiftProtobuf Message+AnyAdditions.swift
[62/99] Compiling SwiftProtobuf Message+BinaryAdditions.swift
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
Build of product 'droidmatch-harness' complete! (4.61s)
serial=<serial-redacted:58e1aad1> local_port=60872 remote_port=39001
```

## M1 Smoke Output

```text
## attempt 1/1 passed
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
m1 smoke passed server=DroidMatchAndroid device="NIO N2301" sdk=34 battery=100 heartbeat_ms=279783408 roots=3 service_state=rpc.session.open events=8 errors=0
```

## Timed ListDir Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
list-dir passed path=dm://app-sandbox/ entries=0 next_page_token=<none>
```

## Upload Output

```text
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'droidmatch-harness' complete! (0.18s)
upload passed transfer_id=01016AE7-4BAD-46BA-A366-9219D65D29C6 chunks=400 bytes=104857600 total=104857600 final_offset=104857600 source=<upload-source> destination=dm://app-sandbox/dm-100mb-upload-zero.bin
```
