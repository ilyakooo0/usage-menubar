import SwiftUI
import Combine
import UserNotifications

/// Main app delegate that manages the menu bar item, the refresh timer,
/// the SwiftUI popover hosting `MenuView`, and sleep/wake handling.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var refreshTimer: Timer?

    /// The shared view model. Shared between the menu bar and the popover.
    let viewModel = ViewModel()

    /// Combine cancellables for observing published changes.
    private var statusTextCancellable: AnyCancellable?

    private let refreshInterval: TimeInterval = 5 * 60 // 5 minutes

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission for low-balance alerts
        requestNotificationPermission()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = nil
            button.title = "⚡?"
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Create popover with SwiftUI content
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView(viewModel: viewModel))

        // Observe published changes (balance + isLoading) to update the menu bar title.
        // CombineLatest fires when either published property changes.
        statusTextCancellable = Publishers.CombineLatest(viewModel.$balance, viewModel.$isLoading)
            .map { [weak viewModel] _, _ in viewModel?.statusBarItemText ?? "⚡?" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.statusItem.button?.title = text
            }

        // Register for sleep/wake notifications
        registerSleepWakeNotifications()

        // Initial fetch
        viewModel.refresh()

        // Start periodic refresh
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.viewModel.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        statusTextCancellable?.cancel()
    }

    // MARK: - Notification Permission

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Permission result is handled silently; notifications are optional.
        }
    }

    // MARK: - Sleep / Wake

    private func registerSleepWakeNotifications() {
        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter

        notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        // Nothing to do on sleep; timer will pause naturally.
    }

    @objc private func systemDidWake(_ notification: Notification) {
        // Refresh after wake to get a fresh balance.
        viewModel.refresh()
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func closePopover() {
        popover.performClose(nil)
    }
}

// MARK: - App Entry Point

@main
struct HyperCreditsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
