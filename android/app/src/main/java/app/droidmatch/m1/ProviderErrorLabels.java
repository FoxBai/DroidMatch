package app.droidmatch.m1;

import app.droidmatch.proto.v1.ErrorCode;

/**
 * Produces bounded provider-owned labels for errors that cross the wire.
 *
 * <p>Catalog exceptions retain their detailed message for local control flow and
 * tests, but a provider must never make that message part of a directory response:
 * a future implementation could accidentally include a private file name, URI, or
 * platform path. The provider name arguments below are fixed literals owned by the
 * callers, never request data.</p>
 * 中文：异常原文只留在 provider 内部，目录 wire 错误只使用固定标签，避免文件名、URI 或路径泄露。
 */
final class ProviderErrorLabels {
    private ProviderErrorLabels() {}

    static String listing(ErrorCode code, String providerName) {
        switch (code) {
            case ERROR_CODE_PERMISSION_REQUIRED:
                return providerName + " permission is required";
            case ERROR_CODE_NOT_FOUND:
                return providerName + " directory is not available";
            case ERROR_CODE_INVALID_ARGUMENT:
                return providerName + " listing request is invalid";
            case ERROR_CODE_UNSUPPORTED_CAPABILITY:
                return providerName + " listing is not supported";
            default:
                return providerName + " listing failed";
        }
    }
}
