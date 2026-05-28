import XCTest
@testable import NDIStream

final class QuicTLSTests: XCTestCase {
    func testGeneratedIdentityHasValidPin() throws {
        let tls = try XCTUnwrap(QuicTLS.loadOrCreate())
        XCTAssertEqual(tls.pinHex.count, 64, "SHA-256 hex is 64 chars")
        XCTAssertFalse(tls.pinSHA256.isEmpty)
    }
}
