package app.droidmatch.m1;

/** Resolves the process-owned installer without making transport wait for application startup. */
interface ApkInstallManagerProvider {
    ApkInstallManager get() throws DmFileProvider.ProviderCatalogException;
}
