import Foundation

// MARK: - Usage

/// Usage data from `GET https://api.anthropic.com/api/oauth/usage` — the endpoint
/// behind Claude Code's own `/usage` command.
///
/// Every field is optional. The payload varies by plan, and Anthropic adds and
/// removes windows without notice, so an unrecognized shape has to degrade to
/// "nothing to show" rather than fail the whole decode.
struct ClaudeUsage: Decodable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let limits: [Limit]?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case limits
    }

    /// The limit the server itself flags as currently binding — the one worth leading
    /// with. `nil` when it flags none, which is the normal state below the thresholds.
    var activeLimit: Limit? {
        limits?.first { $0.isActive }
    }

    /// Whether there is anything at all to render. The endpoint answers `{}` for an
    /// account that has never used the plan, and a section header over nothing reads
    /// as a bug.
    var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil && sevenDayOpus == nil && (limits?.isEmpty ?? true)
    }
}

/// One usage window, e.g. the rolling 5-hour or 7-day allowance.
struct UsageWindow: Decodable, Equatable, ResetCountdown {
    /// Percent of the window consumed, 0–100.
    let utilization: Double

    /// ISO 8601, or `nil` when nothing has been used and so nothing is counting down.
    let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(utilization: Double, resetsAt: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decodeIfPresent(Double.self, forKey: .utilization) ?? 0
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
    }
}

/// One entry in the `limits` array: the server's own classification of a limit,
/// including whether it is the one currently in effect.
struct Limit: Decodable, Equatable, ResetCountdown {
    let percent: Int
    let resetsAt: String?
    let isActive: Bool

    private enum CodingKeys: String, CodingKey {
        case percent
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    init(percent: Int, resetsAt: String? = nil, isActive: Bool = false) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.isActive = isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decoded as a Double and rounded: the field is documented as an integer, but
        // decoding it as one would throw on a fractional value and take the whole
        // payload down with it.
        let rawPercent = try container.decodeIfPresent(Double.self, forKey: .percent) ?? 0
        percent = Int(rawPercent.rounded())
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    }
}

// MARK: - Reset Countdown

/// Anything carrying an ISO 8601 reset timestamp, and so able to render a countdown.
protocol ResetCountdown {
    var resetsAt: String? { get }
}

extension ResetCountdown {
    /// `resetsAt` as a date, or `nil` when absent or unparseable.
    var resetsAtDate: Date? {
        guard let resetsAt else { return nil }
        return ISO8601.date(from: resetsAt)
    }

    /// How long until the window resets, e.g. `"3h 20m"`, `"1d 4h"` or `"12m"`.
    /// `nil` once the reset time has passed, or when there is no timestamp at all.
    ///
    /// - Parameter reference: The instant to count from. Injectable for tests.
    func resetsIn(from reference: Date = Date()) -> String? {
        guard let date = resetsAtDate else { return nil }

        let interval = date.timeIntervalSince(reference)
        guard interval > 0 else { return nil }

        // Rounded to the nearest second, so a window that is exactly "3h 20m" out
        // isn't reported a minute short because of the milliseconds spent getting here.
        let seconds = Int(interval.rounded())
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// The countdown as of now.
    var resetsInFormatted: String? {
        resetsIn()
    }
}

/// Claude timestamps carry fractional seconds, but not always — both spellings parse.
private enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string)
    }
}

// MARK: - Credentials

/// The subset of Claude Code's OAuth blob this app reads. The key names are Claude
/// Code's, not ours — and reading is *all* we do with them.
///
/// Deliberately models neither `refreshToken` nor `expiresAt`. Both existed only to
/// serve a token refresh, and refreshing is precisely what this app must never do: the
/// token endpoint rotates the refresh token, so an app refreshing behind the CLI's back
/// leaves the CLI holding a token the server has already retired — signing the user out
/// of their own terminal. Not modelling the fields is the cheapest way to keep it that
/// way. Every field Claude Code stores that isn't named here is simply ignored.
struct ClaudeOAuthCredentials: Decodable, Equatable {
    let claudeAiOauth: OAuthToken

    struct OAuthToken: Decodable, Equatable {
        let accessToken: String
        let scopes: [String]?
        /// `"pro"`, `"max"`, `"team"`, …
        let subscriptionType: String?
        let rateLimitTier: String?
    }
}

