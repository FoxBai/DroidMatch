package app.droidmatch.m1;

import app.droidmatch.proto.v1.ApplicationEntry;
import app.droidmatch.proto.v1.ApplicationSortField;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListApplicationsRequest;
import app.droidmatch.proto.v1.ListApplicationsResponse;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Live, bounded application projection and session-bound stateless paging.
 * No package name, platform path or label is logged. 中文：分页 token 不含应用名称。 */
final class ApplicationListProvider {
    static final int MAX_APPLICATIONS = 4096;
    static final int MAX_PAGE_SIZE = 100;
    static final int MAX_SOURCE_TEXT_LENGTH = 2048;
    private static final Pattern PACKAGE_IDENTIFIER = Pattern.compile(
            "[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*");
    private final ApplicationCatalog catalog;
    private final byte[] cursorKey = new byte[32];

    ApplicationListProvider(ApplicationCatalog catalog) {
        this.catalog = catalog;
        new SecureRandom().nextBytes(cursorKey);
    }

    ListApplicationsResponse list(ListApplicationsRequest request, long sessionId) {
        long generation = catalog == null ? 0 : catalog.accessGeneration();
        if (generation == 0) return failure(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                "application sharing is disabled");
        int pageSize = request.getPageSize() == 0 ? 50 : request.getPageSize();
        if (sessionId <= 0 || pageSize < 1 || pageSize > MAX_PAGE_SIZE
                || request.getQuery().codePointCount(0, request.getQuery().length()) > 128
                || request.getQuery().codePoints().anyMatch(ApplicationListProvider::isInvisible)
                || request.getPageToken().length() > 92
                || request.getSortField() == ApplicationSortField.UNRECOGNIZED) {
            return failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "application query is invalid");
        }
        String query = Normalizer.normalize(request.getQuery(), Normalizer.Form.NFC)
                .trim().toLowerCase(Locale.ROOT);
        try {
            byte[] supplied = request.getPageToken().isEmpty() ? null : decode(request.getPageToken());
            List<ApplicationCatalog.Entry> source = catalog.queryLaunchableApplications();
            if (source == null || source.size() > MAX_APPLICATIONS) {
                return failure(ErrorCode.ERROR_CODE_INTERNAL, "application inventory is unavailable");
            }
            List<ApplicationEntry> entries = new ArrayList<>();
            Set<String> identifiers = new HashSet<>();
            for (ApplicationCatalog.Entry item : source) {
                if (item == null || !validIdentifier(item.packageIdentifier)
                        || !identifiers.add(item.packageIdentifier)
                        || item.versionCode < 0 || item.updatedMillis < 0) {
                    return failure(ErrorCode.ERROR_CODE_INTERNAL, "application inventory is invalid");
                }
                String name = displayText(item.displayName);
                if (name.isEmpty()) name = displayText(item.packageIdentifier);
                if (!name.toLowerCase(Locale.ROOT).contains(query)
                        && !item.packageIdentifier.toLowerCase(Locale.ROOT).contains(query)) continue;
                entries.add(ApplicationEntry.newBuilder().setPackageIdentifier(item.packageIdentifier)
                        .setDisplayName(name).setVersionName(displayText(item.versionName))
                        .setVersionCode(item.versionCode).setUpdatedMillis(item.updatedMillis)
                        .setSystemApplication(item.systemApplication).build());
            }
            Comparator<ApplicationEntry> order = request.getSortField()
                    == ApplicationSortField.APPLICATION_SORT_FIELD_UPDATED
                    ? Comparator.comparingLong(ApplicationEntry::getUpdatedMillis)
                    : Comparator.comparing(entry -> entry.getDisplayName().toLowerCase(Locale.ROOT));
            order = order.thenComparing(ApplicationEntry::getPackageIdentifier);
            entries.sort(request.getDescending() ? order.reversed() : order);
            byte[] snapshot = snapshot(request, pageSize, sessionId, generation, entries);
            int offset = supplied == null ? 0 : readOffset(supplied, snapshot, pageSize, entries.size());
            int end = Math.min(offset + pageSize, entries.size());
            ListApplicationsResponse.Builder result = ListApplicationsResponse.newBuilder()
                    .addAllEntries(entries.subList(offset, end)).setTotalCount(entries.size());
            if (end < entries.size()) result.setNextPageToken(cursor(end, snapshot));
            // Reject off/on races too: a new grant does not revive a request or
            // cursor admitted under the previous grant. 中文：重新授权须重新查询。
            if (catalog.accessGeneration() != generation) {
                return failure(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "application sharing changed");
            }
            return result.build();
        } catch (InvalidCursorException exception) {
            return failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "application list changed; refresh required");
        } catch (SecurityException exception) {
            return failure(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "application access is unavailable");
        } catch (Exception exception) {
            return failure(ErrorCode.ERROR_CODE_INTERNAL, "application inventory is unavailable");
        }
    }

    private byte[] snapshot(ListApplicationsRequest request, int pageSize, long sessionId,
            long generation, List<ApplicationEntry> entries) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        digest.update(ByteBuffer.allocate(29).putLong(sessionId).putLong(generation)
                .putInt(pageSize).putInt(request.getSortFieldValue())
                .put((byte) (request.getDescending() ? 1 : 0)).putInt(entries.size()).array());
        update(digest, request.getQuery().getBytes(StandardCharsets.UTF_8));
        for (ApplicationEntry entry : entries) update(digest, entry.toByteArray());
        return digest.digest();
    }

    private static void update(MessageDigest digest, byte[] bytes) {
        digest.update(ByteBuffer.allocate(4).putInt(bytes.length).array());
        digest.update(bytes);
    }

    private String cursor(int offset, byte[] snapshot) throws Exception {
        byte[] body = ByteBuffer.allocate(37).put((byte) 1).putInt(offset).put(snapshot).array();
        return Base64.getUrlEncoder().withoutPadding().encodeToString(
                ByteBuffer.allocate(69).put(body).put(authenticate(body)).array());
    }

    private static byte[] decode(String token) throws InvalidCursorException {
        try {
            byte[] value = Base64.getUrlDecoder().decode(token);
            if (value.length != 69 || value[0] != 1
                    || !Base64.getUrlEncoder().withoutPadding().encodeToString(value).equals(token)) {
                throw new InvalidCursorException();
            }
            return value;
        } catch (IllegalArgumentException exception) {
            throw new InvalidCursorException();
        }
    }

    private int readOffset(byte[] value, byte[] snapshot, int pageSize, int count) throws Exception {
        byte[] body = Arrays.copyOf(value, 37);
        int offset = ByteBuffer.wrap(body, 1, 4).getInt();
        if (offset <= 0 || offset >= count || offset % pageSize != 0
                || !MessageDigest.isEqual(Arrays.copyOfRange(body, 5, 37), snapshot)
                || !MessageDigest.isEqual(Arrays.copyOfRange(value, 37, 69), authenticate(body))) {
            throw new InvalidCursorException();
        }
        return offset;
    }

    private byte[] authenticate(byte[] body) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(cursorKey, "HmacSHA256"));
        return mac.doFinal(body);
    }

    static boolean validIdentifier(String identifier) {
        return identifier != null && identifier.length() <= 255
                && PACKAGE_IDENTIFIER.matcher(identifier).matches();
    }

    private static String displayText(String value) {
        if (value == null) return "";
        // Bound normalization before it allocates another copy of platform text.
        if (value.length() > MAX_SOURCE_TEXT_LENGTH) value = value.substring(0, MAX_SOURCE_TEXT_LENGTH);
        StringBuilder text = new StringBuilder();
        Normalizer.normalize(value, Normalizer.Form.NFC).codePoints()
                .filter(code -> !isInvisible(code)).limit(160).forEach(text::appendCodePoint);
        return text.toString().trim();
    }

    private static boolean isInvisible(int code) {
        int type = Character.getType(code);
        return Character.isISOControl(code) || type == Character.FORMAT
                || type == Character.SURROGATE || type == Character.LINE_SEPARATOR
                || type == Character.PARAGRAPH_SEPARATOR;
    }

    private static ListApplicationsResponse failure(ErrorCode code, String message) {
        return ListApplicationsResponse.newBuilder().setError(
                DroidMatchError.newBuilder().setCode(code).setMessage(message)).build();
    }

    private static final class InvalidCursorException extends Exception {
        private static final long serialVersionUID = 1;
    }
}
