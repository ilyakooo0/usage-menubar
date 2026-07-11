import Foundation
import SwiftUI
import Combine
import ServiceManagement
import UserNotifications

/// The view model that drives the menu bar display and the popover content.
final class ViewModel: ObservableObject {
    /// The last known balance. `nil` when there has never been a successful fetch.
    @Published var balance: Int?

    /// `true` while a network request is in flight.
    @Published var isLoading = false

    /// A human-readable error message, shown when the balance can't be fetched.
    @Published var errorMessage: String?

    /// The API key entered by the user (loaded from Keychain on init).
    @Published var apiKeyInput: String = ""

    /// Timestamp of the last successful balance fetch.
    @Published var lastUpdated: Date?

    /// Brief "✓ Saved" confirmation shown after saving the API key.
    @Published var savedConfirmation: Bool = false

    /// Whether launch-at-login is enabled.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isInitializingLaunchAtLogin else { return }
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    /// Flag to suppress the didSet during initial setup.
    private var isInitializingLaunchAtLogin = true

    private let checker: CreditsChecking

    init(checker: CreditsChecking = CreditsChecker()) {
        self.checker = checker
        apiKeyInput = KeychainHelper.load() ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isInitializingLaunchAtLogin = false
    }

    // MARK: - Balance

    /// Formats an integer with thousands grouping separator.
    private func formatBalance(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// The text to show in the menu bar: `⚡…` while loading, `⚡?` when no balance, `⚡{balance}` otherwise.
    var statusBarItemText: String {
        if isLoading && balance == nil {
            return "⚡…"
        }
        if let balance = balance {
            return "⚡\(formatBalance(balance))"
        }
        return "⚡?"
    }

    /// The formatted balance string for display in the popover.
    var formattedBalance: String {
        guard let balance = balance else { return "?" }
        return formatBalance(balance)
    }

    /// The color for the balance display based on thresholds.
    var balanceColor: Color {
        guard let balance = balance else { return .secondary }
        if balance >= 100 { return .green }
        if balance >= 10 { return .yellow }
        return .red
    }

    /// Relative time string for the last successful update, or nil if never updated.
    var lastUpdatedText: String? {
        guard let lastUpdated = lastUpdated else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Updated \(formatter.localizedString(for: lastUpdated, relativeTo: Date()))"
    }

    /// Refreshes the balance from the API. No-op if no API key is set.
    func refresh() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            balance = nil
            errorMessage = nil
            lastUpdated = nil
            return
        }

        Task { @MainActor in
            isLoading = true
            // Don't clear errorMessage here — keep showing the last error
            // until we have a successful result.
            do {
                let result = try await checker.fetchBalance(apiKey: key)
                // Check for low-balance threshold crossing before updating
                let previousBalance = balance
                balance = result
                errorMessage = nil
                lastUpdated = Date()
                isLoading = false

                // Low-balance notification: only on threshold crossing (≥10 → <10)
                if let prev = previousBalance, prev >= 10, result < 10 {
                    sendLowBalanceNotification(balance: result)
                }
            } catch {
                // Keep the stale balance value — don't wipe it on error.
                // Only set balance = nil if there was never a successful fetch
                // (it's already nil in that case, so nothing to do).
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    // MARK: - Low Balance Notification

    private func sendLowBalanceNotification(balance: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Low Hyper Credits"
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let balanceStr = formatter.string(from: NSNumber(value: balance)) ?? "\(balance)"
            content.body = "Low Hyper credits: \(balanceStr) remaining"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "low-balance-alert",
                content: content,
                trigger: nil
            )
            center.add(request)
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
            lastUpdated = nil
        } else {
            KeychainHelper.save(key)
            refresh()
        }

        // Show "✓ Saved" confirmation, auto-reset after 2 seconds
        savedConfirmation = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            savedConfirmation = false
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
                } else if viewModel.balance != nil {
                    Text(viewModel.formattedBalance)
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

            // Last updated time
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
                if viewModel.savedConfirmation {
                    Text("✓ Saved")
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.savedConfirmation)
    }
}
