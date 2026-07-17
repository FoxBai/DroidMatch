import AppKit
import DroidMatchPresentation
import SwiftUI

/// Independent media information architecture over the authenticated file API.
///
/// The three browser models remain session-owned in Presentation. This view
/// owns only the segmented selection and native upload panel.
struct ProductMediaLibraryView: View {
    @ObservedObject var model: MediaLibraryModel
    @ObservedObject var transferQueue: TransferQueueModel
    let allowsUpload: Bool
    @State private var submissionFailure: ProductFileSubmissionFailure?

    var body: some View {
        VStack(spacing: 0) {
            sectionPicker
            if showsParentTransferPersistenceBanner {
                Divider()
                ProductTransferPersistenceBanner(model: transferQueue)
            }
            if showsFreshUploadNotice {
                Divider()
                freshUploadNotice
            }
            Divider()
            content
        }
        .disabled(transferQueue.isSubmittingTransfer)
        .navigationTitle(AppStrings.mediaLibrary)
        .background(Color(nsColor: .windowBackgroundColor))
        // Re-read live capabilities every time the surface becomes visible so
        // permission revocation while another section is open cannot leave
        // cached media names on screen.
        .onAppear { model.activate() }
        .alert(item: $submissionFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.detail),
                dismissButton: .cancel(Text(AppStrings.dismiss))
            )
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.stack.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Picker(AppStrings.mediaLibrary, selection: sectionSelection) {
                ForEach(MediaLibrarySection.allCases) { section in
                    Text(title(for: section)).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 440)
            .disabled(model.phase != .ready)
            Spacer()
            if model.phase == .loadingAccess {
                ProgressView().controlSize(.small)
            }
            if showsTopAccessRefresh {
                Button {
                    model.refreshAccess()
                } label: {
                    Label(AppStrings.recheckMediaAccess, systemImage: "lock.rotation")
                }
                .help(AppStrings.recheckMediaAccessDetail)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var showsTopAccessRefresh: Bool {
        model.phase == .ready
            && model.selectedRoot?.canBrowse == true
            && !model.selectedSectionRequiresPermission
    }

    private var showsFreshUploadNotice: Bool {
        allowsUpload
            && model.phase == .ready
            && model.selectedRoot?.canAcceptUpload == true
    }

    private var freshUploadNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(AppStrings.mediaUploadFreshOnlyDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if model.phase == .idle || model.phase == .loadingAccess {
            ProgressView(AppStrings.loadingMediaLibrary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.phase == .failed {
            mediaState(
                symbol: "wifi.exclamationmark",
                title: AppStrings.mediaLibraryUnavailable,
                detail: accessFailureText,
                actionTitle: AppStrings.tryAgain,
                action: model.refreshAccess
            )
        } else if let root = model.selectedRoot {
            if model.selectedSectionRequiresPermission || !root.canBrowse {
                mediaAccessRequired(root)
            } else {
                mediaBrowser(root: root, section: model.selectedSection)
            }
        } else {
            mediaState(
                symbol: "photo.badge.exclamationmark",
                title: AppStrings.mediaCategoryUnavailable,
                detail: AppStrings.mediaCategoryUnavailableDetail,
                actionTitle: AppStrings.recheckMediaAccess,
                action: model.refreshAccess
            )
        }
    }

    private func mediaBrowser(
        root: DirectoryBrowserItem,
        section: MediaLibrarySection
    ) -> some View {
        ProductFileBrowserView(
            model: model.selectedBrowser,
            transferQueue: transferQueue,
            allowsUpload: allowsUpload,
            title: AppStrings.mediaLibrary,
            rootDirectory: root,
            onPermissionRequired: { model.requirePermission(for: section) }
        )
        .id(section)
    }

    private func mediaAccessRequired(_ root: DirectoryBrowserItem) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.square.stack")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(AppStrings.mediaAccessRequired)
                .font(.title2.weight(.semibold))
            Text(mediaAccessRequiredDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            HStack(spacing: 10) {
                Button(AppStrings.recheckMediaAccess) { model.refreshAccess() }
                    .buttonStyle(.borderedProminent)
                if allowsUpload && root.canAcceptUpload {
                    Button(AppStrings.upload) { chooseUploadSource(into: root) }
                        .disabled(!transferQueue.canPresentTransferSubmission)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mediaState(
        symbol: String,
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionSelection: Binding<MediaLibrarySection> {
        Binding(
            get: { model.selectedSection },
            set: { model.select($0) }
        )
    }

    private func title(for section: MediaLibrarySection) -> String {
        switch section {
        case .images: return AppStrings.images
        case .albums: return AppStrings.imageAlbums
        case .videos: return AppStrings.videos
        }
    }

    private var mediaAccessRequiredDetail: String {
        switch model.selectedSection {
        case .images, .albums:
            return AppStrings.mediaPhotoAccessRequiredDetail
        case .videos:
            return AppStrings.mediaVideoAccessRequiredDetail
        }
    }

    private var showsParentTransferPersistenceBanner: Bool {
        guard (!transferQueue.isPersistenceStatusKnown
                || transferQueue.persistenceStatus == .writeFailed),
              let root = model.selectedRoot else { return false }
        return root.canAcceptUpload
            && (model.selectedSectionRequiresPermission || !root.canBrowse)
    }

    private var accessFailureText: String {
        switch model.failure {
        case .permissionRequired: return AppStrings.filePermissionRequired
        case .notFound: return AppStrings.fileLocationUnavailable
        case .unsupported: return AppStrings.fileOperationUnsupported
        case .invalidRequest, .invalidResponse: return AppStrings.fileResponseInvalid
        case .unavailable, .none: return AppStrings.fileConnectionUnavailable
        }
    }

    private func chooseUploadSource(into root: DirectoryBrowserItem) {
        let section = model.selectedSection
        guard isCurrentUploadRoot(root, section: section) else { return }
        let panel = ProductUploadPanelPolicy.makePanel(directoryPath: root.path)
        panel.begin { response in
            let selectedURLs = panel.urls
            guard response == .OK,
                  isCurrentUploadRoot(root, section: section),
                  let sourceURLs = ProductUploadPanelPolicy.acceptedFiles(
                      selectedURLs,
                      directoryPath: root.path
                  ) else {
                if response == .OK {
                    submissionFailure = .uploadSelection(count: selectedURLs.count)
                }
                return
            }
            Task { @MainActor in
                guard isCurrentUploadRoot(root, section: section) else {
                    submissionFailure = .uploadSelection(count: sourceURLs.count)
                    return
                }
                let ids = await transferQueue.submitUploads(
                    sourceURLs: sourceURLs,
                    directoryPath: root.path
                )
                if ids.count != sourceURLs.count {
                    submissionFailure = .uploadSubmission(
                        count: sourceURLs.count,
                        acceptedCount: ids.count
                    )
                }
            }
        }
    }

    private func isCurrentUploadRoot(
        _ root: DirectoryBrowserItem,
        section: MediaLibrarySection
    ) -> Bool {
        allowsUpload
            && transferQueue.canPresentTransferSubmission
            && model.phase == .ready
            && model.selectedSection == section
            && model.selectedRoot == root
            && root.canAcceptUpload
    }
}
