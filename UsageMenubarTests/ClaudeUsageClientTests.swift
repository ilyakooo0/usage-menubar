import XCTest
import Foundation
@testable import UsageMenubar

/// The instant the countdown tests reckon from, so "3h 20m" is a fact rather than a race
/// against the wall clock.
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

final class ClaudeUsageClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A client whose requests are served by `StubURLProtocol` and whose credentials
    /// come from memory, so no test here touches the real Keychain, the real
    /// `~/.claude/.credentials.json`, or the network. The backoff is short enough that
    /// the retry tests run in milliseconds rather than seconds.
    private func makeClient(
        store: ClaudeCredentialStoring,
        retryBaseDelay: Duration = .milliseconds(1)
    ) -> ClaudeUsageClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClaudeUsageClient(
            session: URLSession(configuration: config),
            store: store,
            retryBaseDelay: retryBaseDelay
        )
    }

    private func credentials(
        accessToken: String = "access-1",
        subscriptionType: String? = "max"
    ) -> ClaudeOAuthCredentials {
        ClaudeOAuthCredentials(
            claudeAiOauth: .init(
                accessToken: accessToken,
                scopes: ["user:inference"],
                subscriptionType: subscriptionType,
                rateLimitTier: nil
            )
        )
    }

    private func usageJSON(fiveHour: Int = 68, sevenDay: Int = 41) -> Data {
        Data("""
        {
          "five_hour": {"utilization": \(fiveHour), "resets_at": "2023-11-14T23:53:20.000Z"},
          "seven_day": {"utilization": \(sevenDay), "resets_at": "2023-11-20T23:53:20.000Z"}
        }
        """.utf8)
    }

    // MARK: - Usage decoding

    func testDecodesUsagePayload() throws {
        let json = Data("""
        {
          "five_hour": {"utilization": 68.4, "resets_at": "2026-07-11T20:00:00.000Z"},
          "seven_day": {"utilization": 41, "resets_at": "2026-07-15T20:00:00.000Z"},
          "seven_day_opus": {"utilization": 12, "resets_at": null},
          "limits": [
            {"percent": 41, "is_active": false, "resets_at": "2026-07-15T20:00:00.000Z"},
            {"percent": 68, "is_active": true, "resets_at": "2026-07-11T20:00:00.000Z"}
          ]
        }
        """.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertEqual(usage.fiveHour?.utilization, 68.4)
        XCTAssertEqual(usage.sevenDay?.utilization, 41)
        XCTAssertEqual(usage.sevenDayOpus?.utilization, 12)
        XCTAssertNil(usage.sevenDayOpus?.resetsAt)
        XCTAssertEqual(usage.limits?.count, 2)
        XCTAssertFalse(usage.isEmpty)
    }

    func testDecodesEmptyPayload() throws {
        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: Data("{}".utf8))

        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.limits)
        XCTAssertTrue(usage.isEmpty, "An account with no usage has nothing worth a section")
    }

    func testIgnoresWindowsItDoesNotModel() throws {
        // Anthropic adds and retires windows without notice; an unknown one must not
        // take the rest of the payload down with it.
        let json = Data("""
        {
          "five_hour": {"utilization": 5},
          "tangelo": {"utilization": 99},
          "iguana_necktie": {"utilization": 99},
          "spend": {"percent": 3, "enabled": true}
        }
        """.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertEqual(usage.fiveHour?.utilization, 5)
        XCTAssertFalse(usage.isEmpty)
    }

    func testMissingUtilizationDefaultsToZero() throws {
        let json = Data(#"{"five_hour": {"resets_at": "2026-07-11T20:00:00.000Z"}}"#.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertEqual(usage.fiveHour?.utilization, 0)
    }

    func testFractionalPercentIsRounded() throws {
        // The field is documented as an integer, but decoding it as one would throw on
        // a fractional value and lose the whole payload.
        let json = Data(#"{"limits": [{"percent": 68.6, "is_active": true}]}"#.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertEqual(usage.activeLimit?.percent, 69)
    }

    func testActiveLimitIsTheOneTheServerFlags() throws {
        let json = Data("""
        {"limits": [
          {"percent": 41, "is_active": false},
          {"percent": 68, "is_active": true}
        ]}
        """.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertEqual(usage.activeLimit?.percent, 68)
    }

    func testActiveLimitIsNilWhenNoneIsFlagged() throws {
        let json = Data(#"{"limits": [{"percent": 41}, {"percent": 12}]}"#.utf8)

        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: json)

        XCTAssertNil(usage.activeLimit)
    }

    // MARK: - Reset countdown

    func testResetsInFormatsHoursAndMinutes() {
        let window = UsageWindow(utilization: 50, resetsAt: iso(fixedNow.addingTimeInterval(3 * 3600 + 20 * 60)))

        XCTAssertEqual(window.resetsIn(from: fixedNow), "3h 20m")
    }

    func testResetsInFormatsDaysAndHours() {
        let window = UsageWindow(utilization: 50, resetsAt: iso(fixedNow.addingTimeInterval(28 * 3600)))

        XCTAssertEqual(window.resetsIn(from: fixedNow), "1d 4h")
    }

    func testResetsInFormatsMinutesAlone() {
        let window = UsageWindow(utilization: 50, resetsAt: iso(fixedNow.addingTimeInterval(12 * 60)))

        XCTAssertEqual(window.resetsIn(from: fixedNow), "12m")
    }

    func testResetsInIsNilOnceTheWindowHasPassed() {
        let window = UsageWindow(utilization: 50, resetsAt: iso(fixedNow.addingTimeInterval(-60)))

        XCTAssertNil(window.resetsIn(from: fixedNow))
    }

    func testResetsInIsNilWithoutATimestamp() {
        XCTAssertNil(UsageWindow(utilization: 0).resetsIn(from: fixedNow))
    }

    func testResetsAtParsesTimestampsWithoutFractionalSeconds() {
        // Claude's timestamps normally carry fractional seconds; this spelling has to
        // parse too, rather than silently costing us the countdown.
        let window = UsageWindow(utilization: 50, resetsAt: "2026-07-11T20:00:00Z")

        XCTAssertEqual(window.resetsAtDate?.timeIntervalSince1970, 1_783_800_000)
    }

    func testResetsAtIsNilForAnUnparseableTimestamp() {
        XCTAssertNil(UsageWindow(utilization: 50, resetsAt: "not a date").resetsAtDate)
    }

    func testLimitAlsoCountsDown() {
        let limit = Limit(percent: 68, resetsAt: iso(fixedNow.addingTimeInterval(90 * 60)), isActive: true)

        XCTAssertEqual(limit.resetsIn(from: fixedNow), "1h 30m")
    }

    // MARK: - Fetching

    func testFetchSendsTheOAuthHeaders() async throws {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(200, usageJSON()))

        let report = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(report.usage.fiveHour?.utilization, 68)
        XCTAssertEqual(report.subscriptionType, "max")

        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.url, ClaudeUsageClient.usageEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testMissingCredentialsThrowWithoutTouchingTheNetwork() async {
        let store = FakeClaudeCredentialStore(credentials: nil)

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected noCredentials error")
        } catch ClaudeUsageError.noCredentials {
            // expected — the caller reads this as "Claude Code isn't set up here"
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testTheStoredTokenIsSpentExactlyAsItIs() async throws {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(200, usageJSON()))

        _ = try await makeClient(store: store).fetchUsage()

        // One request, to the usage endpoint. No token endpoint, no grant, no rotation:
        // refreshing behind the CLI's back is what signed the user out to begin with.
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests[0].url, ClaudeUsageClient.usageEndpoint)
        XCTAssertEqual(StubURLProtocol.recordedRequests[0].httpMethod, "GET")
    }

    func testCredentialsAreReReadOnEveryFetch() async throws {
        // The CLI refreshes on its own schedule and we never do, so the only way to see
        // a new token is to go back to the store each time. Caching one would strand the
        // app on a token the CLI has long since replaced.
        let store = FakeClaudeCredentialStore(credentials: credentials(accessToken: "access-1"))
        StubURLProtocol.enqueue(.status(200, usageJSON()), .status(200, usageJSON()))

        let client = makeClient(store: store)
        _ = try await client.fetchUsage()

        store.replace(with: credentials(accessToken: "access-2"))
        _ = try await client.fetchUsage()

        XCTAssertEqual(store.loadCount, 2)
        let sent = StubURLProtocol.recordedRequests.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(sent, ["Bearer access-1", "Bearer access-2"])
    }

    // MARK: - Rejected tokens

    func testRejectedTokenSurfacesInvalidCredentialsWithoutRefreshing() async {
        // A spent or revoked token is the user's to fix by running `claude`. The app
        // attempting the refresh itself is the bug this whole client is shaped around.
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(401, Data()))

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected invalidCredentials error")
        } catch ClaudeUsageError.invalidCredentials {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            StubURLProtocol.requestCount,
            1,
            "A 401 must end the fetch — no refresh, and no retry of the request either"
        )
    }

    func testForbiddenIsTreatedAsARejectedToken() async {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(403, Data()))

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected invalidCredentials error")
        } catch ClaudeUsageError.invalidCredentials {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testTheInvalidCredentialsMessagePointsAtTheCLI() {
        // The app can't mint a token, so the only useful thing it can say is where one
        // comes from.
        let message = ClaudeUsageError.invalidCredentials.errorDescription
        XCTAssertEqual(message, "Claude sign-in expired. Run `claude` in a terminal to sign in again.")
    }

    // MARK: - Retries

    func testRetriesOnServerErrorThenSucceeds() async throws {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(
            .status(500, Data()),
            .status(503, Data()),
            .status(200, usageJSON())
        )

        let report = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(report.usage.fiveHour?.utilization, 68)
        XCTAssertEqual(StubURLProtocol.requestCount, 3)
    }

    func testRetriesOnRateLimitThenSucceeds() async throws {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(429, Data()), .status(200, usageJSON()))

        _ = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testRetriesOnNetworkErrorThenSucceeds() async throws {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.failure(URLError(.timedOut)), .status(200, usageJSON()))

        _ = try await makeClient(store: store).fetchUsage()

        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testGivesUpAfterTwoRetries() async {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(500, Data()))  // repeats

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected requestFailed error")
        } catch ClaudeUsageError.requestFailed(let message) {
            XCTAssertEqual(message, "HTTP 500")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Initial attempt + 2 retries.
        XCTAssertEqual(StubURLProtocol.requestCount, 3)
    }

    func testDoesNotRetryOnClientError() async {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(404, Data()))

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected requestFailed error")
        } catch ClaudeUsageError.requestFailed(let message) {
            XCTAssertEqual(message, "HTTP 404")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testDoesNotRetryOnDecodingFailure() async {
        let store = FakeClaudeCredentialStore(credentials: credentials())
        StubURLProtocol.enqueue(.status(200, Data("not json".utf8)))

        do {
            _ = try await makeClient(store: store).fetchUsage()
            XCTFail("Expected decodingFailed error")
        } catch ClaudeUsageError.decodingFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    // MARK: - Errors

    func testErrorsAreEquatable() {
        XCTAssertEqual(ClaudeUsageError.noCredentials, .noCredentials)
        XCTAssertNotEqual(ClaudeUsageError.noCredentials, .invalidCredentials)
        XCTAssertEqual(ClaudeUsageError.requestFailed("HTTP 500"), .requestFailed("HTTP 500"))
    }

    func testClaudeUsageClientConformsToProtocol() {
        let checker: ClaudeUsageChecking = ClaudeUsageClient()
        // If this compiles, ClaudeUsageClient conforms to ClaudeUsageChecking.
        XCTAssertNotNil(checker)
    }

    // MARK: - Helpers

    /// An ISO 8601 timestamp with fractional seconds, as Claude's API spells them.
    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Credential store

/// These drive `ClaudeCodeCredentialStore` against a throwaway file and a Keychain
/// service that cannot exist, so `security` always misses and the file fallback is what
/// gets exercised. Nothing here can read — let alone write — the real Claude Code
/// credentials, which is the whole point: a test that clobbered them would sign the
/// user out of their own CLI.
final class ClaudeCodeCredentialStoreTests: XCTestCase {

    private var directory: URL!

    /// A credentials blob as Claude Code actually writes it: the two token fields we no
    /// longer model, and two more we never did.
    private let credentialsJSON = """
    {
      "claudeAiOauth": {
        "accessToken": "access-1",
        "refreshToken": "refresh-1",
        "expiresAt": 4000000000000,
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "max",
        "somethingWeDoNotModel": "keep me"
      },
      "anotherTopLevelKey": "keep me too"
    }
    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeStore(file: URL) -> ClaudeCodeCredentialStore {
        ClaudeCodeCredentialStore(
            keychainService: "com.example.tests.absent-\(UUID().uuidString)",
            credentialsFile: file
        )
    }

    private func writeCredentialsFile() throws -> URL {
        let file = directory.appendingPathComponent(".credentials.json")
        try Data(credentialsJSON.utf8).write(to: file)
        return file
    }

    func testReadsCredentialsFromTheFileWhenTheKeychainHasNothing() throws {
        let file = try writeCredentialsFile()

        let credentials = try XCTUnwrap(makeStore(file: file).load())

        XCTAssertEqual(credentials.claudeAiOauth.accessToken, "access-1")
        XCTAssertEqual(credentials.claudeAiOauth.subscriptionType, "max")
        XCTAssertEqual(credentials.claudeAiOauth.scopes, ["user:inference", "user:profile"])
    }

    func testReturnsNilWhenThereIsNeitherAKeychainItemNorAFile() {
        let missing = directory.appendingPathComponent("nothing-here.json")

        XCTAssertNil(makeStore(file: missing).load())
    }

    func testReturnsNilForACorruptedFile() throws {
        let file = directory.appendingPathComponent(".credentials.json")
        try Data("{ not json".utf8).write(to: file)

        XCTAssertNil(makeStore(file: file).load())
    }

    func testABlobWithoutTheFieldsWeDroppedStillLoads() throws {
        // `refreshToken` and `expiresAt` are no longer modelled, so their absence must
        // not fail the decode — nor must their presence, above.
        let file = directory.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth": {"accessToken": "access-1"}}"#.utf8).write(to: file)

        let credentials = try XCTUnwrap(makeStore(file: file).load())

        XCTAssertEqual(credentials.claudeAiOauth.accessToken, "access-1")
        XCTAssertNil(credentials.claudeAiOauth.subscriptionType)
    }

    func testLoadingLeavesTheCredentialsFileByteForByteUntouched() throws {
        // The regression guard for the bug this store was built around: the app used to
        // write a rotated token back here, racing the CLI's own refresh and signing the
        // user out of their terminal. It must now be a reader and nothing else.
        let file = try writeCredentialsFile()
        let before = try Data(contentsOf: file)

        _ = makeStore(file: file).load()

        XCTAssertEqual(try Data(contentsOf: file), before)
    }
}

// MARK: - Fake credential store

/// An in-memory `ClaudeCredentialStoring`. Never goes near the Keychain or the disk.
///
/// It cannot write, because the protocol no longer can: the CLI is the only thing that
/// may rotate these tokens. `replace(with:)` is the test standing in for the CLI having
/// done exactly that behind the app's back.
final class FakeClaudeCredentialStore: ClaudeCredentialStoring {
    private let lock = NSLock()
    private var current: ClaudeOAuthCredentials?
    private var loads = 0

    init(credentials: ClaudeOAuthCredentials?) {
        current = credentials
    }

    /// How many times the client has gone back to the store — it should be once per fetch.
    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    /// Stands in for the CLI refreshing its own token between two fetches.
    func replace(with credentials: ClaudeOAuthCredentials?) {
        lock.lock()
        defer { lock.unlock() }
        current = credentials
    }

    func load() -> ClaudeOAuthCredentials? {
        lock.lock()
        defer { lock.unlock() }
        loads += 1
        return current
    }
}
