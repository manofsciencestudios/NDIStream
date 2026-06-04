import XCTest
@testable import NDIStream

final class NDITransportTests: XCTestCase {
    func testFactoryReturnsNilForUnimplementedQuicLinkSender() {
        let sender = TransportFactory.makeSender(transport: .quicLink,
                                                 sourceName: "X", clockVideo: false)
        XCTAssertNil(sender, "QuicLink sender is not implemented until Plan 2c")
    }

    func testFactoryReturnsNilForQuicLinkReceiver() {
        let src = FoundSource(name: "X", address: "1.2.3.4", transport: .quicLink)
        XCTAssertNil(TransportFactory.makeReceiver(for: src),
                     "QuicLink receiver is not implemented until Plan 2c")
    }

    func testFoundSourceMappingTagsNDI() {
        let mapped = NDISourceFinder.mapForTesting(name: "CAM (Mac Camera)", address: "10.0.0.5")
        XCTAssertEqual(mapped, FoundSource(name: "CAM (Mac Camera)", address: "10.0.0.5", transport: .ndi))
    }

    func testVideoTransportKindHasWarpStreamCase() {
        XCTAssertEqual(VideoTransportKind.warpStream.rawValue, "warpStream")
        XCTAssertTrue(VideoTransportKind.allCases.contains(.warpStream))
    }

    func testFoundSourceCarriesRoomCode() {
        let s = FoundSource(name: "X", address: "1.2.3.4", transport: .warpStream,
                            port: 7000, pinSHA256: Data([1,2,3]), roomCode: "ABC123")
        XCTAssertEqual(s.roomCode, "ABC123")
    }

    func testFoundSourceRoomCodeDefaultsNil() {
        let s = FoundSource(name: "X", address: "1.2.3.4", transport: .ndi)
        XCTAssertNil(s.roomCode)
    }
}
