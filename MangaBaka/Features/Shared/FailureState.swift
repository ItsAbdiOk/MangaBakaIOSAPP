import SwiftUI

/// A whole-screen failure, shown only when there is genuinely nothing to
/// display. Anywhere content exists, the content wins and the reason becomes a
/// quiet banner instead.
struct FailureState: View {
    let error: APIError
    var retry: (() async -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: error.symbolName)
                .font(.system(size: 30))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            Text(headline)
                .typeSubsectionHeader()
                .foregroundStyle(Palette.textPrimary)

            Text(error.userFacingMessage)
                .typeSubtitle()
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)

            if case .rateLimited = error {
                Text("""
                The limit is shared with everyone on your network, so this \
                can happen even when you have barely used the app.
                """)
                .typeFootnote()
                .foregroundStyle(Palette.textQuaternary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
            }

            if let retry {
                Button("Try again") { Task { await retry() } }
                    .typeCTA()
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 18)
                    .frame(height: Metrics.ctaSecondary)
                    .background(Palette.accent, in: Capsule())
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 60)
    }

    private var headline: String {
        switch error {
        case .offline: "You're offline"
        case .rateLimited: "Too many requests, briefly"
        case .server: "MangaBaka had a problem"
        case .decoding, .transport: "Something went wrong"
        }
    }
}

/// A quiet banner above content that may be out of date, used instead of an
/// error page whenever there is anything at all to show.
struct StaleBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Palette.positive)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(message)
                .typeSmallMeta()
                .foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.gutter)
    }
}
