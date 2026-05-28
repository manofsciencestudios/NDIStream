import XCTest
@testable import NDIStream

final class QuicTLSTests: XCTestCase {
    func testIdentityIsIdempotentAndPinIsStable() throws {
        let a = try XCTUnwrap(QuicTLS.loadOrCreate())
        let b = try XCTUnwrap(QuicTLS.loadOrCreate())
        XCTAssertEqual(a.pinHex, b.pinHex, "persisted identity must yield a stable pin across loads")
        XCTAssertEqual(a.pinHex.count, 64, "SHA-256 hex is 64 chars")
    }
}
