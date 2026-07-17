import DroidMatchPresentation

/// Localizes only DroidMatch-owned virtual roots by canonical path.
///
/// Provider and user-controlled names (including SAF roots and all files) retain
/// their provider identity and cross the shared safe-display projection; matching
/// their visible text for localization would silently relabel unrelated content.
enum FileEntryDisplayName {
    static func value(_ entry: DirectoryBrowserItem) -> String {
        switch entry.path {
        case "dm://media-images/": return AppStrings.images
        case "dm://media-images/albums/": return AppStrings.imageAlbums
        case "dm://media-videos/": return AppStrings.videos
        case "dm://app-sandbox/": return AppStrings.appSandbox
        default: return entry.safeDisplayName ?? AppStrings.unnamedItem
        }
    }
}
