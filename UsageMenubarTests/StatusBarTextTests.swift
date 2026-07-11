import XCTest
@testable import UsageMenubar

/// The menu bar title and the Claude number it is built from.
///
/// Balances are kept under 1,000 so the assertions don't depend on the grouping
/// separator of whatever locale the test happens to run in.
@MainActor
final class StatusBarTextTests: XCTestCase {

    // MARK: - Title

    func testBothServices() {
        let title = ViewModel.statusBarText(balance: 42, isLoading: false, claudePercent: 62)
        XCTAssertEqual(title, "⚡42 · 62%")
    }

    func testHyperOnly() {
        let title = ViewModel.statusBarText(balance: 42, isLoading: false, claudePercent: nil)
        XCTAssertEqual(title, "⚡42")
    }

    func testClaudeOnly() {
        let title = ViewModel.statusBarText(balance: nil, isLoading: false, claudePercent: 62)
        XCTAssertEqual(title, "62%")
    }

    func testLoadingWithNothingToShow() {
        let title = ViewModel.statusBarText(balance: nil, isLoading: true, claudePercent: nil)
        XCTAssertEqual(title, "⚡…")
    }

    func testNothingToShow() {
        let title = ViewModel.statusBarText(balance: nil, isLoading: false, claudePercent: nil)
        XCTAssertEqual(title, "⚡?")
    }

    /// The placeholders only stand in for an *empty* title. Someone who runs Claude Code
    /// without a Hyper key refreshes every few minutes, and a title that fell back to `⚡…`
    /// each time would blink their percentage away and back.
    func testLoadingKeepsAClaudePercentOnScreen() {
        let title = ViewModel.statusBarText(balance: nil, isLoading: true, claudePercent: 62)
        XCTAssertEqual(title, "62%")
    }

    func testLoadingKeepsAStaleBalanceOnScreen() {
        let title = ViewModel.statusBarText(balance: 42, isLoading: true, claudePercent: 62)
        XCTAssertEqual(title, "⚡42 · 62%")
    }

    func testZeroPercentIsShownRatherThanOmitted() {
        let title = ViewModel.statusBarText(balance: 42, isLoading: false, claudePercent: 0)
        XCTAssertEqual(title, "⚡42 · 0%")
    }

    // MARK: - Claude Headline

    func testHeadlinePrefersTheActiveLimit() {
        let usage = ClaudeUsage(
            fiveHour: UsageWindow(utilization: 12),
            sevenDay: nil,
            sevenDayOpus: nil,
            limits: [
                Limit(percent: 12, isActive: false),
                Limit(percent: 68, isActive: true)
            ]
        )
        XCTAssertEqual(ViewModel.claudeHeadline(for: usage)?.percent, 68)
    }

    /// Below the thresholds the server flags no limit at all, and the 5-hour window
    /// stands in — rounded, because the title has no room for a decimal.
    func testHeadlineFallsBackToTheRoundedFiveHourWindow() {
        let usage = ClaudeUsage(
            fiveHour: UsageWindow(utilization: 61.6),
            sevenDay: UsageWindow(utilization: 4),
            sevenDayOpus: nil,
            limits: []
        )
        XCTAssertEqual(ViewModel.claudeHeadline(for: usage)?.percent, 62)
    }

    func testHeadlineIsNilWithoutUsage() {
        XCTAssertNil(ViewModel.claudeHeadline(for: nil))
    }

    /// The endpoint answers `{}` for an account that has never used the plan.
    func testHeadlineIsNilForAnEmptyPayload() {
        let usage = ClaudeUsage(fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, limits: nil)
        XCTAssertNil(ViewModel.claudeHeadline(for: usage))
    }
}
