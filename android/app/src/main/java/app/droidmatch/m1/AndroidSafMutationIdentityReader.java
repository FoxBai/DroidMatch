package app.droidmatch.m1;

import android.content.ContentResolver;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;

import java.io.IOException;
import java.util.List;
import java.util.Objects;

/** Reads the provider-owned identity produced by a SAF create or rename. */
final class AndroidSafMutationIdentityReader {
    private AndroidSafMutationIdentityReader() {}

    static Result read(
            ContentResolver contentResolver,
            Uri treeUri,
            Uri returnedUri
    ) throws IOException {
        Uri canonicalUri = canonicalUri(treeUri, returnedUri);
        String returnedDocumentId = DocumentsContract.getDocumentId(canonicalUri);
        try (Cursor cursor = contentResolver.query(
                canonicalUri,
                SafDocumentCursorReader.projection(),
                null,
                null,
                null
        )) {
            if (cursor == null) {
                throw new IOException("SAF mutation identity could not be queried");
            }
            ProviderSafCatalog.MutationIdentity identity =
                    SafDocumentCursorReader.singleMutationIdentity(cursor);
            if (identity == null || !returnedDocumentId.equals(identity.documentId)) {
                throw new IOException("SAF mutation returned an inconsistent identity");
            }
            return new Result(canonicalUri, identity);
        }
    }

    static Uri canonicalUri(Uri treeUri, Uri returnedUri) throws IOException {
        String treeAuthority = treeUri == null ? null : treeUri.getAuthority();
        if (returnedUri == null
                || treeUri == null
                || treeAuthority == null
                || treeAuthority.isEmpty()
                || !Objects.equals(treeAuthority, returnedUri.getAuthority())) {
            throw new IOException("SAF mutation returned an identity outside its root");
        }
        String returnedDocumentId = DocumentsContract.getDocumentId(returnedUri);
        if (returnedDocumentId == null || returnedDocumentId.isEmpty()) {
            throw new IOException("SAF mutation returned no document identity");
        }
        return DocumentsContract.buildDocumentUriUsingTree(treeUri, returnedDocumentId);
    }

    static ProviderSafCatalog.MutationIdentity uniqueExactChild(
            ContentResolver contentResolver,
            Uri treeUri,
            String parentDocumentId,
            String displayName
    ) throws IOException {
        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                parentDocumentId
        );
        try (Cursor cursor = contentResolver.query(
                childrenUri,
                SafDocumentCursorReader.projection(),
                null,
                null,
                null
        )) {
            if (cursor == null) {
                throw new IOException("SAF mutation parent could not be queried");
            }
            List<SafDocumentCursorReader.ChildDocument> matches =
                    SafDocumentCursorReader.childrenByDisplayName(
                            cursor,
                            displayName,
                            2
                    );
            if (matches.size() > 1) {
                throw new IOException("SAF mutation parent is ambiguous");
            }
            if (matches.isEmpty()) {
                return null;
            }
            SafDocumentCursorReader.ChildDocument child = matches.get(0);
            if (child.documentId == null
                    || child.documentId.isEmpty()
                    || child.kind == app.droidmatch.proto.v1.FileKind
                            .FILE_KIND_UNSPECIFIED) {
                throw new IOException("SAF mutation parent returned invalid metadata");
            }
            return new ProviderSafCatalog.MutationIdentity(
                    child.documentId,
                    displayName,
                    child.kind,
                    child.sizeBytes
            );
        } catch (SecurityException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            throw new IOException("SAF mutation parent query failed", exception);
        }
    }

    static boolean sameIdentity(
            ProviderSafCatalog.MutationIdentity first,
            ProviderSafCatalog.MutationIdentity second
    ) {
        return first != null
                && second != null
                && first.documentId.equals(second.documentId)
                && first.displayName.equals(second.displayName)
                && first.kind == second.kind;
    }

    static final class Result {
        final Uri canonicalUri;
        final ProviderSafCatalog.MutationIdentity identity;

        private Result(
                Uri canonicalUri,
                ProviderSafCatalog.MutationIdentity identity
        ) {
            this.canonicalUri = canonicalUri;
            this.identity = identity;
        }
    }
}
