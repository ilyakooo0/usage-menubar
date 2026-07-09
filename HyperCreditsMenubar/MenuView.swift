import Foundation
import SwiftUI
import Combine
import ServiceManagement

/// The view model that drives the menu bar display and the popover content.
final class ViewModel: ObservableObject {
    /// The last known balance. `nil` when loading, error, or no API key.
    @Published var balance: Int?

    /// `true` while a network request is in flight.
    @Published var isLoading = false

    /// A human-readable error message, shown when the balance can't be fetched.
    @Published var errorMessage: String?

    /// The API key entered by the user (loaded from Keychain on init).
    @Published var apiKeyInput: String = ""

    /// Whether launch-at-login is enabled.
    @Published var launchAtLogin: Bool {
        didSet {
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    private let checker = CreditsChecker()

    init() {
        apiKeyInput = KeychainHelper.load() ?? ""
        launchAtLogin = SMAppService.mainApp.status == .registered
    }

    // MARK: - Balance

    /// The text to show in the menu bar: `⚡{balance}` or `⚡?`.
    var statusBarItemText: String {
        if let balance = balance {
            return "⚡\(balance)"
        }
        return "⚡?"
    }

    /// The color for the balance display based on thresholds.
    var balanceColor: Color {
        guard let balance = balance else { return .secondary }
        if balance >= 100 { return .green }
        if balance >= 10 { return .yellow }
        return .red
    }

    /// Refreshes the balance from the API. No-op if no API key is set.
    func refresh() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            balance = nil
            errorMessage = nil
            return
        }

        Task { @MainActor in
            isLoading = true
            errorMessage = nil
            do {
                let result = try await checker.fetchBalance(apiKey: key)
                balance = result
            } catch {
                balance = nil
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    // MARK: - API Key

    /// Saves the current `apiKeyInput` to the Keychain and triggers a refresh.
    func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            KeychainHelper.delete()
            balance = nil
            errorMessage = nil
        } else {
            KeychainHelper.save(key)
            refresh()
        }
    }

    // MARK: - Launch at Login

    func updateLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - MenuView

/// The SwiftUI view shown inside the popover when the menu bar item is clicked.
struct MenuView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Balance display
            VStack(spacing: 4) {
                if viewModel.isLoading && viewModel.balance == nil {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let balance = viewModel.balance {
                    Text("\(balance)")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(viewModel.balanceColor)
                    Text("credits")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("?")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    Text("credits")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Divider()

            // Refresh button
            Button(action: { viewModel.refresh() }) {
                Label("Refresh now", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading)

            // API key section
            VStack(alignment: .leading, spacing: 6) {
                Text("API Key")
                    .font(.headline)
                HStack {
                    SecureField("sk-...", text: $viewModel.apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        viewModel.saveAPIKey()
                    }
                }
            }

            // Launch at login toggle
            Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
                .toggleStyle(.switch)

            // Links
            HStack {
                if let url = URL(string: "https://hyper.charm.land") {
                    Button("Open hyper.charm.land") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
            }

            Divider()

            // Quit
            Button("Quit HyperCredits") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 280)
    }
}
