package app.droidmatch.m1;

import java.io.IOException;
import java.io.OutputStream;
import java.util.Set;

/** The manager owns authorization/state; the Android adapter owns OS sessions and intents. */
interface ApkInstallBackend {
    boolean supported();
    boolean sourceTrusted();
    int create(long size) throws IOException;
    Sink openUpload(int sessionId, long size) throws IOException;
    void submit(int sessionId, String operationId, byte[] callbackKey) throws IOException;
    void abandon(int sessionId) throws IOException;
    Set<Integer> ownedSessionIds() throws IOException;

    interface Sink extends AutoCloseable {
        OutputStream stream();
        void sync() throws IOException;
        @Override void close() throws IOException;
    }
}
