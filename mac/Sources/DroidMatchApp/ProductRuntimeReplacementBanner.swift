import AppKit
import SwiftUI

/// A stale process is blocked from starting more device or Keychain work. The
/// user explicitly quits, then opens the already-published App normally.
struct ProductRuntimeReplacementBanner: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppStrings.runningAppWasReplaced)
                    .font(.headline)
                Text(AppStrings.runningAppWasReplacedDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(AppStrings.quitDroidMatch) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
