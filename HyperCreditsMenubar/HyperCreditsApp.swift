import SwiftUI
import Combine

/// Main app delegate that manages the menu bar item, the refresh timer,
/// and the SwiftUI popover hosting `MenuView`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var refreshTimer: Timer?

    /// The shared view model. Shared between the menu bar and the popover.
    let viewModel = ViewModel()

    /// Combine cancellable for observing balance changes.
    private var statusTextCancellable: AnyCancellable?

    private let refreshInterval: TimeInterval = 5 * 60 // 5 minutes

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Observe balance changes to update the menu bar title
        statusTextCancellable = viewModel.$balance
            .map { [weak viewModel] _ in viewModel?.statusBarItemText ?? "⚡?" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.statusItem.button?.title = text
            }

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
