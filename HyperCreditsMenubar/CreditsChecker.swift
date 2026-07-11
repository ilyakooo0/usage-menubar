import Foundation

/// JSON response from `GET https://hyper.charm.land/v1/credits`.
struct BalanceResponse: Decodable, Equatable {
    let balance: Int
}

/// Errors that can occur while fetching the balance.
enum CreditsError: LocalizedError, Equatable {
    case noAPIKey
    case invalidAPIKey
    case invalidURL
    case requestFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key set. Enter your Hyper API key in settings."
        case .invalidAPIKey:
            return "Invalid API key. Check your key at hyper.charm.land"
        case .invalidURL:
            return "The server URL is invalid."
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .decodingFailed(let message):
            return "Failed to decode response: \(message)"
        }
    }
}

/// Protocol abstraction for fetching credit balance, enabling test injection.
protocol CreditsChecking {
    func fetchBalance(apiKey: String) async throws -> Int
}

/// Client for the Hyper (Charm) credits API.
final class CreditsChecker: CreditsChecking {
    static let endpoint = URL(string: "https://hyper.charm.land/v1/credits")!

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetches the current credit balance for the given API key.
    /// - Parameter apiKey: A Hyper API key (starts with `"sk-"`).
    /// - Returns: The balance as an integer.
    /// - Throws: `CreditsError` on failure.
    func fetchBalance(apiKey: String) async throws -> Int {
        guard !apiKey.isEmpty else { throw CreditsError.noAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CreditsError.requestFailed("Invalid response type")
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 {
                    throw CreditsError.invalidAPIKey
                }
                throw CreditsError.requestFailed("HTTP \(httpResponse.statusCode)")
            }
            do {
                let decoded = try JSONDecoder().decode(BalanceResponse.self, from: data)
                return decoded.balance
            } catch {
                throw CreditsError.decodingFailed(error.localizedDescription)
            }
        } catch let error as CreditsError {
            throw error
        } catch {
            throw CreditsError.requestFailed(error.localizedDescription)
        }
    }
}
