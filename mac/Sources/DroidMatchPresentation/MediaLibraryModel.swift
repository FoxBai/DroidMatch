import Combine
import DroidMatchCore
import Foundation

public enum MediaLibrarySection: String, CaseIterable, Identifiable, Sendable {
    case images
    case albums
    case videos

    public var id: Self { self }

    var rootPath: String {
        switch self {
        case .images: return "dm://media-images/"
        case .albums: return "dm://media-images/albums/"
        case .videos: return "dm://media-videos/"
        }
    }
}

public enum MediaLibraryPhase: String, Sendable, Equatable {
    case idle
    case loadingAccess
    case ready
    case failed
}

/// Session-owned state for the independent media product surface.
///
/// Root metadata is refreshed through the same authenticated directory
/// boundary as Files. Each section owns a separate browser so switching between
/// photos, albums, and videos does not destroy pagination or navigation state.
/// Unreadable roots are never listed, and revocation clears cached item names.
@MainActor
public final class MediaLibraryModel: ObservableObject {
    @Published public private(set) var selectedSection: MediaLibrarySection = .images
    @Published public private(set) var phase: MediaLibraryPhase = .idle
    @Published public private(set) var failure: DirectoryBrowserFailure?
    @Published private var roots: [MediaLibrarySection: DirectoryBrowserItem] = [:]
    @Published private var permissionRequiredSections = Set<MediaLibrarySection>()

    public let imagesBrowser: DirectoryBrowserModel
    public let albumsBrowser: DirectoryBrowserModel
    public let videosBrowser: DirectoryBrowserModel

    public var selectedBrowser: DirectoryBrowserModel {
        browser(for: selectedSection)
    }

    public var selectedRoot: DirectoryBrowserItem? {
        roots[selectedSection]
    }

    public var selectedSectionRequiresPermission: Bool {
        permissionRequiredSections.contains(selectedSection)
    }

    private let client: any DirectoryBrowserClient
    private var accessTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var sectionsAwaitingReload = Set<MediaLibrarySection>()

    public init(client: any DirectoryBrowserClient) {
        self.client = client
        imagesBrowser = DirectoryBrowserModel(client: client)
        albumsBrowser = DirectoryBrowserModel(client: client)
        videosBrowser = DirectoryBrowserModel(client: client)
    }

    deinit {
        accessTask?.cancel()
    }

    public func start() {
        guard phase == .idle else { return }
        requestAccess(invalidateLoadedBrowsers: false)
    }

    /// Revalidates when the media surface becomes visible, without replacing an
    /// access request that is already in flight from session assembly.
    public func activate() {
        guard phase != .loadingAccess else { return }
        requestAccess(invalidateLoadedBrowsers: true)
    }

    public func select(_ section: MediaLibrarySection) {
        guard selectedSection != section else { return }
        browser(for: selectedSection).suspendDerivativeWork()
        selectedSection = section
        guard phase == .ready,
              !permissionRequiredSections.contains(section) else { return }
        ensureLoaded(section)
    }

    /// Responds to an authoritative permission failure from one child browser.
    /// Cached display data is removed and the section stays blocked until an
    /// explicit refresh or a later surface activation. This prevents a stale
    /// readable root from creating an unbounded root/list retry loop.
    public func requirePermission(for section: MediaLibrarySection) {
        browser(for: section).invalidateAuthorizationContent()
        permissionRequiredSections.insert(section)
    }

    /// Re-reads live root capabilities without probing a root already marked
    /// unreadable. This is the recovery path after Android permission changes.
    public func refreshAccess() {
        requestAccess(invalidateLoadedBrowsers: true)
    }

    private func requestAccess(invalidateLoadedBrowsers: Bool) {
        if invalidateLoadedBrowsers {
            permissionRequiredSections = []
            for section in MediaLibrarySection.allCases {
                let browser = browser(for: section)
                guard browser.query != nil else { continue }
                browser.invalidateAuthorizationContent()
                sectionsAwaitingReload.insert(section)
            }
        }
        generation &+= 1
        let operationGeneration = generation
        accessTask?.cancel()
        failure = nil
        phase = .loadingAccess
        let client = self.client
        accessTask = Task { [weak self] in
            do {
                let page = try await client.listDirectoryPage(
                    query: DirectoryListingQuery(path: "dm://roots/", pageSize: 1_000),
                    pageToken: nil
                )
                guard !Task.isCancelled else { return }
                self?.apply(page, generation: operationGeneration)
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                self?.applyFailure(
                    DirectoryListingError.remote(.cancelled),
                    generation: operationGeneration
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyFailure(error, generation: operationGeneration)
            }
        }
    }

    private func apply(_ page: DirectoryListingPage, generation: UInt64) {
        guard generation == self.generation else { return }
        var refreshed: [MediaLibrarySection: DirectoryBrowserItem] = [:]
        for entry in page.entries {
            guard let section = MediaLibrarySection.allCases.first(where: {
                $0.rootPath == entry.path
            }) else { continue }
            refreshed[section] = DirectoryBrowserItem(entry)
        }
        roots = refreshed
        accessTask = nil
        failure = nil
        phase = .ready

        for section in MediaLibrarySection.allCases {
            guard refreshed[section]?.canBrowse == true else {
                browser(for: section).reset()
                sectionsAwaitingReload.remove(section)
                continue
            }
            let browser = browser(for: section)
            if sectionsAwaitingReload.remove(section) != nil,
               let query = browser.query {
                browser.load(query)
            }
        }
        ensureLoaded(selectedSection)
    }

    private func applyFailure(_ error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        accessTask = nil
        failure = DirectoryBrowserPolicy.presentationFailure(error)
        phase = .failed
    }

    private func ensureLoaded(_ section: MediaLibrarySection) {
        guard !permissionRequiredSections.contains(section),
              let root = roots[section], root.canBrowse else { return }
        let browser = browser(for: section)
        guard browser.query == nil else { return }
        browser.load(DirectoryListingQuery(path: root.path))
    }

    private func browser(for section: MediaLibrarySection) -> DirectoryBrowserModel {
        switch section {
        case .images: return imagesBrowser
        case .albums: return albumsBrowser
        case .videos: return videosBrowser
        }
    }
}
