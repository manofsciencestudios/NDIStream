import XCTest
@testable import NDIStream

final class NDITransportTests: XCTestCase {

    // MARK: VideoTransportKind

    func testVideoTransportKindHasWarpStreamCase() {
        XCTAssertEqual(VideoTransportKind.warpStream.rawValue, "warpStream")
        XCTAssertTrue(VideoTransportKind.allCases.contains(.warpStream))
    }

    // MARK: FoundSource

    func testFoundSourceCarriesRoomCode() {
        let s = FoundSource(name: "X", address: "1.2.3.4", transport: .warpStream,
                            port: 7000, pinSHA256: Data([1,2,3]), roomCode: "ABC123")
        XCTAssertEqual(s.roomCode, "ABC123")
    }

    func testFoundSourceRoomCodeDefaultsNil() {
        let s = FoundSource(name: "X", address: "1.2.3.4", transport: .ndi)
        XCTAssertNil(s.roomCode)
    }

    func testFoundSourceMappingTagsNDI() {
        let mapped = NDISourceFinder.mapForTesting(name: "CAM (Mac Camera)", address: "10.0.0.5")
        XCTAssertEqual(mapped, FoundSource(name: "CAM (Mac Camera)", address: "10.0.0.5", transport: .ndi))
    }

    // MARK: TransportStats

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

    // MARK: Factory routing

    func testFactoryReturnsNilForUnimplementedQuicLinkSender() {
        let sender = TransportFactory.makeSender(transport: .quicLink,
                                                 sourceName: "X", clockVideo: false)
        XCTAssertNil(sender, "QuicLink sender adapter not yet wired in NDIStream")
    }

    func testFactoryReturnsNilForQuicLinkReceiver() {
        let src = FoundSource(name: "X", address: "1.2.3.4", transport: .quicLink)
        XCTAssertNil(TransportFactory.makeReceiver(for: src),
                     "QuicLink receiver adapter not yet wired in NDIStream")
    }

    func testFactoryReturnsStubForWarpStreamSender() {
        let sender = TransportFactory.makeSender(transport: .warpStream,
                                                 sourceName: "X", clockVideo: false)
        // Stub returns a working no-op so the UI can be exercised end-to-end while
        // WarpStream's SDK is unfinished. Once the real adapter lands, this assertion
        // stays valid (a real sender is also non-nil).
        XCTAssertNotNil(sender, "WarpStream stub should produce a no-op sender for UI smoke testing")
        sender?.stop()
    }

    func testFactoryRoutesWarpStreamReceiverByPort() {
        let discovered = FoundSource(name: "X", address: "10.0.0.5", transport: .warpStream,
                                     port: 7000, pinSHA256: Data([1,2,3]), roomCode: "ABC123")
        let manual = FoundSource(name: "Code: ABC123", address: "", transport: .warpStream,
                                 port: nil, pinSHA256: nil, roomCode: "ABC123")
        // Stub returns a no-op receiver for both routing paths. We're pinning that the
        // factory routes both port-bearing and code-only FoundSources without crashing.
        XCTAssertNotNil(TransportFactory.makeReceiver(for: discovered))
        XCTAssertNotNil(TransportFactory.makeReceiver(for: manual))
    }

    func testMakeFindersIncludesNDIAndWarpStream() {
        let finders = TransportFactory.makeFinders()
        XCTAssertGreaterThanOrEqual(finders.count, 2,
                                    "makeFinders should return at least NDI and WarpStream finders")
    }

    func testWarpStreamFinderMappingSeam() {
        let fp = Data([0xab, 0xcd])
        let s = WarpStreamSourceFinder.mapForTesting(name: "Mike's Camera",
                                                     host: "10.0.0.7",
                                                     port: 7000,
                                                     pskFingerprint: fp,
                                                     roomCode: "ABC123")
        XCTAssertEqual(s.name, "Mike's Camera")
        XCTAssertEqual(s.address, "10.0.0.7")
        XCTAssertEqual(s.transport, .warpStream)
        XCTAssertEqual(s.port, 7000)
        XCTAssertEqual(s.pinSHA256, fp)
        XCTAssertEqual(s.roomCode, "ABC123")
    }
}