/// Reads the credentials Claude Code owns. Read-only by design — there is no `save`,
/// because the CLI is the only thing allowed to rotate these tokens.
/// Injectable so tests never go near the real Keychain or the real credentials file.
protocol ClaudeCredentialStoring {
    func load() -> ClaudeOAuthCredentials?
}

/// The real store: Claude Code's login-Keychain item, falling back to
/// `~/.claude/.credentials.json`.
///
/// The Keychain item belongs to Claude Code, so it is read through the `security`
/// CLI rather than `SecItemCopyMatching`: the item's ACL trusts `/usr/bin/security`,
/// and macOS asks the user once to allow it. Spawning a process and reading a file in
/// the user's home is also why this app cannot be sandboxed.
struct ClaudeCodeCredentialStore: ClaudeCredentialStoring {
    static let defaultKeychainService = "Claude Code-credentials"

    /// `NSHomeDirectory()` rather than `FileManager.homeDirectoryForCurrentUser`: the
    /// latter can resolve to a container path, while Claude Code always writes to the
    /// real home directory.
    static var defaultCredentialsFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
    }

    private let keychainService: String
    private let credentialsFile: URL

    init(
        keychainService: String = ClaudeCodeCredentialStore.defaultKeychainService,
        credentialsFile: URL = ClaudeCodeCredentialStore.defaultCredentialsFile
    ) {
        self.keychainService = keychainService
        self.credentialsFile = credentialsFile
    }

    func load() -> ClaudeOAuthCredentials? {
        if let json = Self.runSecurity(["find-generic-password", "-s", keychainService, "-w"]),
           let credentials = Self.decode(Data(json.utf8)) {
            return credentials
        }

        guard let data = try? Data(contentsOf: credentialsFile) else { return nil }
        return Self.decode(data)
    }

    private static func decode(_ data: Data) -> ClaudeOAuthCredentials? {
        try? JSONDecoder().decode(ClaudeOAuthCredentials.self, from: data)
    }

    /// Runs `/usr/bin/security`, returning its trimmed stdout, or `nil` when it fails
    /// or says nothing — which is the ordinary answer when Claude Code was never
    /// signed in on this machine.
    private static func runSecurity(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        // Discarded rather than piped: an undrained error pipe can fill and deadlock.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drained before waiting, for the same reason.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Errors

/// Errors that can occur while fetching Claude usage.
enum ClaudeUsageError: LocalizedError, Equatable {
    /// Claude Code has never signed in here. Not an error the user needs to see — the
    /// popover just leaves the section out.
    case noCredentials

    /// The token the CLI last stored has expired or been revoked. The app cannot fix
    /// this itself — only the CLI may mint a new one — so the message sends the user
    /// there.
    case invalidCredentials
    case requestFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No Claude Code credentials found. Run `claude` in a terminal to sign in."
        case .invalidCredentials:
            return "Claude sign-in expired. Run `claude` in a terminal to sign in again."
        case .requestFailed(let message):
            return "Claude request failed: \(message)"
        case .decodingFailed(let message):
            return "Failed to decode Claude usage: \(message)"
        }
    }
}

/// What a successful fetch yields: the usage itself, plus the plan it belongs to.
struct ClaudeUsageReport: Equatable {
    let usage: ClaudeUsage

    /// `"pro"`, `"max"`, … straight from the OAuth credentials; `nil` when absent.
    let subscriptionType: String?
}

/// Protocol abstraction for fetching Claude usage, enabling test injection.
protocol ClaudeUsageChecking {
    func fetchUsage() async throws -> ClaudeUsageReport
}

// MARK: - Client

