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

    /// Timestamp of the last successful balance fetch, for relative "x ago" display.
    @Published var lastUpdated: Date?

    /// Whether an API key is currently stored in the Keychain.
    @Published var hasAPIKey: Bool

    private let checker = CreditsChecker()

    init() {
        let storedKey = KeychainHelper.load()
        apiKeyInput = storedKey ?? ""
        hasAPIKey = (storedKey ?? "").isEmpty == false
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Balance

    /// `true` when there is no stored API key and no balance yet (onboarding state).
    var needsOnboarding: Bool {
        !hasAPIKey && balance == nil && errorMessage == nil
    }

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

    /// A human-readable relative time for the last update, e.g. "2m ago".
    var relativeUpdateText: String? {
        guard let lastUpdated else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastUpdated, relativeTo: Date())
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
            errorMessage = nil
            do {
                let result = try await checker.fetchBalance(apiKey: key)
                balance = result
                lastUpdated = Date()
            } catch {
                balance = nil
                errorMessage = error.localizedDescription
                lastUpdated = nil
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
            hasAPIKey = false
            balance = nil
            errorMessage = nil
            lastUpdated = nil
        } else {
            KeychainHelper.save(key)
            hasAPIKey = true
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
///
/// Redesigned with a card-based layout, a hero balance ring, animated numeric
/// transitions, a collapsible API-key section, and a polished footer. All
/// underlying ViewModel logic (API calls, Keychain, launch-at-login) is
/// unchanged — only the presentation layer has been rewritten.
struct MenuView: View {
    @ObservedObject var viewModel: ViewModel

    /// Controls whether the API-key disclosure section is expanded.
    @State private var isAPIKeyExpanded: Bool = false
    /// Drives the popover content entrance animation.
    @State private var appeared: Bool = false

    private let hyperAccent = Color(
        red: 0.906, green: 0.345, blue: 0.078, opacity: 1.0
    )

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroSection
                if viewModel.needsOnboarding {
                    onboardingCard
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let error = viewModel.errorMessage {
                    errorCard(error)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                apiKeySection
                footerSection
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 320, height: 460)
        .background(
            ZStack {
                // Subtle radial glow tinted by the balance color.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                viewModel.balanceColor.opacity(0.10),
                                Color.clear,
                            ],
                            center: .top,
                            startRadius: 10,
                            endRadius: 260
                        )
                    )
                    .blur(radius: 20)
                    .offset(y: -60)
                Color(nsColor: .windowBackgroundColor)
            }
            .ignoresSafeArea()
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .animation(.easeOut(duration: 0.28), value: appeared)
        .onAppear { appeared = true }
        .animation(.easeInOut(duration: 0.3), value: viewModel.balance)
        .animation(.easeInOut(duration: 0.3), value: viewModel.errorMessage)
        .animation(.easeInOut(duration: 0.3), value: viewModel.needsOnboarding)
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 8) {
            ZStack {
                BalanceRingView(
                    balance: viewModel.balance,
                    color: viewModel.balanceColor,
                    isLoading: viewModel.isLoading
                )
                .frame(width: 120, height: 120)

                VStack(spacing: 2) {
                    if viewModel.isLoading && viewModel.balance == nil {
                        ProgressView()
                            .scaleEffect(0.9)
                    } else if let balance = viewModel.balance {
                        Text("\(balance)")
                            .font(.system(size: 38, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(viewModel.balanceColor)
                            .contentTransition(.numericTransition(for: Double(balance)))
                    } else if viewModel.needsOnboarding {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 34, weight: .bold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("?")
                            .font(.system(size: 38, weight: .heavy, design: .rounded))
                            .foregroundColor(.secondary)
                    }

                    Text("credits")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .tracking(1.2)
                }
            }
            .padding(.top, 4)

            // Last-updated + refresh row
            HStack(spacing: 6) {
                if let relative = viewModel.relativeUpdateText {
                    Label(relative, systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                } else if viewModel.isLoading {
                    Text("Updating…")
                } else {
                    Text("Not yet updated")
                }
            }
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundStyle(.tertiary)

            refreshButton
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(viewModel.balanceColor.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
    }

    // MARK: - Refresh button

    private var refreshButton: some View {
        Button(action: { viewModel.refresh() }) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                    .symbolRenderingMode(.hierarchical)
                    .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                    .animation(
                        viewModel.isLoading
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .easeOut(duration: 0.3),
                        value: viewModel.isLoading
                    )
                Text(viewModel.isLoading ? "Refreshing" : "Refresh")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(hyperAccent.opacity(viewModel.isLoading ? 0.15 : 0.12))
            )
            .foregroundColor(hyperAccent)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoading)
    }

    // MARK: - Onboarding

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(hyperAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to HyperCredits")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("Connect your account to see your balance here.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isAPIKeyExpanded = true
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Add your API key")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(hyperAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hyperAccent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hyperAccent.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Error

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red.opacity(0.8))
                Text(message)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(.red.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: { viewModel.refresh() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                    Text("Retry")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundColor(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.red.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.red.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - API key section

    private var apiKeySection: some View {
        DisclosureGroup(isExpanded: $isAPIKeyExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(hyperAccent)
                    SecureField("sk-…", text: $viewModel.apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                }
                Button(action: { viewModel.saveAPIKey() }) {
                    Text("Save API Key")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(hyperAccent.opacity(viewModel.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.3 : 1.0))
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text(viewModel.hasAPIKey ? "API Key saved" : "API Key")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                if viewModel.hasAPIKey {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
        }
        .accentColor(hyperAccent)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 8) {
            // Launch at login
            HStack {
                Label("Launch at Login", systemImage: "arrow.up.forward.square")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .symbolRenderingMode(.hierarchical)
                Spacer()
                Toggle("", isOn: $viewModel.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
            )

            // Links row
            HStack(spacing: 0) {
                if let url = URL(string: "https://hyper.charm.land") {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10, weight: .semibold))
                            Text("hyper.charm.land")
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 4)

            // Version
            Text("HyperCredits \(appVersion)")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    /// Reads the marketing version + build from the main bundle.
    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(v).\(b)"
    }
}

// MARK: - Numeric content transition helper

private extension ContentTransition {
    /// Returns a numeric content transition suitable for animating balance changes.
    static func numericTransition(for value: Double) -> ContentTransition {
        .numeric(value: value)
    }
}
