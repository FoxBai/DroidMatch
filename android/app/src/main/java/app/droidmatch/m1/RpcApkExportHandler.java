package app.droidmatch.m1;

import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.PrepareApkExportRequest;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.ValidateApkExportRequest;
import app.droidmatch.proto.v1.ValidateApkExportResponse;
import com.google.protobuf.InvalidProtocolBufferException;

final class RpcApkExportHandler {
    private final ApkExportCatalog catalog;
    RpcApkExportHandler(ApkExportCatalog catalog) { this.catalog = catalog; }

    RpcDispatcher.DispatchResult handle(RpcEnvelope request, RpcSessionState state) {
        if (state.installOwner == null) return failure(request, ErrorCode.ERROR_CODE_UNAUTHORIZED);
        if (catalog == null || !state.grantedCapabilities.contains(Capability.CAPABILITY_APK_EXPORT)
                || !state.grantedCapabilities.contains(Capability.CAPABILITY_FILE_READ)) {
            return failure(request, ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
        }
        if (request.getPayload().size() > 1024) return failure(request, ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
        try {
            if (request.getPayloadType() == PayloadType.PAYLOAD_TYPE_PREPARE_APK_EXPORT_REQUEST) {
                String identifier = PrepareApkExportRequest.parseFrom(request.getPayload()).getPackageIdentifier();
                if (state.apkExport != null) state.apkExport.invalidate();
                state.apkExport = null;
                ApkExportLease next = new ApkExportLease(catalog, identifier);
                app.droidmatch.proto.v1.PrepareApkExportResponse response = next.manifest();
                state.apkExport = next;
                return RpcDispatcher.DispatchResult.response(RpcDispatcher.responseEnvelope(request.getRequestId(),
                        PayloadType.PAYLOAD_TYPE_PREPARE_APK_EXPORT_RESPONSE, response.toByteString()));
            }
            String id = ValidateApkExportRequest.parseFrom(request.getPayload()).getExportId();
            if (state.apkExport == null || !state.apkExport.id.equals(id)) {
                return failure(request, ErrorCode.ERROR_CODE_NOT_FOUND);
            }
            state.apkExport.validate(true);
            return RpcDispatcher.DispatchResult.response(RpcDispatcher.responseEnvelope(request.getRequestId(),
                    PayloadType.PAYLOAD_TYPE_VALIDATE_APK_EXPORT_RESPONSE,
                    ValidateApkExportResponse.newBuilder().setExportId(id).build().toByteString()));
        } catch (InvalidProtocolBufferException error) {
            return failure(request, ErrorCode.ERROR_CODE_PROTOCOL_ERROR);
        } catch (DmFileProvider.ProviderCatalogException error) {
            return failure(request, error.code);
        } catch (RuntimeException error) {
            return failure(request, ErrorCode.ERROR_CODE_INTERNAL);
        }
    }

    private static RpcDispatcher.DispatchResult failure(RpcEnvelope request, ErrorCode code) {
        return RpcDispatcher.DispatchResult.response(RpcDispatcher.errorEnvelope(request.getRequestId(),
                code, "APK export is unavailable"));
    }
}
