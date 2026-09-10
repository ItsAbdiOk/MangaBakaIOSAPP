import SwiftUI

/// What this session has cost, in bytes and in milliseconds.
///
/// **Not analytics.** Nothing here is uploaded, nothing is stored, and it is
/// empty again next launch. It exists so the answer to "how heavy is this app?"
/// is a number the reader can see rather than a claim the developer makes.
///
/// It is also the only place the API's actual speed is visible. Every previous
/// answer to "is the API fast?" in this project was about response shapes.
struct DataUseSection: View {
    @State private var total = 0
    @State private var requests = 0
    @State private var images = 0
    @State private var slowest: [(path: String, entry: NetworkLedger.Entry)] = []
    @State private var isExpanded = false

    var body: some View {
        SettingsSection(title: "Data used", caption: caption) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard {
                    SettingsRow(title: "This session", caption: breakdown) {
                        Text(format(total))
                            .typeRowTitle()
                            .foregroundStyle(Palette.accent)
                    }
                }

                if !slowest.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
                    } label: {
                        Text(isExpanded ? "Hide the detail" : "The eight slowest")
                            .typeInstruction()
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        // Named as a top-eight rather than a breakdown. Read as
                        // a breakdown, the numbers do not add up to the total
                        // and the list quietly discredits itself.
                        SettingsCard {
                            ForEach(Array(slowest.enumerated()), id: \.offset) { index, row in
                                endpointRow(row)
                                if index < slowest.count - 1 { SettingsDivider() }
                            }
                        }
                    }
                }
            }
        }
        .task { await refresh() }
    }

    private var caption: String {
        """
        Counted on this phone and never sent anywhere. It resets when the app \
        closes.
        """
    }

    private var breakdown: String {
        guard requests > 0 else { return "Nothing fetched yet" }
        // Images are named separately because they are almost all of it, and
        // lumping them in hides the one number worth doing anything about.
        return "\(requests) requests · \(format(images)) of it cover art"
    }

    private func endpointRow(_ row: (path: String, entry: NetworkLedger.Entry)) -> some View {
        SettingsRow(
            title: row.path,
            caption: "\(row.entry.requests) calls · \(format(row.entry.bytes))"
        ) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(milliseconds(row.entry.averageSeconds))
                    .typeRowTitle()
                    .foregroundStyle(Palette.textPrimary)
                Text("worst \(milliseconds(row.entry.slowestSeconds))")
                    .typeFootnote()
                    .foregroundStyle(Palette.textQuaternary)
            }
        }
    }

    private func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func milliseconds(_ seconds: Double) -> String {
        seconds >= 1
            ? String(format: "%.1fs", seconds)
            : "\(Int((seconds * 1000).rounded()))ms"
    }

    private func refresh() async {
        total = await NetworkLedger.shared.totalBytes
        requests = await NetworkLedger.shared.totalRequests
        images = await NetworkLedger.shared.imageBytes
        slowest = await NetworkLedger.shared.slowest()
    }
}
