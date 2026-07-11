import DroidMatchPresentation

/// Localizes only DroidMatch-owned virtual roots by canonical path.
///
/// Provider and user-controlled names (including SAF roots and all files) must
/// remain verbatim display data; translating by matching their text would
/// silently rename unrelated user content in the interface.
enum FileEntryDisplayName {
    static func value(_ entry: DirectoryBrowserItem) -> String {
        switch entry.path {
        case "dm://media-images/": return AppStrings.images
        case "dm://media-images/albums/": return AppStrings.imageAlbums
        case "dm://media-videos/": return AppStrings.videos
        case "dm://app-sandbox/": return AppStrings.appSandbox
        default: return entry.name ?? AppStrings.unnamedItem
        }
    }
}
