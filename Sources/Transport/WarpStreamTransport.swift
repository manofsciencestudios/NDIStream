import CoreMedia
import CoreVideo
import Foundation

// MARK: - Stub adapter
//
// This file wires `.warpStream` into NDIStream's transport abstraction with stub
// implementations that return nil/no-op. The stubs compile and exercise the
// surrounding code paths (factory routing, ReceiverModel multi-finder, UI
// transport picker) without requiring WarpStream's SDK to ship.
//
// When WarpStream's public API lands (see
// docs/superpowers/specs/2026-06-04-warpstream-integration-design.md, §"WarpStream
// public API contract"), replace these stubs with:
//
//   - `import WarpStreamSender` / `import WarpStreamReceiver`
//   - real adapter wrappers translating the SDK's types to VideoSender /
//     VideoReceiver / SourceFinder
//   - real Bonjour TXT mapping for `WarpStreamDiscoveredSource -> FoundSource`
//
// The stubs intentionally fail-open (return nil, no-op) so the UI can render a
// "WarpStream not available yet" state cleanly.

/// Stub. Real impl wraps `WarpStream.WarpStreamSender`.
final class WarpStreamVideoSender: VideoSender {
    let roomCode: String

    init?(sourceName: String, clockVideo: Bool) {
        // Stub init succeeds but does nothing. Real impl forwards to WarpStreamSender(throws:).
        // Returning nil here would make the Sender window show an error; we let the stub
        // pretend to start so UI can be exercised end-to-end. Flip to `return nil` if you'd
        // rather block broadcast attempts until the SDK lands.
        self.roomCode = "WS-STUB"
        DebugLog.write("WarpStreamVideoSender STUB init sourceName=\(sourceName) clockVideo=\(clockVideo)")
    }

    func send(pixelBuffer: CVPixelBuffer, frameRateN: Int32, frameRateD: Int32) { /* stub no-op */ }
    func repeatLastFrame(frameRateN: Int32, frameRateD: Int32) { /* stub no-op */ }
    func sendAudio(_ sampleBuffer: CMSampleBuffer) { /* stub no-op */ }
    func stop() { DebugLog.write("WarpStreamVideoSender STUB stop") }
    func currentStats() -> TransportStats? { nil }
}

/// Stub. Real impl wraps `WarpStream.WarpStreamReceiver` and translates its
/// delegate callbacks to `VideoReceiverDelegate`.
final class WarpStreamVideoReceiver: NSObject, VideoReceiver {
    weak var delegate: VideoReceiverDelegate?

    init?(discovered: FoundSource) {
        super.init()
        DebugLog.write("WarpStreamVideoReceiver STUB init discovered name=\(discovered.name) port=\(discovered.port ?? 0) code=\(discovered.roomCode ?? "")")
    }

    init?(roomCode: String) {
        super.init()
        DebugLog.write("WarpStreamVideoReceiver STUB init roomCode=\(roomCode)")
    }

    func stop() { DebugLog.write("WarpStreamVideoReceiver STUB stop") }
    func currentStats() -> TransportStats? { nil }
}

/// Stub. Real impl wraps `WarpStream.WarpStreamFinder` and maps
/// `WarpStreamDiscoveredSource -> FoundSource(transport: .warpStream, ...)`.
final class WarpStreamSourceFinder: SourceFinder {
    var onSourcesChanged: (([FoundSource]) -> Void)?

    init() {
        DebugLog.write("WarpStreamSourceFinder STUB init")
    }

    func currentSources() -> [FoundSource] { [] }
    func stop() { DebugLog.write("WarpStreamSourceFinder STUB stop") }

    /// Pure mapping seam, mirrors `NDISourceFinder.mapForTesting`. Tested even
    /// though the live finder is a stub, so when the real impl lands the mapping
    /// is already pinned by tests.
    static func mapForTesting(name: String, host: String, port: UInt16,
                              pskFingerprint: Data, roomCode: String) -> FoundSource {
        FoundSource(name: name, address: host, transport: .warpStream,
                    port: port, pinSHA256: pskFingerprint, roomCode: roomCode)
    }
}
