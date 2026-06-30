package app.droidmatch.m1;

import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;

public final class DmFileProvider {
    public static final String ROOTS_PATH = "dm://roots/";

    private static final Root[] ROOTS = new Root[] {
            new Root("media-images", "Images", true, false),
            new Root("media-videos", "Videos", true, false),
            new Root("app-sandbox", "App Sandbox", true, false)
    };

    public String[] listRoots() {
        String[] paths = new String[ROOTS.length];
        for (int index = 0; index < ROOTS.length; index++) {
            paths[index] = ROOTS[index].path();
        }
        return paths;
    }

    public ListDirResponse listDir(ListDirRequest request) {
        if (!request.getPageToken().isEmpty()) {
            return errorResponse(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "page_token is not supported by the M1 root provider"
            );
        }
        if (!ROOTS_PATH.equals(request.getPath())) {
            return errorResponse(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "unknown DroidMatch provider path: " + request.getPath()
            );
        }

        ListDirResponse.Builder response = ListDirResponse.newBuilder();
        for (Root root : ROOTS) {
            response.addEntries(FileEntry.newBuilder()
                    .setPath(root.path())
                    .setName(root.displayName)
                    .setKind(FileKind.FILE_KIND_VIRTUAL)
                    .setCanRead(root.canRead)
                    .setCanWrite(root.canWrite)
                    .setMimeType("vnd.droidmatch.root")
                    .build());
        }
        return response.build();
    }

    private static ListDirResponse errorResponse(ErrorCode code, String message) {
        return ListDirResponse.newBuilder()
                .setError(DroidMatchError.newBuilder()
                        .setCode(code)
                        .setMessage(message)
                        .build())
                .build();
    }

    private static final class Root {
        private final String id;
        private final String displayName;
        private final boolean canRead;
        private final boolean canWrite;

        private Root(String id, String displayName, boolean canRead, boolean canWrite) {
            this.id = id;
            this.displayName = displayName;
            this.canRead = canRead;
            this.canWrite = canWrite;
        }

        private String path() {
            return "dm://" + id + "/";
        }
    }
}
