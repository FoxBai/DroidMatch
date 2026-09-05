import AppKit
import SwiftUI

struct ProductRefreshAction {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void
}

private struct ProductRefreshActionKey: FocusedValueKey {
    typealias Value = ProductRefreshAction
}

extension FocusedValues {
    var productRefreshAction: ProductRefreshAction? {
        get { self[ProductRefreshActionKey.self] }
        set { self[ProductRefreshActionKey.self] = newValue }
    }
}

/// The visible page supplies its existing action; no hidden page is a fallback.
/// 当前页面提供已有刷新动作；不回退到后台页面。
struct ProductRefreshCommands: Commands {
    let isRuntimeAvailable: () -> Bool
    @FocusedValue(\.productRefreshAction) private var refreshAction

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(refreshAction?.title ?? AppStrings.refresh) {
                guard canRefresh else { return }
                refreshAction?.perform()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!canRefresh)
        }
    }

    private var canRefresh: Bool {
        guard isRuntimeAvailable(), refreshAction?.isEnabled == true,
              let window = NSApp.keyWindow else { return false }
        // Scene values can survive a sheet becoming key. Recheck at invocation.
        // sheet 成为 key window 时场景值可能仍存在，执行时再次检查。
        return window.attachedSheet == nil && window.sheetParent == nil
            && NSApp.modalWindow == nil
    }
}
