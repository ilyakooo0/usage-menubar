import XCTest
@testable import HyperCreditsMenubar

final class CreditsCheckerTests: XCTestCase {

    // MARK: - BalanceResponse Decoding

    func testDecodeValidBalance() throws {
        let json = #"{"balance": 42}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, 42)
    }

    func testDecodeZeroBalance() throws {
        let json = #"{"balance": 0}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, 0)
    }

    func testDecodeLargeBalance() throws {
        let json = #"{"balance": 999999}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, 999999)
    }

    func testDecodeMissingBalanceThrows() {
        let json = #"{"foo": "bar"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(BalanceResponse.self, from: json))
    }

    func testDecodeNegativeBalance() throws {
        // The API could theoretically return a negative balance
        let json = #"{"balance": -5}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(BalanceResponse.self, from: json)
        XCTAssertEqual(response.balance, -5)
    }

    // MARK: - CreditsChecker Errors

    func testEmptyAPIKeyThrowsNoAPIKey() async {
        let checker = CreditsChecker()
        do {
            _ = try await checker.fetchBalance(apiKey: "")
            XCTFail("Expected noAPIKey error")
        } catch CreditsError.noAPIKey {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
