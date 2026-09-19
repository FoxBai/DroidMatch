package app.droidmatch.m1;

import static org.junit.Assert.*;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.PrepareApkExportRequest;
import app.droidmatch.proto.v1.PrepareApkExportResponse;
import app.droidmatch.proto.v1.RpcEnvelope;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.Test;

public final class ApkExportLeaseTest {
    @Test public void completeSplitSetHasOpaquePathsAndFreshOnlyReaders() throws Exception {
        Catalog catalog = new Catalog();
        ApkExportLease lease = new ApkExportLease(catalog, "fixture.app");
        PrepareApkExportResponse manifest = lease.manifest();
        assertEquals(2, manifest.getComponentsCount());
        assertEquals("", manifest.getComponents(0).getSplitName());
        assertEquals("config.arm64_v8a", manifest.getComponents(1).getSplitName());
        assertEquals(1, manifest.getComponents(1).getIndex());
        assertFalse(manifest.toString().contains("/private"));
        DmFileProvider.DownloadReader reader = lease.open(path(lease, 1), 0, 4);
        assertEquals(4, reader.readNextChunk().data.length);
        DmFileProvider.DownloadChunk last = reader.readNextChunk();
        assertEquals(3, last.data.length); assertTrue(last.finalChunk);
        assertEquals(7, last.totalSizeBytes); assertEquals(0, last.modifiedUnixMillis);
        assertEquals(lease.id + ":1", last.providerEtag);
        assertEquals(1, catalog.closed);
        denied(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, () -> lease.open(path(lease, 0), 1, 4));
        denied(ErrorCode.ERROR_CODE_NOT_FOUND, () -> lease.open(path(lease, 0).replace("/0.apk", "/00.apk"), 0, 4));
        ApkExportLease other = new ApkExportLease(catalog, "fixture.app");
        denied(ErrorCode.ERROR_CODE_NOT_FOUND, () -> other.open(path(lease, 0), 0, 4));
    }

    @Test public void metadataSharingAloneAndRegrantCannotAuthorizeBytes() throws Exception {
        Catalog catalog = new Catalog(); catalog.exports.setEnabled(false);
        denied(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, () -> new ApkExportLease(catalog, "fixture.app"));
        assertEquals(0, catalog.captures);
        catalog.exports.setEnabled(true);
        ApkExportLease lease = new ApkExportLease(catalog, "fixture.app");
        DmFileProvider.DownloadReader reader = lease.open(path(lease, 0), 0, 4);
        reader.readNextChunk();
        catalog.exports.setEnabled(false); catalog.exports.setEnabled(true);
        denied(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, reader::readNextChunk);
        assertEquals(1, catalog.closed);
        denied(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, () -> lease.validate(true));
        ApkExportLease next = new ApkExportLease(catalog, "fixture.app");
        catalog.applications.setEnabled(false); catalog.applications.setEnabled(true);
        denied(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, () -> next.open(path(next, 0), 0, 4));
    }

    @Test public void midReadUpdateAndFinalWholeSetChangesPreventSuccess() throws Exception {
        Catalog catalog = new Catalog();
        ApkExportLease lease = new ApkExportLease(catalog, "fixture.app");
        DmFileProvider.DownloadReader reader = lease.open(path(lease, 0), 0, 4);
        catalog.changeDuringRead = true;
        denied(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, reader::readNextChunk);
        assertEquals(1, catalog.closed);
        catalog.changeDuringRead = false;
        ApkExportLease fresh = new ApkExportLease(catalog, "fixture.app");
        DmFileProvider.DownloadReader complete = fresh.open(path(fresh, 0), 0, 8);
        assertTrue(complete.readNextChunk().finalChunk);
        catalog.revision++;
        denied(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, () -> fresh.validate(true));
    }