/// Client for Claude Code's subscription usage API, authenticating with whatever OAuth
/// access token the CLI has most recently stored on this machine.
///
/// **A passenger, never a driver.** It reads the CLI's token and spends it as-is. It
/// never refreshes: the token endpoint *rotates* the refresh token, and the CLI refreshes
/// on its own schedule, so an app that also refreshed would race it — whichever of the two
/// went second would present a refresh token the server had already retired, and the user
/// would find themselves signed out of their own terminal. That bug is not worth a usage
/// readout. When the token is spent, we say so and point at `claude`.
///
/// Credentials are re-read on every fetch (the app polls every 1–5 minutes), so a token
/// the CLI refreshes is picked up on the next tick without the app lifting a finger.
///
/// Still an actor: it holds no mutable state now that the refresh is gone, but the
/// overlapping fetches (timer, manual click, wake) share one instance, and an actor keeps
/// that sharing trivially safe.
actor ClaudeUsageClient: ClaudeUsageChecking {
    static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Cloudflare fronts the API and answers 403 `browser_signature_banned` to anything
    /// without a browser User-Agent.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    /// Retries *after* the initial attempt, so at most 3 requests per call.
    static let maxRetries = 2

    /// URL error codes worth retrying: the request never reached a server that had an
    /// opinion about it, so the same request may well succeed a moment later.
    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .resourceUnavailable,
        .badServerResponse,
    ]

    /// Client-error status codes that are nonetheless worth retrying: both are the
    /// server telling us to come back later, not that the request itself is wrong.
    private static let retryableStatusCodes: Set<Int> = [
        408,  // Request Timeout
        429,  // Too Many Requests
    ]

    private let session: URLSession
    private let store: ClaudeCredentialStoring
    private let retryBaseDelay: Duration

    /// - Parameters:
    ///   - retryBaseDelay: Delay before the first retry; doubles on each subsequent
    ///     one (2s, then 4s). Injectable so tests need not wait in real time.
    init(
        session: URLSession? = nil,
        store: ClaudeCredentialStoring = ClaudeCodeCredentialStore(),
        retryBaseDelay: Duration = .seconds(2)
    ) {
        self.store = store
        self.retryBaseDelay = retryBaseDelay
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetches current usage with the CLI's current access token, exactly as stored.
    ///
    /// The token is not checked for expiry and not refreshed on rejection — see the type
    /// comment. A spent token surfaces as `.invalidCredentials`, which asks the user to
    /// run `claude`; doing so has the CLI mint a fresh token, which the next fetch picks
    /// up on its own.
    ///
    /// - Throws: `ClaudeUsageError`. `.noCredentials` means Claude Code was never
    ///   signed in here, which callers should treat as "nothing to show" rather than
    ///   as a failure.
    func fetchUsage() async throws -> ClaudeUsageReport {
        guard let credentials = store.load() else { throw ClaudeUsageError.noCredentials }

        let token = credentials.claudeAiOauth
        let usage = try await requestUsage(token: token.accessToken)
        return ClaudeUsageReport(usage: usage, subscriptionType: token.subscriptionType)
    }

    // MARK: - Usage Request

    private func requestUsage(token: String) async throws -> ClaudeUsage {
        var request = URLRequest(url: Self.usageEndpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data = try await send(request)

        do {
            return try JSONDecoder().decode(ClaudeUsage.self, from: data)
        } catch {
            throw ClaudeUsageError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Transport

    /// Sends a request, retrying transient failures with exponential backoff.
    private func send(_ request: URLRequest) async throws -> Data {
        var attempt = 0

        while true {
            do {
                return try await performAttempt(request)
            } catch let failure as AttemptFailure {
                guard failure.isRetryable, attempt < Self.maxRetries else {
                    throw failure.underlying
                }
                try await Task.sleep(for: retryBaseDelay * (1 << attempt))
                attempt += 1
            }
        }
    }

    /// Performs a single request, tagging the failure with whether a retry could
    /// plausibly help.
    private func performAttempt(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw AttemptFailure(
                underlying: .requestFailed(urlError.localizedDescription),
                isRetryable: Self.retryableURLErrorCodes.contains(urlError.code)
            )
        } catch {
            throw AttemptFailure(
                underlying: .requestFailed(error.localizedDescription),
                isRetryable: false
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttemptFailure(underlying: .requestFailed("Invalid response type"), isRetryable: false)
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw AttemptFailure(underlying: .invalidCredentials, isRetryable: false)
        case 500...599:
            throw AttemptFailure(
                underlying: .requestFailed("HTTP \(httpResponse.statusCode)"),
                isRetryable: true
            )
        default:
            throw AttemptFailure(
                underlying: .requestFailed("HTTP \(httpResponse.statusCode)"),
                isRetryable: Self.retryableStatusCodes.contains(httpResponse.statusCode)
            )
        }
    }

    /// A failed attempt, carrying the error to surface plus whether retrying is worthwhile.
    private struct AttemptFailure: Error {
        let underlying: ClaudeUsageError
        let isRetryable: Bool
    }
}
