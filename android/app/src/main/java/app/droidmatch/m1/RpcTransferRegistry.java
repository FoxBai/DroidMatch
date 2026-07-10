package app.droidmatch.m1;

import app.droidmatch.m1.RpcTransferStreams.Download;
import app.droidmatch.m1.RpcTransferStreams.Upload;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

/**
 * Session-scoped ownership registry for active provider transfer handles.
 *
 * The RPC handler decides protocol admission and responses; this class owns
 * identity lookup and deterministic resource release. Every removal transfers
 * close responsibility to the caller, while replacement and session teardown
 * close their displaced handles immediately.
 */
final class RpcTransferRegistry {
    private final ConcurrentMap<String, Download> downloads = new ConcurrentHashMap<>();
    private final ConcurrentMap<String, Upload> uploads = new ConcurrentHashMap<>();

    boolean hasStream(long sessionId, long streamId) {
        String key = key(sessionId, streamId);
        return downloads.containsKey(key) || uploads.containsKey(key);
    }

    int count(long sessionId) {
        String prefix = prefix(sessionId);
        int count = 0;
        for (String key : downloads.keySet()) {
            if (key.startsWith(prefix)) {
                count += 1;
            }
        }
        for (String key : uploads.keySet()) {
            if (key.startsWith(prefix)) {
                count += 1;
            }
        }
        return count;
    }

    boolean hasTransferId(long sessionId, String transferId) {
        String prefix = prefix(sessionId);
        for (Map.Entry<String, Download> entry : downloads.entrySet()) {
            if (entry.getKey().startsWith(prefix) && transferId.equals(entry.getValue().transferId)) {
                return true;
            }
        }
        for (Map.Entry<String, Upload> entry : uploads.entrySet()) {
            if (entry.getKey().startsWith(prefix) && transferId.equals(entry.getValue().transferId)) {
                return true;
            }
        }
        return false;
    }

    void installDownload(long sessionId, long streamId, Download transfer) {
        close(downloads.put(key(sessionId, streamId), transfer));
    }

    void installUpload(long sessionId, long streamId, Upload transfer) {
        close(uploads.put(key(sessionId, streamId), transfer));
    }

    Download download(long sessionId, long streamId) {
        return downloads.get(key(sessionId, streamId));
    }

    Upload upload(long sessionId, long streamId) {
        return uploads.get(key(sessionId, streamId));
    }

    Download removeDownload(long sessionId, long streamId) {
        return downloads.remove(key(sessionId, streamId));
    }

    Upload removeUpload(long sessionId, long streamId) {
        return uploads.remove(key(sessionId, streamId));
    }

    Download removeDownload(long sessionId, String transferId) {
        String prefix = prefix(sessionId);
        for (Map.Entry<String, Download> entry : downloads.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && transferId.equals(entry.getValue().transferId)
                    && downloads.remove(entry.getKey(), entry.getValue())) {
                return entry.getValue();
            }
        }
        return null;
    }

    Upload removeUpload(long sessionId, String transferId) {
        String prefix = prefix(sessionId);
        for (Map.Entry<String, Upload> entry : uploads.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && transferId.equals(entry.getValue().transferId)
                    && uploads.remove(entry.getKey(), entry.getValue())) {
                return entry.getValue();
            }
        }
        return null;
    }

    void closeSession(long sessionId) {
        String prefix = prefix(sessionId);
        for (Map.Entry<String, Download> entry : downloads.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && downloads.remove(entry.getKey(), entry.getValue())) {
                entry.getValue().close();
            }
        }
        for (Map.Entry<String, Upload> entry : uploads.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && uploads.remove(entry.getKey(), entry.getValue())) {
                entry.getValue().close();
            }
        }
    }

    private static String prefix(long sessionId) {
        return sessionId + ":";
    }

    private static String key(long sessionId, long streamId) {
        return prefix(sessionId) + streamId;
    }

    private static void close(Download transfer) {
        if (transfer != null) {
            transfer.close();
        }
    }

    private static void close(Upload transfer) {
        if (transfer != null) {
            transfer.close();
        }
    }
}
