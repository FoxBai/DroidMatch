import SwiftUI

enum ProductHelpWindow {
    static let id = "product-help"
}

struct ProductHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // The standard macOS Help item expects a Help Book. DroidMatch ships a
        // local SwiftUI guide instead, so replace that item rather than leaving
        // a system menu action that ends in "help not found."
        CommandGroup(replacing: .help) {
            Button(AppStrings.helpMenuTitle) {
                openWindow(id: ProductHelpWindow.id)
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

struct ProductHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 16) {
                    ProductHelpSection(
                        symbol: "cable.connector.horizontal",
                        title: AppStrings.helpGetConnected,
                        points: [
                            AppStrings.helpEnableSecureUSB,
                            AppStrings.helpApproveADB,
                            AppStrings.helpComparePairingCode,
                        ]
                    )
                    ProductHelpSection(
                        symbol: "folder.badge.gearshape",
                        title: AppStrings.helpBrowseAndTransfer,
                        points: [
                            AppStrings.helpUseFilesAndMedia,
                            AppStrings.helpPermissionsAreLive,
                            AppStrings.helpUseTransfers,
                        ]
                    )
                    ProductHelpSection(
                        symbol: "wrench.and.screwdriver",
                        title: AppStrings.helpTroubleshooting,
                        points: [
                            AppStrings.helpNoDevice,
                            AppStrings.helpAuthenticationFailed,
                            AppStrings.helpInterruptedTransfer,
                        ]
                    )
                    ProductHelpSection(
                        symbol: "hand.raised.fill",
                        title: AppStrings.helpPrivacy,
                        points: [
                            AppStrings.helpLocalUSB,
                            AppStrings.helpSerialPrivacy,
                            AppStrings.helpKeychainPrivacy,
                            AppStrings.helpKeychainConnectionPrompt,
                        ]
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(ProductAccessibilityIdentifiers.helpWindow)
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(AppStrings.helpWindowTitle)
                    .font(.title.bold())
                Text(AppStrings.helpSubtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProductHelpSection: View {
    let symbol: String
    let title: String
    let points: [String]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(point)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label(title, systemImage: symbol)
                .font(.headline)
        }
    }
}
