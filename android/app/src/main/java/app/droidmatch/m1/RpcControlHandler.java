package app.droidmatch.m1;

import app.droidmatch.proto.v1.CreateDirectoryRequest;
import app.droidmatch.proto.v1.DeletePathRequest;
import app.droidmatch.proto.v1.DeviceInfoRequest;
import app.droidmatch.proto.v1.DiagnosticsRequest;
import app.droidmatch.proto.v1.DiagnosticsResponse;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileMutationResponse;
import app.droidmatch.proto.v1.HeartbeatRequest;
import app.droidmatch.proto.v1.HeartbeatResponse;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RenamePathRequest;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.ThumbnailRequest;
import app.droidmatch.proto.v1.ThumbnailResponse;
import app.droidmatch.proto.v1.TransportKind;
import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;

import java.util.Map;

/**
 * Executes non-authentication control requests after dispatcher admission.
 * Envelope shape, session phase, capability checks, socket lifetime, and
 * transfer state intentionally remain in {@link RpcDispatcher}.
 *
 * <p>中文：只执行已通过 envelope、会话阶段与 capability 准入的控制请求；
 * 不拥有认证、传输状态或 socket 生命周期。</p>
 */
final class RpcControlHandler {
    private final DiagnosticsReporter diagnosticsReporter;
    private final DmFileProvider fileProvider;
    private final AndroidDeviceInfoProvider deviceInfoProvider;

    RpcControlHandler(
            DiagnosticsReporter diagnosticsReporter,
            DmFileProvider fileProvider,
            AndroidDeviceInfoProvider deviceInfoProvider
    ) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.fileProvider = fileProvider;
        this.deviceInfoProvider = deviceInfoProvider;
    }

    RpcDispatcher.DispatchResult deviceInfo(RpcEnvelope request) {
        try {
            DeviceInfoRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.device_info.invalid", exception);
            return protocolError(request, "DeviceInfoRequest payload is invalid");
        }
        diagnosticsReporter.recordCounter("rpc.device_info.requests", 1);
        return response(request, PayloadType.PAYLOAD_TYPE_DEVICE_INFO_RESPONSE,
                deviceInfoProvider.snapshot().toByteString());
    }

    RpcDispatcher.DispatchResult heartbeat(RpcEnvelope request) {
        HeartbeatRequest payload;
        try {
            payload = HeartbeatRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.heartbeat.invalid", exception);
            return protocolError(request, "HeartbeatRequest payload is invalid");
        }
        diagnosticsReporter.recordCounter("rpc.heartbeat.requests", 1);
        HeartbeatResponse result = HeartbeatResponse.newBuilder()
                .setMonotonicMillis(payload.getMonotonicMillis()).build();
        return response(request, PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE, result.toByteString());
    }

    RpcDispatcher.DispatchResult listDir(RpcEnvelope request) {
        ListDirRequest payload;
        try {
            payload = ListDirRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.list_dir.invalid", exception);
            return protocolError(request, "ListDirRequest payload is invalid");
        }
        diagnosticsReporter.recordCounter("rpc.list_dir.requests", 1);
        ListDirResponse result = fileProvider.listDir(payload);
        return response(request, PayloadType.PAYLOAD_TYPE_LIST_DIR_RESPONSE, result.toByteString());
    }

    RpcDispatcher.DispatchResult createDirectory(RpcEnvelope request) {
        CreateDirectoryRequest payload;
        try {
            payload = CreateDirectoryRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.create_directory.invalid", exception);
            return protocolError(request, "CreateDirectoryRequest payload is invalid");
        }
        diagnosticsReporter.recordCounter("rpc.create_directory.requests", 1);
        return mutation(request, fileProvider.createDirectory(payload.getPath()));
    }

    RpcDispatcher.DispatchResult renamePath(RpcEnvelope request) {
        RenamePathRequest payload;
        try {
            payload = RenamePathRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.rename_path.invalid", exception);
            return protocolError(request, "RenamePathRequest payload is invalid");
        }
        diagnosticsReporter.recordCounter("rpc.rename_path.requests", 1);
        return mutation(request, fileProvider.renamePath(
                payload.getSourcePath(), payload.getDestinationPath()));
    }

    RpcDispatcher.DispatchResult deletePath(RpcEnvelope request) {
        DeletePathRequest payload;
        try {
            payload = DeletePathRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.delete_path.invalid", exception);
            return protocolError(request, "DeletePathRequest payload is invalid");
        }
        diagnosticsReporter.recordCounter("rpc.delete_path.requests", 1);
        return mutation(request, fileProvider.deletePath(payload.getPath(), payload.getRecursive()));
    }

    RpcDispatcher.DispatchResult thumbnail(RpcEnvelope request) {
        ThumbnailRequest payload;
        try {
            payload = ThumbnailRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.thumbnail.invalid", exception);
            return protocolError(request, "ThumbnailRequest payload is invalid");
        }
        diagnosticsReporter.recordCounter("rpc.thumbnail.requests", 1);
        ThumbnailResponse result = fileProvider.thumbnail(payload);
        return response(request, PayloadType.PAYLOAD_TYPE_THUMBNAIL_RESPONSE, result.toByteString());
    }

    RpcDispatcher.DispatchResult diagnostics(RpcEnvelope request) {
        try {
            DiagnosticsRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.diagnostics.invalid", exception);
            return protocolError(request, "DiagnosticsRequest payload is invalid");
        }
        diagnosticsReporter.recordCounter("rpc.diagnostics.requests", 1);
        DiagnosticsResponse.Builder result = DiagnosticsResponse.newBuilder()
                .setTransport(TransportKind.TRANSPORT_KIND_ADB)
                .setServiceState(diagnosticsReporter.currentState());
        for (String event : diagnosticsReporter.recentErrorEvents()) {
            result.addRecentErrors(event);
        }
        for (String event : diagnosticsReporter.recentEvents()) {
            result.addRecentEvents(event);
        }
        for (Map.Entry<String, Long> counter : diagnosticsReporter.counters().entrySet()) {
            result.putCounters(counter.getKey(), Long.toString(counter.getValue()));
        }
        return response(request, PayloadType.PAYLOAD_TYPE_DIAGNOSTICS_RESPONSE,
                result.build().toByteString());
    }

    private RpcDispatcher.DispatchResult mutation(
            RpcEnvelope request,
            FileMutationResponse result
    ) {
        return response(request, PayloadType.PAYLOAD_TYPE_FILE_MUTATION_RESPONSE,
                result.toByteString());
    }

    private RpcDispatcher.DispatchResult protocolError(RpcEnvelope request, String message) {
        return RpcDispatcher.DispatchResult.response(RpcDispatcher.errorEnvelope(
                request.getRequestId(), ErrorCode.ERROR_CODE_PROTOCOL_ERROR, message));
    }

    private RpcDispatcher.DispatchResult response(
            RpcEnvelope request,
            PayloadType payloadType,
            ByteString payload
    ) {
        return RpcDispatcher.DispatchResult.response(RpcDispatcher.responseEnvelope(
                request.getRequestId(), payloadType, payload));
    }
}
