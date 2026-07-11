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

    // MARK: - CreditsError cases

    func testInvalidAPIKeyErrorDescription() {
        XCTAssertEqual(
            CreditsError.invalidAPIKey.errorDescription,
            "Invalid API key. Check your key at hyper.charm.land"
        )
    }

    func testInvalidAPIKeyIsEquatable() {
        XCTAssertEqual(CreditsError.invalidAPIKey, .invalidAPIKey)
        XCTAssertNotEqual(CreditsError.invalidAPIKey, .noAPIKey)
    }

    // MARK: - CreditsChecking protocol

    func testCreditsCheckerConformsToProtocol() {
        let checker: CreditsChecking = CreditsChecker()
        // If this compiles, CreditsChecker conforms to CreditsChecking.
        XCTAssertNotNil(checker)
    }

    // MARK: - Mock CreditsChecker for ViewModel tests

    func testMockCreditsCheckerReturnsBalance() async throws {
        let mock = MockCreditsChecker(balanceToReturn: 42)
        let result = try await mock.fetchBalance(apiKey: "sk-test")
        XCTAssertEqual(result, 42)
    }

    func testMockCreditsCheckerThrowsError() async {
        let mock = MockCreditsChecker(errorToThrow: CreditsError.invalidAPIKey)
        do {
            _ = try await mock.fetchBalance(apiKey: "sk-test")
            XCTFail("Expected invalidAPIKey error")
        } catch CreditsError.invalidAPIKey {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Mock CreditsChecker

/// A mock `CreditsChecking` implementation for testing the ViewModel.
final class MockCreditsChecker: CreditsChecking {
    var balanceToReturn: Int?
    var errorToThrow: Error?

    init(balanceToReturn: Int? = nil, errorToThrow: Error? = nil) {
        self.balanceToReturn = balanceToReturn
        self.errorToThrow = errorToThrow
    }

    func fetchBalance(apiKey: String) async throws -> Int {
        if let errorToThrow {
            throw errorToThrow
        }
        return balanceToReturn ?? 0
    }
}
