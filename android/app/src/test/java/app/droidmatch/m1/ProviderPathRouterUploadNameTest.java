package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;

import java.util.Collections;

import org.junit.Test;

import app.droidmatch.proto.v1.ErrorCode;

public final class ProviderPathRouterUploadNameTest {
    @Test
    public void safUploadReservesItsPartialPrefixOnlyWithinSaf() {
        DmFileProvider.SafRoot root = new DmFileProvider.SafRoot(
                "abc123", "primary:Docs", "Documents", true
        );
        String supplementaryFormat = new String(Character.toChars(0xE0001));

        for (String displayName : new String[] {
                "private%name.bin",
                "private" + String.valueOf((char) 0x0001) + "name.bin",
                "private" + String.valueOf((char) 0x0085) + "name.bin",
                "private\u200Dname.bin",
                "private\u202Ename.bin",
                "private\u2068name.bin",
                "private" + supplementaryFormat + "name.bin",
                ".droidmatch-upload-0123456789abcdef0123.part",
                ".droidmatch-upload-provider-renamed (1).part",
        }) {
            ProviderPathRouter.SafUploadTarget target = ProviderPathRouter.safUpload(
                    root.path() + displayName,
                    Collections.singletonList(root),
                    new ProviderSafDocumentCache(1)
            );

            assertNotNull(target.error);
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, target.error.code);
            assertEquals("malformed SAF upload file name", target.error.getMessage());
            assertFalse(target.error.getMessage().contains("private"));
        }

        String crossProviderName = ".droidmatch-upload-user.jpg";
        ProviderPathRouter.AppSandboxTarget appSandbox =
                ProviderPathRouter.appSandboxUploadFile(
                        DmFileProvider.APP_SANDBOX_PATH + crossProviderName
                );
        ProviderPathRouter.MediaUploadTarget media =
                ProviderPathRouter.mediaUpload(
                        DmFileProvider.MEDIA_IMAGES_PATH + crossProviderName
                );
        assertNull(appSandbox.downloadError);
        assertEquals(crossProviderName, appSandbox.relativePath);
        assertNull(media.error);
        assertEquals(crossProviderName, media.displayName);
    }
}
