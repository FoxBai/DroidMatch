package app.droidmatch.m1;

import app.droidmatch.proto.v1.ErrorCode;

import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Process-local exclusive ownership for one canonical provider destination.
 *
 * <p>The foreground endpoint serves multiple sessions concurrently. A session
 * registry therefore cannot protect provider partials by itself: two sessions
 * could otherwise open the same destination and make one writer commit the
 * other's partial. Leases live beside the shared provider facade and are held
 * until the writer commits, aborts, or closes.</p>
 */
final class ProviderUploadLeases {
    private final ConcurrentMap<Destination, LeaseToken> active = new ConcurrentHashMap<>();

    DmFileProvider.UploadWriter openLeased(Destination destination, Opener opener)
            throws DmFileProvider.ProviderCatalogException {
        LeaseToken token = new LeaseToken();
        if (active.putIfAbsent(destination, token) != null) {
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                    "upload destination is already active"
            );
        }

        boolean opened = false;
        try {
            DmFileProvider.UploadWriter writer = opener.open();
            if (writer == null) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "upload provider returned no writer"
                );
            }
            DmFileProvider.UploadWriter leased = new LeasedUploadWriter(
                    writer,
                    destination,
                    token,
                    this
            );
            opened = true;
            return leased;
        } finally {
            if (!opened) {
                release(destination, token);
            }
        }
    }

    void runLeased(Destination destination, Operation operation)
            throws DmFileProvider.ProviderCatalogException {
        LeaseToken token = new LeaseToken();
        if (active.putIfAbsent(destination, token) != null) {
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                    "upload destination is already active"
            );
        }
        try {
            operation.run();
        } finally {
            release(destination, token);
        }
    }

    private void release(Destination destination, LeaseToken token) {
        // Token-qualified removal prevents a repeated close from releasing a
        // later writer that already acquired the same destination.
        active.remove(destination, token);
    }

    @FunctionalInterface
    interface Opener {
        DmFileProvider.UploadWriter open() throws DmFileProvider.ProviderCatalogException;
    }

    @FunctionalInterface
    interface Operation {
        void run() throws DmFileProvider.ProviderCatalogException;
    }

    static final class Destination {
        private final String namespace;
        private final String first;
        private final String second;
        private final String third;

        private Destination(String namespace, String first, String second, String third) {
            this.namespace = namespace;
            this.first = first;
            this.second = second;
            this.third = third;
        }

        static Destination appSandbox(String canonicalPath) {
            return new Destination("app-sandbox", canonicalPath, "", "");
        }

        static Destination media(DmFileProvider.RootKind rootKind, String displayName) {
            return new Destination("media", rootKind.name(), displayName, "");
        }

        static Destination saf(
                DmFileProvider.SafRoot root,
                String parentDocumentId,
                String displayName
        ) {
            if (root.treeUri == null) {
                return new Destination(
                        "saf",
                        "stable:" + root.stableId,
                        parentDocumentId,
                        displayName
                );
            }
            return safAuthority(
                    Objects.toString(root.treeUri.getAuthority(), ""),
                    parentDocumentId,
                    displayName
            );
        }

        static Destination safAuthority(
                String providerAuthority,
                String parentDocumentId,
                String displayName
        ) {
            // A user can grant both a parent tree and one of its child trees.
            // DocumentsProvider IDs are unique within an authority, so the
            // tree URI itself must not split one physical destination's lease.
            return new Destination(
                    "saf",
                    "authority:" + providerAuthority,
                    parentDocumentId,
                    displayName
            );
        }

        @Override
        public boolean equals(Object other) {
            if (this == other) {
                return true;
            }
            if (!(other instanceof Destination)) {
                return false;
            }
            Destination destination = (Destination) other;
            return namespace.equals(destination.namespace)
                    && first.equals(destination.first)
                    && second.equals(destination.second)
                    && third.equals(destination.third);
        }

        @Override
        public int hashCode() {
            return Objects.hash(namespace, first, second, third);
        }
    }

    private static final class LeaseToken {
    }

    private static final class LeasedUploadWriter implements DmFileProvider.UploadWriter {
        private final DmFileProvider.UploadWriter writer;
        private final Destination destination;
        private final LeaseToken token;
        private final ProviderUploadLeases owner;
        private final AtomicBoolean closed = new AtomicBoolean(false);

        private LeasedUploadWriter(
                DmFileProvider.UploadWriter writer,
                Destination destination,
                LeaseToken token,
                ProviderUploadLeases owner
        ) {
            this.writer = writer;
            this.destination = destination;
            this.token = token;
            this.owner = owner;
        }

        @Override
        public long nextOffsetBytes() {
            return writer.nextOffsetBytes();
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                throws DmFileProvider.ProviderCatalogException {
            boolean succeeded = false;
            try {
                writer.writeChunk(offsetBytes, data, finalChunk);
                succeeded = true;
            } finally {
                // A failed write is an abort even when a direct provider caller
                // forgets to close. A successful final write has already made
                // the provider commit durable, so its lease can end immediately.
                if (finalChunk || !succeeded) {
                    close();
                }
            }
        }

        @Override
        public void close() {
            if (!closed.compareAndSet(false, true)) {
                return;
            }
            try {
                writer.close();
            } finally {
                owner.release(destination, token);
            }
        }
    }
}
