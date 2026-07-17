package app.droidmatch.m1;

import static app.droidmatch.m1.DmFileProviderTestFixtures.deleteAppSandboxRoot;
import static app.droidmatch.m1.DmFileProviderTestFixtures.deleteRecursively;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import app.droidmatch.proto.v1.ErrorCode;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.Test;

public final class AppSandboxPathResolverTest {
    @Test
    public void resolvesRootExistingAndFutureEntriesBelowCanonicalRoot() throws Exception {
        File root = Files.createTempDirectory("droidmatch-path-resolver").toFile();
        try {
            assertTrue(new File(root, "existing").mkdir());
            AppSandboxPathResolver resolver = new AppSandboxPathResolver(root);

            assertEquals(root.getCanonicalFile(), resolver.resolve(""));
            assertEquals(
                    new File(root, "existing/.future").getCanonicalFile(),
                    resolver.resolve("existing/.future")
            );
        } finally {
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void rejectsLexicalAliasesBeforeCanonicalizationCanEraseThem() throws Exception {
        File root = Files.createTempDirectory("droidmatch-path-resolver").toFile();
        try {
            AppSandboxPathResolver resolver = new AppSandboxPathResolver(root);

            assertInvalid(resolver, ".");
            assertInvalid(resolver, "child/..");
            assertInvalid(resolver, "child//file");
            assertInvalid(resolver, "/absolute");
            assertInvalid(resolver, ".payload.droidmatch-upload-part");
        } finally {
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void rejectsEveryExistingSymbolicLinkComponent() throws Exception {
        Path root = Files.createTempDirectory("droidmatch-path-resolver");
        Path outside = Files.createTempDirectory("droidmatch-path-resolver-outside");
        Path directAlias = Files.createSymbolicLink(root.resolve("direct"), outside);
        Path container = Files.createDirectory(root.resolve("container"));
        Path nestedAlias = Files.createSymbolicLink(container.resolve("nested"), outside);
        try {
            AppSandboxPathResolver resolver = new AppSandboxPathResolver(root.toFile());

            assertInvalid(resolver, "direct");
            assertInvalid(resolver, "direct/future.txt");
            assertInvalid(resolver, "container/nested/future.txt");
            assertTrue(Files.isSymbolicLink(directAlias));
            assertTrue(Files.isSymbolicLink(nestedAlias));
        } finally {
            Files.deleteIfExists(directAlias);
            Files.deleteIfExists(nestedAlias);
            deleteAppSandboxRoot(root.toFile());
            deleteRecursively(outside.toFile());
        }
    }

    private static void assertInvalid(AppSandboxPathResolver resolver, String relativePath)
            throws Exception {
        try {
            resolver.resolve(relativePath);
            fail("expected invalid app sandbox path: " + relativePath);
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
        }
    }
}
