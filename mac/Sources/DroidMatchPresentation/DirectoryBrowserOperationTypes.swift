import DroidMatchCore
import Foundation

extension DirectoryBrowserModel {
    enum Operation {
        case initial
        case refresh
        case nextPage(requestedToken: String)
    }

    struct NavigationLocation {
        let query: DirectoryListingQuery
        let directory: DirectoryBrowserItem?
    }

    struct PreviewRequest: Equatable {
        let operationID: UInt64
        let thumbnailGeneration: UInt64
        let path: String
        let context: DirectoryPreviewContext
    }
}
