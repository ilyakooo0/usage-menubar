import Foundation

/// JSON response from `GET https://hyper.charm.land/v1/credits`.
struct BalanceResponse: Decodable, Equatable {
    let balance: Int
}

/// Errors that can occur while fetching the balance.
enum CreditsError: LocalizedError, Equatable {
    case noAPIKey
    case invalidURL
    case requestFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key set. Enter your Hyper API key in settings."
        case .invalidURL:
            return "The server URL is invalid."
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .decodingFailed(let message):
            return "Failed to decode response: \(message)"
        }
    }
}

/// Client for the Hyper (Charm) credits API.
final class CreditsChecker {
    static let endpoint = URL(string: "https://hyper.charm.land/v1/credits")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches the current credit balance for the given API key.
    /// - Parameter apiKey: The Hyper API key (starts with `"sk-"`).
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
