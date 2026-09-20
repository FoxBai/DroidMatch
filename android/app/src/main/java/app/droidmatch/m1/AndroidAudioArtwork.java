package app.droidmatch.m1;

import android.annotation.TargetApi;
import android.content.ContentResolver;
import android.content.res.AssetFileDescriptor;
import android.graphics.Bitmap;
import android.graphics.ImageDecoder;
import android.graphics.Point;
import android.net.Uri;
import android.os.Bundle;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;

/** API 29+ MediaStore image derivative adapter. No original audio fallback.
 * 中文：请求系统提供的图片派生物；源字节和解码尺寸均在分配前受限。 */
@TargetApi(29)
final class AndroidAudioArtwork {
    static ProviderThumbnail load(
            ContentResolver resolver, Uri uri, int maximum,
            ProviderLiveAuthorization authorization
    ) throws DmFileProvider.ProviderCatalogException, IOException {
        return ProviderAudioArtwork.load(maximum, authorization,
                () -> openDerivative(resolver, uri, maximum), AndroidAudioArtwork::encode);
    }

    private static InputStream openDerivative(ContentResolver resolver, Uri uri, int maximum)
            throws IOException {
        Bundle options = new Bundle();
        options.putParcelable(ContentResolver.EXTRA_SIZE, new Point(maximum, maximum));
        AssetFileDescriptor asset = resolver.openTypedAssetFileDescriptor(uri, "image/*", options);
        if (asset == null) return null;
        try {
            if (asset.getDeclaredLength() > ProviderAudioArtwork.MAX_INPUT_BYTES) {
                throw new IOException("audio artwork exceeds input budget");
            }
            // AutoCloseInputStream retains the declared slice and owns the FD.
            // 中文：流按声明的切片读取，并负责关闭描述符。
            return asset.createInputStream();
        } catch (IOException | RuntimeException exception) {
            try { asset.close(); } catch (IOException ignored) { }
            throw exception;
        }
    }

    private static ProviderThumbnail encode(byte[] input, int maximum) throws IOException {
        Bitmap bitmap = ImageDecoder.decodeBitmap(
                ImageDecoder.createSource(ByteBuffer.wrap(input)),
                (decoder, info, source) -> {
                    int[] size = ProviderAudioArtwork.targetSize(
                            info.getSize().getWidth(), info.getSize().getHeight(), maximum);
                    decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);
                    decoder.setTargetSize(size[0], size[1]);
                    decoder.setOnPartialImageListener(exception -> false);
                });
        try {
            if (bitmap.getWidth() > maximum || bitmap.getHeight() > maximum) {
                throw new IOException("audio artwork exceeds decoded budget");
            }
            ProviderAudioArtwork.EncodedOutput output = new ProviderAudioArtwork.EncodedOutput();
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 82, output)) {
                throw new IOException("audio artwork encoding failed");
            }
            return new ProviderThumbnail(output.toByteArray(), "image/jpeg",
                    bitmap.getWidth(), bitmap.getHeight());
        } finally {
            bitmap.recycle();
        }
    }
}
