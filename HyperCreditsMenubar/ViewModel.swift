import Foundation
import SwiftUI
import Combine
import ServiceManagement
import UserNotifications

/// Posted when the user changes the refresh interval, so the app delegate can
/// restart its timer with the new period.
extension Notification.Name {
    static let refreshIntervalDidChange = Notification.Name("com.ilyakooo0.hyper-credits-menubar.refreshIntervalDidChange")
}

/// The direction the balance has moved over the most recent history points.
enum BalanceTrend {
    case increasing
    case decreasing
    case stable
    /// Not enough history to say.
    case unknown

    /// SF Symbol for the trend, or `nil` when there is nothing worth showing.
    var symbolName: String? {
        switch self {
        case .increasing: return "arrow.up.right"
        case .decreasing: return "arrow.down.right"
        case .stable: return "arrow.right"
        case .unknown: return nil
        }
    }
}

/// A single balance observation.
struct BalancePoint: Equatable {
    let date: Date
    let balance: Int
}

/// How often the balance is refreshed. Lives outside `ViewModel` so the view and
/// the app delegate can read the options without hopping onto the main actor.
enum RefreshInterval {
    /// `UserDefaults` key for the refresh period, in minutes.
    static let defaultsKey = "refreshIntervalMinutes"

    /// The intervals offered in the settings picker.
    static let options = [1, 5, 15, 30]

    /// Used when nothing valid is stored.
    static let defaultMinutes = 5

    /// Reads the stored interval, falling back to the default when unset or when
    /// the stored value isn't one we offer.
    static func stored(in defaults: UserDefaults = .standard) -> Int {
        let minutes = defaults.integer(forKey: defaultsKey)
        guard options.contains(minutes) else { return defaultMinutes }
        return minutes
    }
}

/// The view model that drives the menu bar display and the popover content.
@MainActor
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

    /// Brief "✓ Copied" confirmation shown after copying the balance.
    @Published var copiedConfirmation: Bool = false

    /// Successful balance observations from the last 24 hours, oldest first.
    @Published private(set) var history: [BalancePoint] = []

    /// How often the balance is refreshed, in minutes. Persisted to `UserDefaults`;
    /// changing it posts `.refreshIntervalDidChange` so the app delegate can
    /// restart its timer.
    @Published var refreshIntervalMinutes: Int {
        didSet {
            guard refreshIntervalMinutes != oldValue else { return }
            defaults.set(refreshIntervalMinutes, forKey: RefreshInterval.defaultsKey)
            NotificationCenter.default.post(name: .refreshIntervalDidChange, object: nil)
        }
    }

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
    private let defaults: UserDefaults

    /// The currently in-flight refresh task, if any. Used to cancel
    /// overlapping refreshes (timer + user click + wake).
    private var refreshTask: Task<Void, Never>?

    /// Resets `copiedConfirmation`; held so rapid clicks re-arm the delay
    /// instead of the first click's reset firing early.
    private var copiedResetTask: Task<Void, Never>?

    // MARK: - History Configuration

    /// 24 hours at the shortest (1 minute) interval would overflow this, so the
    /// count cap and the age cutoff both apply; whichever bites first wins.
    private static let maxHistoryEntries = 300
    private static let historyWindow: TimeInterval = 24 * 60 * 60

    init(checker: CreditsChecking = CreditsChecker(), defaults: UserDefaults = .standard) {
        self.checker = checker
        self.defaults = defaults
        apiKeyInput = KeychainHelper.load() ?? ""
        // Assigning in init doesn't fire didSet, so this load doesn't re-post
        // the change notification or write back to defaults.
        refreshIntervalMinutes = RefreshInterval.stored(in: defaults)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isInitializingLaunchAtLogin = false
    }

    // MARK: - Balance

    /// Cached number formatter for balance display.
    private static let balanceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// Formats an integer with thousands grouping separator.
    private func formatBalance(_ value: Int) -> String {
        Self.balanceFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
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

    // MARK: - History

    /// The last 24 hours of successful fetches, oldest first.
    var balanceHistory: [(date: Date, balance: Int)] {
        history.map { (date: $0.date, balance: $0.balance) }
    }

    /// The direction of travel across the most recent handful of observations.
    /// `.unknown` until there are at least two points to compare.
    var balanceTrend: BalanceTrend {
        guard history.count >= 2 else { return .unknown }
        let recent = history.suffix(5)
        guard let first = recent.first, let last = recent.last else { return .unknown }
        if last.balance > first.balance { return .increasing }
        if last.balance < first.balance { return .decreasing }
        return .stable
    }

    /// Appends an observation and drops anything older than 24 hours or beyond the cap.
    private func recordHistory(balance: Int, at date: Date) {
        history.append(BalancePoint(date: date, balance: balance))

        let cutoff = date.addingTimeInterval(-Self.historyWindow)
        history.removeAll { $0.date < cutoff }

        if history.count > Self.maxHistoryEntries {
            history.removeFirst(history.count - Self.maxHistoryEntries)
        }
    }

    // MARK: - Refresh

    /// Refreshes the balance from the API. No-op if no API key is set.
    /// Cancels any previously in-flight refresh to prevent races.
    func refresh() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            balance = nil
            errorMessage = nil
            lastUpdated = nil
            return
        }

        refreshTask?.cancel()

        refreshTask = Task { @MainActor in
            isLoading = true
            // Don't clear errorMessage here — keep showing the last error
            // until we have a successful result.
            do {
                let result = try await checker.fetchBalance(apiKey: key)
                // Check for cancellation after the await
                guard !Task.isCancelled else { return }
                // Check for low-balance threshold crossing before updating
                let previousBalance = balance
                balance = result
                errorMessage = nil
                let now = Date()
                lastUpdated = now
                recordHistory(balance: result, at: now)
                isLoading = false

                // Low-balance notification: on threshold crossing (≥10 → <10)
                // OR on first successful fetch if already below threshold.
                if let prev = previousBalance, prev >= 10, result < 10 {
                    sendLowBalanceNotification(balance: result)
                } else if previousBalance == nil && result < 10 {
                    sendLowBalanceNotification(balance: result)
                }
            } catch {
                // Keep the stale balance value — don't wipe it on error.
                // Only set balance = nil if there was never a successful fetch
                // (it's already nil in that case, so nothing to do).
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    // MARK: - Clipboard

    /// Copies the current balance to the clipboard as plain digits (no grouping
    /// separator), and shows a brief "✓ Copied" confirmation.
    func copyBalanceToClipboard() {
        guard let balance = balance else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(balance), forType: .string)

        copiedConfirmation = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copiedConfirmation = false
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
            let balanceStr = Self.balanceFormatter.string(from: NSNumber(value: balance)) ?? "\(balance)"
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
    /// Shows "✓ Saved" on success, or an error message if the keychain rejected the key.
    func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            KeychainHelper.delete()
            balance = nil
            errorMessage = nil
            lastUpdated = nil
        } else {
            let saved = KeychainHelper.save(key)
            guard saved else {
                errorMessage = "Could not save API key to Keychain. It may be locked."
                return
            }
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
