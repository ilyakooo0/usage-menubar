import SwiftUI

/// The SwiftUI view shown inside the popover when the menu bar item is clicked.
struct MenuView: View {
    @ObservedObject var viewModel: ViewModel

    private static let websiteURL = URL(string: "https://hyper.charm.land")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            settings
            footer
        }
        .padding(16)
        .frame(width: 280)
        .animation(.easeInOut(duration: 0.2), value: viewModel.savedConfirmation)
        .animation(.easeInOut(duration: 0.2), value: viewModel.copiedConfirmation)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 6) {
            if viewModel.isLoading && viewModel.balance == nil {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(height: 50)
                Text("Loading…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                balanceNumber
                caption
                sparkline
            }

            if let lastUpdatedText = viewModel.lastUpdatedText {
                Text(lastUpdatedText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The balance itself. Clicking it copies the raw number to the clipboard.
    private var balanceNumber: some View {
        Button(action: { viewModel.copyBalanceToClipboard() }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(viewModel.formattedBalance)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(viewModel.balanceColor)

                if let symbol = viewModel.balanceTrend.symbolName {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.balance == nil)
        .help("Click to copy")
    }

    /// Doubles as the copy confirmation so the layout doesn't shift.
    private var caption: some View {
        Group {
            if viewModel.copiedConfirmation {
                Text("✓ Copied")
                    .foregroundColor(.green)
            } else {
                Text("credits")
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var sparkline: some View {
        // Key paths can't index tuple elements, so this stays a closure.
        let values = viewModel.balanceHistory.map { $0.balance }
        if values.count >= 2 {
            Sparkline(values: values)
                .frame(height: 24)
                .padding(.top, 2)
        }
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API Key")
                        .font(.headline)
                    Spacer()
                    Link("Get key →", destination: Self.websiteURL)
                        .font(.caption)
                }

                HStack {
                    SecureField("sk-...", text: $viewModel.apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        viewModel.saveAPIKey()
                    }
                }

                if viewModel.savedConfirmation {
                    Text("✓ Saved")
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
            }

            HStack {
                Text("Refresh every")
                Spacer()
                Picker("Refresh every", selection: $viewModel.refreshIntervalMinutes) {
                    ForEach(RefreshInterval.options, id: \.self) { minutes in
                        Text("\(minutes)m").tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack {
                Button(action: { viewModel.refresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }

            Link("hyper.charm.land", destination: Self.websiteURL)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Sparkline

/// A minimal line chart of recent balances: no axes, no fill, no labels.
/// Points are spaced evenly by index rather than by timestamp, which keeps the
/// shape readable when fetches are irregular (wake-ups, manual refreshes).
struct Sparkline: View {
    let values: [Int]

    /// Keeps the stroke from being clipped at the top and bottom edges.
    private let verticalInset: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard values.count >= 2 else { return }

                let size = geometry.size
                let minValue = values.min() ?? 0
                let maxValue = values.max() ?? 0
                let range = Double(maxValue - minValue)

                let stepX = size.width / CGFloat(values.count - 1)
                let usableHeight = max(size.height - verticalInset * 2, 1)

                for (index, value) in values.enumerated() {
                    // A flat series has no range to normalize against; center it.
                    let normalized = range == 0 ? 0.5 : Double(value - minValue) / range
                    let point = CGPoint(
                        x: CGFloat(index) * stepX,
                        y: verticalInset + (1 - CGFloat(normalized)) * usableHeight
                    )
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(
                Color.secondary.opacity(0.5),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
    }
}