    @Test public void malformedOrOversizedSetsNeverReturnTruncatedManifests() throws Exception {
        Catalog catalog = new Catalog();
        List<List<ApkExportCatalog.Component>> invalid = Arrays.asList(
                new ArrayList<>(), Arrays.asList(new ApkExportCatalog.Component("base", 7)),
                Arrays.asList(new ApkExportCatalog.Component("", 0)),
                Arrays.asList(new ApkExportCatalog.Component("", ApkExportLease.MAX_COMPONENT_BYTES + 1)),
                Arrays.asList(new ApkExportCatalog.Component("", 7), new ApkExportCatalog.Component("../private", 7)),
                Arrays.asList(new ApkExportCatalog.Component("", 7), new ApkExportCatalog.Component("", 7)));
        for (List<ApkExportCatalog.Component> parts : invalid) {
            catalog.parts = parts;
            denied(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, () -> new ApkExportLease(catalog, "fixture.app"));
        }
        catalog.parts = new ArrayList<>();
        for (int i = 0; i < 257; i++) catalog.parts.add(new ApkExportCatalog.Component(i == 0 ? "" : "split" + i, 7));
        denied(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, () -> new ApkExportLease(catalog, "fixture.app"));
        catalog.parts = new ArrayList<>();
        for (int i = 0; i < 9; i++) catalog.parts.add(new ApkExportCatalog.Component(i == 0 ? "" : "split" + i,
                ApkExportLease.MAX_COMPONENT_BYTES));
        denied(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, () -> new ApkExportLease(catalog, "fixture.app"));
    }

    @Test public void preparationNeedsPairedSessionAndReplacementInvalidatesOldLease() throws Exception {
        Catalog catalog = new Catalog(); RpcApkExportHandler handler = new RpcApkExportHandler(catalog);
        RpcSessionState state = new RpcSessionState();
        state.grantedCapabilities = Arrays.asList(Capability.CAPABILITY_FILE_READ, Capability.CAPABILITY_APK_EXPORT);
        RpcEnvelope request = RpcEnvelope.newBuilder().setRequestId(1)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_PREPARE_APK_EXPORT_REQUEST)
                .setPayload(PrepareApkExportRequest.newBuilder().setPackageIdentifier("fixture.app").build().toByteString())
                .build();
        handler.handle(request, state);
        assertEquals(0, catalog.captures); assertNull(state.apkExport);
        state.installOwner = InstallOwner.authenticated(new byte[16]);
        handler.handle(request, state);
        ApkExportLease first = state.apkExport; assertNotNull(first);
        handler.handle(request, state); assertNotSame(first, state.apkExport);
        denied(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, () -> first.open(path(first, 0), 0, 4));
        ApkExportLease second = state.apkExport;
        state.closeAndClear(); assertNull(state.apkExport);
        denied(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, () -> second.validate(true));
    }

    private static String path(ApkExportLease lease, int index) { return ApkExportLease.PREFIX + lease.id + "/" + index + ".apk"; }
    private interface Action { void run() throws Exception; }
    private static void denied(ErrorCode code, Action action) throws Exception {
        try { action.run(); fail("request must fail"); }
        catch (DmFileProvider.ProviderCatalogException error) { assertEquals(code, error.code); }
    }

    private static final class Catalog implements ApkExportCatalog {
        final ApplicationAccess applications = new ApplicationAccess();
        final ApkExportAccess exports = new ApkExportAccess();
        List<Component> parts = Arrays.asList(new Component("", 7), new Component("config.arm64_v8a", 7));
        int revision = 1, captures, closed;
        boolean changeDuringRead;
        Catalog() { applications.setEnabled(true); exports.setEnabled(true); }
        @Override public long exportGeneration() { return exports.generation(); }
        @Override public long applicationGeneration() { return applications.generation(); }
        @Override public Snapshot capture(String identifier) {
            captures++; return new Snapshot(identifier, revision, 123, parts);
        }
        @Override public void validate(Snapshot snapshot, boolean complete) throws DmFileProvider.ProviderCatalogException {
            if (snapshot.versionCode != revision) throw ApkExportLease.failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
        }
        @Override public DmFileProvider.DownloadReader open(Snapshot snapshot, int index, int chunkSize) {
            return new DmFileProvider.DownloadReader() {
                int offset; boolean done;
                @Override public DmFileProvider.DownloadChunk readNextChunk() {
                    int length = Math.min(chunkSize, 7 - offset); offset += length;
                    if (changeDuringRead) revision++;
                    return new DmFileProvider.DownloadChunk(new byte[length], 7, 123, "private-identity", offset == 7);
                }
                @Override public void close() { if (!done) { done = true; closed++; } }
            };
        }
    }
}
