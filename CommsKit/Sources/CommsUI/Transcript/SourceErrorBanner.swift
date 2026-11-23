import SwiftUI

/// The inline banner under the transcript header while the source cannot answer:
/// "Can't reach WhatsApp right now" with a Retry button. Glass, as a floating control.
public struct SourceErrorBanner: View {
    let message: String
    let retry: @MainActor () async -> Void

    public init(message: String, retry: @escaping @MainActor () async -> Void) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Button("Retry") { Task { await retry() } }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}
