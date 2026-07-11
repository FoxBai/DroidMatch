package app.droidmatch.m1;

/** Encoded provider result; platform Bitmap objects never cross this boundary. */
final class ProviderThumbnail {
    final byte[] encodedImage;
    final String mimeType;
    final int widthPx;
    final int heightPx;

    ProviderThumbnail(byte[] encodedImage, String mimeType, int widthPx, int heightPx) {
        this.encodedImage = encodedImage;
        this.mimeType = mimeType;
        this.widthPx = widthPx;
        this.heightPx = heightPx;
    }
}
