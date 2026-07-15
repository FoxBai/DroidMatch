#!/usr/bin/env python3
"""Fail-closed tests for the executable maintainer ownership contract."""

from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CHECKER = Path("tools/check-maintainer-contract.py")
CASES = (
    (
        Path("mac/Sources/DroidMatchPresentation/DirectoryBrowserPresentationTypes.swift"),
        "public var canBrowse: Bool",
    ),
    (
        Path("mac/Sources/DroidMatchPresentation/DirectoryBrowserModel.swift"),
        "guard entry.canBrowse, let query else { return false }",
    ),
    (
        Path("mac/Sources/DroidMatchApp/ProductFileBrowserView.swift"),
        "else if allowsUpload && entry.canAcceptUpload",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java"),
        "mediaPermissionController.manageAccess(mediaSettingsRecommended)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchActivity.java"),
        "outState.putBoolean(STATE_MEDIA_SETTINGS_RECOMMENDED",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/DroidMatchScreen.java"),
        "actions.manageMediaAccess()",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/MediaPermissionController.java"),
        "activity.requestPermissions(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/MediaPermissionController.java"),
        "MediaPermissionPolicy.permissionCallbackComplete(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/MediaPermissionPolicy.java"),
        "static final String READ_MEDIA_VISUAL_USER_SELECTED =",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderDirectoryListings.java"),
        "return mediaCatalog.canReadMedia(RootKind.MEDIA_IMAGES);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "if (!mediaCatalog.canUploadMedia(media.rootKind))",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafCatalog.java"),
        "private final AndroidSafUploadOpener uploadOpener;",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafCatalog.java"),
        "return ProviderAuthorizedTransfers.upload(writer, authorization);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java"),
        "truncateSafUploadPartial(documentUri, offsetBytes);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafUploadOpener.java"),
        "ProviderIoCleanup.deleteDocumentQuietly(contentResolver, documentUri);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/SafUploadOpenPolicy.java"),
        "partialDocument.sizeBytes < offsetBytes",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderAuthorizedTransfers.java"),
        "authorization.requireAuthorized();",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderUploadWriters.java"),
        "commitAuthorization.requireAuthorized();",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidMediaCatalog.java"),
        "() -> isMediaItemVisible(uri)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/PermissionStateProvider.java"),
        "MediaReadAccess publicMediaReadAccess(DmFileProvider.RootKind rootKind)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderIoCleanup.java"),
        "catch (IOException | RuntimeException ignored)",
    ),
)


def copy_repository(destination: Path) -> None:
    ignored = shutil.ignore_patterns(
        ".git",
        ".gradle",
        ".swiftpm",
        ".build",
        "build",
        "DerivedData",
    )
    shutil.copytree(ROOT, destination, ignore=ignored)


def run_checker(repository: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(CHECKER)],
        cwd=repository,
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="droidmatch-maintainer-contract-") as temporary:
        repository = Path(temporary) / "repository"
        copy_repository(repository)

        baseline = run_checker(repository)
        if baseline.returncode != 0:
            raise AssertionError(f"baseline checker failed: {baseline.stderr}")

        for relative_path, required_fragment in CASES:
            source = repository / relative_path
            original = source.read_text(encoding="utf-8")
            if required_fragment not in original:
                raise AssertionError(
                    f"test fixture is missing guarded fragment: {relative_path} / {required_fragment}"
                )
            source.write_text(
                original.replace(required_fragment, "guarded fragment removed", 1),
                encoding="utf-8",
            )
            rejected = run_checker(repository)
            source.write_text(original, encoding="utf-8")
            if rejected.returncode == 0:
                raise AssertionError(
                    f"checker accepted missing ownership seam: {relative_path} / {required_fragment}"
                )
            if "current capability wiring" not in rejected.stderr:
                raise AssertionError(f"unexpected rejection for {relative_path}: {rejected.stderr}")

    print("maintainer contract fail-closed tests passed.")
    print("中文：维护者契约 fail-closed 测试通过。")


if __name__ == "__main__":
    main()
