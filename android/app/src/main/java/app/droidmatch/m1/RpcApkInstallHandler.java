package app.droidmatch.m1;

import app.droidmatch.proto.v1.CancelApkInstallRequest;
import app.droidmatch.proto.v1.CancelApkInstallResponse;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListApkInstallsRequest;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.PrepareApkInstallRequest;
import app.droidmatch.proto.v1.RpcEnvelope;

import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;
import java.util.List;

/** Bounded routing only. No RPC path calls the phone-only submit/confirmation methods. */
final class RpcApkInstallHandler {
    private final ApkInstallManagerProvider provider;

    RpcApkInstallHandler(ApkInstallManagerProvider provider) { this.provider = provider; }

    RpcDispatcher.DispatchResult handle(RpcEnvelope request, List<Capability> capabilities, InstallOwner owner) {
        if (!capabilities.contains(Capability.CAPABILITY_APK_INSTALL) || provider == null) {
            return failure(request, ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
        }
        if (owner == null) return failure(request, ErrorCode.ERROR_CODE_UNAUTHORIZED);
        if (request.getPayload().size() > 2048) return failure(request, ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
        try {
            ApkInstallManager manager = provider.get();
            PayloadType responseType;
            ByteString payload;
            switch (request.getPayloadType()) {
                case PAYLOAD_TYPE_PREPARE_APK_INSTALL_REQUEST:
                    responseType = PayloadType.PAYLOAD_TYPE_PREPARE_APK_INSTALL_RESPONSE;
                    payload = manager.prepare(owner, PrepareApkInstallRequest.parseFrom(request.getPayload())).toByteString();
                    break;
                case PAYLOAD_TYPE_LIST_APK_INSTALLS_REQUEST:
                    ListApkInstallsRequest.parseFrom(request.getPayload());
                    responseType = PayloadType.PAYLOAD_TYPE_LIST_APK_INSTALLS_RESPONSE;
                    payload = manager.list(owner).toByteString();
                    break;
                case PAYLOAD_TYPE_CANCEL_APK_INSTALL_REQUEST:
                    responseType = PayloadType.PAYLOAD_TYPE_CANCEL_APK_INSTALL_RESPONSE;
                    CancelApkInstallRequest cancel = CancelApkInstallRequest.parseFrom(request.getPayload());
                    payload = CancelApkInstallResponse.newBuilder()
                            .setOperation(manager.cancel(owner, cancel.getOperationId())).build().toByteString();
                    break;
                default: return failure(request, ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
            }
            return RpcDispatcher.DispatchResult.response(
                    RpcDispatcher.responseEnvelope(request.getRequestId(), responseType, payload));
        } catch (InvalidProtocolBufferException invalid) {
            return failure(request, ErrorCode.ERROR_CODE_PROTOCOL_ERROR);
        } catch (DmFileProvider.ProviderCatalogException failure) {
            return failure(request, failure.code);
        } catch (RuntimeException unavailable) {
            return failure(request, ErrorCode.ERROR_CODE_INTERNAL);
        }
    }

    private static RpcDispatcher.DispatchResult failure(RpcEnvelope request, ErrorCode code) {
        String label;
        switch (code) {
            case ERROR_CODE_UNAUTHORIZED: label = "paired installation authentication is required"; break;
            case ERROR_CODE_PERMISSION_REQUIRED: label = "enable APK installation requests on Android"; break;
            case ERROR_CODE_NOT_FOUND: label = "installation operation is unavailable"; break;
            case ERROR_CODE_ALREADY_EXISTS: label = "an installation needs attention on Android"; break;
            case ERROR_CODE_INVALID_ARGUMENT: label = "APK installation request is invalid"; break;
            case ERROR_CODE_UNSUPPORTED_CAPABILITY: label = "system-confirmed installation is unavailable"; break;
            default: label = "installation state is unavailable";
        }
        return RpcDispatcher.DispatchResult.response(RpcDispatcher.errorEnvelope(request.getRequestId(), code, label));
    }
}
