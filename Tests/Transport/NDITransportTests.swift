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

    func testTransportStatsRoundtrip() {
        let s = TransportStats(bitrateKbps: 8400, sendLatencyMs: 12, wireLatencyMs: 18,
                               receiveLatencyMs: 32, endToEndLatencyMs: 62,
                               jitterBufferMs: 24, framesDropped: 3, cpuPercent: 14.5)
        XCTAssertEqual(s.bitrateKbps, 8400)
        XCTAssertEqual(s.sendLatencyMs, 12)
        XCTAssertEqual(s.wireLatencyMs, 18)
        XCTAssertEqual(s.receiveLatencyMs, 32)
        XCTAssertEqual(s.endToEndLatencyMs, 62)
        XCTAssertEqual(s.jitterBufferMs, 24)
        XCTAssertEqual(s.framesDropped, 3)
        XCTAssertEqual(s.cpuPercent, 14.5)
    }

    func testTransportStatsAllowsNilLatencies() {
        let s = TransportStats(bitrateKbps: 100, framesDropped: 0, cpuPercent: 5)
        XCTAssertNil(s.sendLatencyMs)
        XCTAssertNil(s.wireLatencyMs)
        XCTAssertNil(s.receiveLatencyMs)
        XCTAssertNil(s.endToEndLatencyMs)
        XCTAssertNil(s.jitterBufferMs)
    }

    func testNDIVideoSenderCurrentStatsReturnsNilForNow() {
        // The NDI SDK doesn't expose stats; the adapter returns nil until we have a meter.
        // This test pins behavior so we notice when we wire something in.
        let sender = NDIVideoSender(sourceName: "TestSrc", clockVideo: false)
        // Sender may be nil if NDI runtime isn't initialized in the test host; only check stats if alive.
        if let sender = sender {
            XCTAssertNil(sender.currentStats(),
                         "NDI adapter has no stats meter yet; expect nil until one is added")
            sender.stop()
        }
    }
}
