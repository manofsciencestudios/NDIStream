# WarpStream Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `.warpStream` into NDIStream as a third concurrent transport alongside `.ndi` and `.quicLink`, so when WarpStream's public SDK lands NDIStream is ready to plug it in for a head-to-head shootout.

**Architecture:** Extend NDIStream's existing transport abstraction (`VideoTransportKind`, `FoundSource`, `VideoSender`, `VideoReceiver`, `SourceFinder`, `TransportFactory`) with a `.warpStream` case, a `roomCode: String?` field on `FoundSource`, a `TransportStats` type, and a stub WarpStream adapter file. ReceiverModel grows multi-finder + transport-filtering + connect-by-room-code. AppKit UI grows a transport picker on both Sender and Receiver windows, a room-code display on Sender, a room-code entry field on Receiver, and a polling stats overlay.

**Tech Stack:** Swift 5.9, AppKit (NSSegmentedControl, NSPanel, NSTextField), Network.framework (Bonjour via NWBrowser), VideoToolbox (existing recorder), XCTest, XcodeGen project generation, no SwiftUI.

**Spec:** `docs/superpowers/specs/2026-06-04-warpstream-integration-design.md`

**WarpStream code constraint:** Do not modify anything in `Low_Latency_UDPstreaming/Sources/`. The WarpStream stub adapter created in Phase 4 of this plan compiles against placeholder types defined inside NDIStream; it will be rewired once WarpStream's public SDK ships.

---

## File Structure

**New files (3):**

- `Sources/Transport/TransportStats.swift` — value type carrying bitrate, multi-component latency, jitter buffer depth, dropped frames, CPU%.
- `Sources/Transport/WarpStreamTransport.swift` — stub adapter classes (`WarpStreamVideoSender`, `WarpStreamVideoReceiver`, `WarpStreamSourceFinder`) that compile but return nil/empty until WarpStream's SDK ships.
- `Sources/UI/StatsOverlay.swift` — AppKit overlay panel polling `currentStats()` at 1 Hz on the active sender or receiver.

**Modified files (5):**

- `Sources/Transport/VideoTransport.swift` — `.warpStream` case in `VideoTransportKind`, `roomCode` on `FoundSource`, `currentStats() -> TransportStats?` protocol methods.
- `Sources/Transport/NDITransport.swift` — NDI adapter implements `currentStats()`; `TransportFactory` gains `.warpStream` branches; `makeFinder()` becomes `makeFinders()`.
- `Sources/Receive/ReceiverModel.swift` — `selectedTransport` with persistence, multi-finder source merging, transport filtering, `connectByRoomCode(_:)`.
- `Sources/App/NDIStreamApp.swift` — Sender + Receiver windows grow transport pickers; Sender grows room-code display; Receiver grows room-code entry; View menu grows "Show Stats" with ⌘I.
- `Sources/Model/BroadcastController.swift` — expose `currentRoomCode: String?` reader for the Sender UI room-code display.

**New tests (1 new file + 1 extended):**

- `Tests/Transport/WarpStreamTransportTests.swift` — stub adapter + factory routing for `.warpStream`.
- `Tests/Transport/NDITransportTests.swift` (extended) — tests for `roomCode` field, `TransportStats`, `makeFinders()`, `.warpStream` factory branches.

---

## Phase 1: Protocol additions

### Task 1: Add `.warpStream` case and `roomCode` field

**Files:**
- Modify: `Sources/Transport/VideoTransport.swift`
- Test: `Tests/Transport/NDITransportTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/Transport/NDITransportTests.swift` (append below the existing tests):

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Generate the Xcode project and run tests:

```bash
cd "/Users/Shendge/Desktop/Claude_Apps/NDI Stream/NDIStream"
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: compile errors — `.warpStream` doesn't exist, `roomCode` parameter unknown.

- [ ] **Step 3: Edit `Sources/Transport/VideoTransport.swift`**

Replace the file with:

```swift
import CoreMedia
import CoreVideo
import Foundation

/// Which transport carries video/audio. Persisted as a raw string in UserDefaults.
enum VideoTransportKind: String, CaseIterable {
    case ndi
    case quicLink
    case warpStream
}

/// A discovered source the receiver can connect to, tagged by transport.
struct FoundSource: Equatable {
    let name: String
    let address: String
    let transport: VideoTransportKind
    /// QuicLink + WarpStream (Bonjour path): the UDP port the sender advertises. nil for NDI and for room-code paths.
    var port: UInt16? = nil
    /// QuicLink: SHA-256 of the sender's leaf cert DER. WarpStream: PSK fingerprint. nil for NDI and for room-code paths.
    var pinSHA256: Data? = nil
    /// WarpStream only: the room code identifying the session. Surfaced from Bonjour TXT or entered manually by the operator.
    var roomCode: String? = nil
}

/// Sends camera frames + audio over some transport. Mirrors the NDISender surface.
protocol VideoSender: AnyObject {
    func send(pixelBuffer: CVPixelBuffer, frameRateN: Int32, frameRateD: Int32)
    func repeatLastFrame(frameRateN: Int32, frameRateD: Int32)
    func sendAudio(_ sampleBuffer: CMSampleBuffer)
    func stop()
    /// Optional shootout instrumentation. Default impl returns nil so existing
    /// transports compile without changes.
    func currentStats() -> TransportStats?
}

extension VideoSender {
    func currentStats() -> TransportStats? { nil }
}

/// Receives decoded frames + audio. Callbacks fire on a non-main (transport) thread;
/// the implementer is responsible for hopping to the main actor as needed.
protocol VideoReceiverDelegate: AnyObject {
    func videoReceiverDidReceive(sampleBuffer: CMSampleBuffer, width: Int32, height: Int32,
                                 frameRateN: Int32, frameRateD: Int32, fourCC: UInt32)
    func videoReceiverDidDisconnect()
    func videoReceiverDidStall(forSeconds seconds: Int)
    func videoReceiverDidResume()
    func videoReceiverDidReceiveAudio(samples: UnsafePointer<Float>, sampleRate: Int32,
                                      channels: Int32, samplesPerChannel: Int32,
                                      channelStrideBytes: Int32)
}

protocol VideoReceiver: AnyObject {
    var delegate: VideoReceiverDelegate? { get set }
    func stop()
    /// Optional shootout instrumentation. Default impl returns nil so existing
    /// transports compile without changes.
    func currentStats() -> TransportStats?
}

extension VideoReceiver {
    func currentStats() -> TransportStats? { nil }
}

/// Discovers sources on the network for one transport.
protocol SourceFinder: AnyObject {
    var onSourcesChanged: (([FoundSource]) -> Void)? { get set }
    func currentSources() -> [FoundSource]
    func stop()
}
```

- [ ] **Step 4: Run tests, verify they pass (or surface next failures)**

```bash
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: the three new tests pass. Other failures may surface for `TransportStats` (next task) — that's fine.

- [ ] **Step 5: Commit**

```bash
git add Sources/Transport/VideoTransport.swift Tests/Transport/NDITransportTests.swift
git commit -m "feat(transport): add .warpStream case, FoundSource.roomCode, currentStats hooks"
```

---

### Task 2: Add `TransportStats` value type

**Files:**
- Create: `Sources/Transport/TransportStats.swift`
- Test: `Tests/Transport/NDITransportTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/Transport/NDITransportTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: compile errors — `TransportStats` unknown.

- [ ] **Step 3: Create `Sources/Transport/TransportStats.swift`**

```swift
import Foundation

/// Multi-component transport statistics for the NDI/QuicLink/WarpStream shootout.
///
/// Latency fields are milliseconds. `nil` means the transport can't measure that
/// component (e.g., NDI exposes only `endToEndLatencyMs`). `jitterBufferMs` is the
/// current jitter-buffer depth — a setting, not a latency — included separately so
/// it isn't summed by mistake.
struct TransportStats: Equatable {
    let bitrateKbps: Double
    let sendLatencyMs: Double?
    let wireLatencyMs: Double?
    let receiveLatencyMs: Double?
    let endToEndLatencyMs: Double?
    let jitterBufferMs: Double?
    let framesDropped: UInt64
    let cpuPercent: Double

    init(bitrateKbps: Double,
         sendLatencyMs: Double? = nil,
         wireLatencyMs: Double? = nil,
         receiveLatencyMs: Double? = nil,
         endToEndLatencyMs: Double? = nil,
         jitterBufferMs: Double? = nil,
         framesDropped: UInt64,
         cpuPercent: Double) {
        self.bitrateKbps = bitrateKbps
        self.sendLatencyMs = sendLatencyMs
        self.wireLatencyMs = wireLatencyMs
        self.receiveLatencyMs = receiveLatencyMs
        self.endToEndLatencyMs = endToEndLatencyMs
        self.jitterBufferMs = jitterBufferMs
        self.framesDropped = framesDropped
        self.cpuPercent = cpuPercent
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: all NDITransportTests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Transport/TransportStats.swift Tests/Transport/NDITransportTests.swift project.yml
git commit -m "feat(transport): add TransportStats value type for shootout instrumentation"
```

---

## Phase 2: NDI adapter stats

### Task 3: Implement `currentStats()` on `NDIVideoSender` and `NDIVideoReceiver`

NDI's API doesn't expose its internals — the adapter populates what it can (we don't currently track bitrate inside the adapter, so most fields are nil). Honest minimal impl: return nil from the adapter for now, with a TODO comment. The stats overlay handles nil rendering. This task is therefore mostly an explicit no-op + comment, plus a test confirming nil.

**Files:**
- Modify: `Sources/Transport/NDITransport.swift`
- Test: `Tests/Transport/NDITransportTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/Transport/NDITransportTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests, verify they fail (or pass trivially)**

```bash
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: test passes trivially because the protocol's default `currentStats()` returns nil. That's fine — the test pins behavior, not implementation.

- [ ] **Step 3: Add an explicit override + TODO to NDIVideoSender and NDIVideoReceiver**

Edit `Sources/Transport/NDITransport.swift`, replacing the `NDIVideoSender` and `NDIVideoReceiver` classes (lines ~6–63):

```swift
/// Wraps the ObjC NDISender behind the VideoSender protocol.
final class NDIVideoSender: VideoSender {
    private let ndi: NDISender

    init?(sourceName: String, clockVideo: Bool) {
        guard let ndi = NDISender(sourceName: sourceName, clockVideo: clockVideo) else { return nil }
        self.ndi = ndi
    }

    func send(pixelBuffer: CVPixelBuffer, frameRateN: Int32, frameRateD: Int32) {
        ndi.send(pixelBuffer, frameRateN: frameRateN, frameRateD: frameRateD)
    }

    func repeatLastFrame(frameRateN: Int32, frameRateD: Int32) {
        ndi.repeatLastFrame(withFrameRateN: frameRateN, frameRateD: frameRateD)
    }

    func sendAudio(_ sampleBuffer: CMSampleBuffer) { ndi.sendAudio(sampleBuffer) }

    func stop() { ndi.stop() }

    // NDI SDK does not expose per-stream metrics; adapter has no meter yet.
    // Returning nil makes the stats overlay render "—" for the NDI baseline.
    func currentStats() -> TransportStats? { nil }
}

/// Wraps the ObjC NDIReceiver, translating its delegate callbacks to VideoReceiverDelegate.
final class NDIVideoReceiver: NSObject, VideoReceiver, NDIReceiverDelegate {
    weak var delegate: VideoReceiverDelegate?
    private let ndi: NDIReceiver

    init?(sourceName: String, sourceAddress: String) {
        guard let ndi = NDIReceiver(sourceName: sourceName, sourceAddress: sourceAddress) else { return nil }
        self.ndi = ndi
        super.init()
        ndi.delegate = self
    }

    func stop() {
        ndi.delegate = nil
        ndi.stop()
    }

    func currentStats() -> TransportStats? { nil }

    // MARK: NDIReceiverDelegate → VideoReceiverDelegate

    func receiverDidReceive(_ sampleBuffer: CMSampleBuffer, width: Int32, height: Int32,
                            frameRateN: Int32, frameRateD: Int32, fourCC: UInt32) {
        delegate?.videoReceiverDidReceive(sampleBuffer: sampleBuffer, width: width, height: height,
                                          frameRateN: frameRateN, frameRateD: frameRateD, fourCC: fourCC)
    }

    func receiverDidDisconnect() { delegate?.videoReceiverDidDisconnect() }

    func receiverDidStall(forSeconds seconds: Int) { delegate?.videoReceiverDidStall(forSeconds: seconds) }

    func receiverDidResume() { delegate?.videoReceiverDidResume() }

    func receiverDidReceiveAudio(_ samples: UnsafePointer<Float>, sampleRate: Int32, channels: Int32,
                                 samplesPerChannel: Int32, channelStrideBytes: Int32) {
        delegate?.videoReceiverDidReceiveAudio(samples: samples, sampleRate: sampleRate, channels: channels,
                                               samplesPerChannel: samplesPerChannel,
                                               channelStrideBytes: channelStrideBytes)
    }
}
```

- [ ] **Step 4: Run tests, verify pass**

```bash
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: NDIVideoSender test passes; existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Transport/NDITransport.swift Tests/Transport/NDITransportTests.swift
git commit -m "feat(transport): explicit nil currentStats on NDI adapter (placeholder)"
```

---

## Phase 3: TransportFactory updates

### Task 4: Convert `makeFinder()` to `makeFinders()`

**Files:**
- Modify: `Sources/Transport/NDITransport.swift`
- Modify: `Sources/Receive/ReceiverModel.swift`

- [ ] **Step 1: Edit `TransportFactory` in `Sources/Transport/NDITransport.swift`**

Replace the existing `TransportFactory` enum (last ~25 lines of the file) with:

```swift
/// Picks transport backends by kind. `.quicLink` and `.warpStream` are wired but
/// return nil from sender/receiver until their adapters land.
enum TransportFactory {
    static func makeSender(transport: VideoTransportKind, sourceName: String,
                           clockVideo: Bool) -> VideoSender? {
        switch transport {
        case .ndi: return NDIVideoSender(sourceName: sourceName, clockVideo: clockVideo)
        case .quicLink: return nil
        case .warpStream: return WarpStreamVideoSender(sourceName: sourceName, clockVideo: clockVideo)
        }
    }

    static func makeReceiver(for source: FoundSource) -> VideoReceiver? {
        switch source.transport {
        case .ndi:
            return NDIVideoReceiver(sourceName: source.name, sourceAddress: source.address)
        case .quicLink:
            return nil
        case .warpStream:
            // Routing rule: room-code path (no port) vs Bonjour-discovered path.
            // The stub adapter returns nil in both cases; real impl arrives with WarpStream SDK.
            if source.port == nil {
                return WarpStreamVideoReceiver(roomCode: source.roomCode ?? "")
            } else {
                return WarpStreamVideoReceiver(discovered: source)
            }
        }
    }

    /// The finders the receiver should run. Today: NDI live; QuicLink + WarpStream
    /// stubs return empty source lists.
    static func makeFinders() -> [SourceFinder] {
        [
            NDISourceFinder(),
            WarpStreamSourceFinder(),
        ]
    }
}
```

(Note: QuicLink's finder, when wired, joins this array. For now we leave it out — the QuicLink finder exists at `Sources/QuicLink/QuicLinkFinder.swift` but no adapter conforms it to `SourceFinder` in NDIStream yet.)

- [ ] **Step 2: Update the single existing caller in `ReceiverModel.swift`**

Find line 49 in `Sources/Receive/ReceiverModel.swift`:

```swift
        self.finder = TransportFactory.makeFinder()
```

This will be replaced in Phase 5 with multi-finder logic. For now (to keep this task surgical), replace with a transitional single-finder using just the NDI one to keep the existing tests green:

Actually — leave the file unchanged in this task. The single `makeFinder()` call breaking is intentional and gets fixed in Phase 5 (Task 7). After this step the build will fail in `ReceiverModel.swift`. That's expected; we're staging change across phases.

To make this task self-contained, we temporarily add a shim. Replace line 49 with:

```swift
        self.finder = TransportFactory.makeFinders().first
```

This keeps the build green while preserving today's single-finder receiver behavior; Phase 5 reworks it properly.

- [ ] **Step 3: Build to confirm it compiles**

```bash
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: build succeeds. (`WarpStreamVideoSender` etc. don't exist yet; we'll create stubs in Task 6. Build will fail on those — that's the next task's setup.)

If build fails on `WarpStreamVideoSender`/`WarpStreamVideoReceiver`/`WarpStreamSourceFinder` symbols, continue to Task 6 — that's the expected next step.

- [ ] **Step 4: Commit (with `WIP:` prefix since build is intentionally red on WarpStream symbols)**

```bash
git add Sources/Transport/NDITransport.swift Sources/Receive/ReceiverModel.swift
git commit -m "WIP: route .warpStream through factory (stub types arrive in next commit)"
```

---

### Task 5: Update existing factory tests

**Files:**
- Modify: `Tests/Transport/NDITransportTests.swift`

- [ ] **Step 1: Replace QuicLink-specific tests + add WarpStream factory tests**

Replace `Tests/Transport/NDITransportTests.swift` entirely:

```swift
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
}
```

(Tests will fail to compile until Task 6 lands the stub `WarpStreamVideoSender` / `WarpStreamVideoReceiver` / `WarpStreamSourceFinder` types. Don't run them yet; Task 6 will run them.)

- [ ] **Step 2: Stage but don't commit yet**

Don't commit — Task 6 ships the stubs that make these compile.

---

## Phase 4: WarpStream stub adapter

### Task 6: Create stub `WarpStreamTransport.swift`

The adapter compiles against placeholder types defined inside NDIStream (not WarpStream's package — WarpStream's SDK isn't ready). When WarpStream's public API ships, this file gets rewritten to import `WarpStreamSender` / `WarpStreamReceiver` instead.

**Files:**
- Create: `Sources/Transport/WarpStreamTransport.swift`

- [ ] **Step 1: Create the stub file**

Create `Sources/Transport/WarpStreamTransport.swift`:

```swift
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
```

- [ ] **Step 2: Regenerate Xcode project + run tests**

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: build succeeds, all NDITransportTests pass including the new WarpStream factory tests from Task 5.

- [ ] **Step 3: Add mapping seam test**

Append to `Tests/Transport/NDITransportTests.swift`:

```swift
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
```

- [ ] **Step 4: Run tests, verify pass**

```bash
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -10
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Transport/WarpStreamTransport.swift Tests/Transport/NDITransportTests.swift
git commit -m "feat(transport): stub WarpStream adapter — compiles, returns nil/no-op until SDK ships"
```

---

## Phase 5: ReceiverModel multi-finder + room-code path

### Task 7: Add `selectedTransport` + multi-finder source merging to ReceiverModel

**Files:**
- Modify: `Sources/Receive/ReceiverModel.swift`

- [ ] **Step 1: Replace `ReceiverModel` published state and init**

Edit `Sources/Receive/ReceiverModel.swift`. Replace lines 11–83 (the property declarations and init through the auto-select wiring) with:

```swift
    @Published var availableSources: [FoundSource] = []
    @Published var selectedSourceName: String = ""
    @Published var selectedTransport: VideoTransportKind {
        didSet {
            UserDefaults.standard.set(selectedTransport.rawValue, forKey: "receiverTransport")
            // When transport changes, re-filter the visible source list and clear stale selection.
            refilterAndPublish()
            if !availableSources.contains(where: { $0.name == selectedSourceName }) {
                selectedSourceName = availableSources.first?.name ?? ""
            }
        }
    }
    @Published var roomCodeEntry: String = ""
    @Published var isConnected: Bool = false
    @Published var statusLine: String = "No source selected"
    @Published var lastFormat: FrameFormat? = nil
    @Published var tally: Tally = .idle
    @Published var slate: String = "" {
        didSet { UserDefaults.standard.set(slate, forKey: "receiverSlate") }
    }
    @Published var autoRecord: Bool = false {
        didSet { UserDefaults.standard.set(autoRecord, forKey: "receiverAutoRecord") }
    }
    @Published var audioEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "receiverAudioEnabled")
            audioPlayer.setMuted(!audioEnabled)
        }
    }
    @Published var isLocked: Bool = false

    struct FrameFormat: Equatable {
        let width: Int
        let height: Int
        let fps: Int
        let fourCC: String
    }

    let displayLayer = AVSampleBufferDisplayLayer()
    nonisolated let recorder = Recorder(filenamePrefix: "Receiver")
    nonisolated let audioPlayer = AudioPlayer()

    /// All finders running concurrently, one per transport. Their callbacks
    /// merge into `allSources`; `availableSources` is the filtered view.
    private let finders: [SourceFinder]
    /// Merged sources from all finders, keyed by `"<transport>::<name>"`.
    private var allSources: [String: FoundSource] = [:]
    private var receiver: VideoReceiver?
    private var receivedFrameCount = 0
    private var hasPerformedInitialAutoselect = false

    override init() {
        DebugLog.write("ReceiverModel.init")
        self.finders = TransportFactory.makeFinders()
        // Default to .ndi on first launch, restore last-used otherwise (per spec §"UI changes").
        let savedTransport = UserDefaults.standard.string(forKey: "receiverTransport")
            .flatMap(VideoTransportKind.init(rawValue:)) ?? .ndi
        self.selectedTransport = savedTransport
        super.init()

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor

        if let saved = UserDefaults.standard.string(forKey: "lastReceiverSource") {
            selectedSourceName = saved
        }
        self.slate = UserDefaults.standard.string(forKey: "receiverSlate") ?? ""
        self.autoRecord = UserDefaults.standard.bool(forKey: "receiverAutoRecord")
        self.audioEnabled = UserDefaults.standard.bool(forKey: "receiverAudioEnabled")
        audioPlayer.setMuted(!audioEnabled)

        // Wire every finder's callback to merge into allSources.
        for finder in finders {
            finder.onSourcesChanged = { [weak self] sources in
                guard let self else { return }
                Task { @MainActor in
                    self.ingest(sources: sources)
                }
            }
            for src in finder.currentSources() {
                let key = "\(src.transport.rawValue)::\(src.name)"
                allSources[key] = src
            }
        }
        refilterAndPublish()
    }

    /// Merge a finder's current sources into the global map. Sources from other
    /// transports are untouched. Triggers a refilter + autoselect pass.
    private func ingest(sources: [FoundSource]) {
        // Remove stale entries for the transports represented in this callback,
        // then re-insert.
        let touchedTransports = Set(sources.map(\.transport))
        for key in allSources.keys where touchedTransports.contains(allSources[key]!.transport) {
            allSources.removeValue(forKey: key)
        }
        for src in sources {
            allSources["\(src.transport.rawValue)::\(src.name)"] = src
        }
        refilterAndPublish()

        if !hasPerformedInitialAutoselect, !availableSources.isEmpty, !isConnected {
            hasPerformedInitialAutoselect = true
            let savedMatches = availableSources.contains(where: { $0.name == selectedSourceName })
            if !savedMatches, let first = availableSources.first {
                let was = selectedSourceName
                selectedSourceName = first.name
                DebugLog.write("receiver auto-selected source=\(first.name) (saved='\(was)') transport=\(selectedTransport.rawValue)")
            }
        }
    }

    /// Publish the subset of `allSources` matching `selectedTransport`, sorted.
    private func refilterAndPublish() {
        let filtered = allSources.values
            .filter { $0.transport == selectedTransport }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        availableSources = filtered
        DebugLog.write("receiver sources refilter transport=\(selectedTransport.rawValue) count=\(filtered.count) names=\(filtered.map { $0.name })")
    }
```

- [ ] **Step 2: Remove the old single-finder wiring**

The old `finder?.onSourcesChanged` block (now gone) is replaced by the per-finder loop above. The `finder` private property (was line 42) is now `finders` (plural). Search the rest of the file for any other references to `self.finder` or `finder?` — if any remain (e.g., in `disconnect()`), they should be removed or updated.

Run a grep:

```bash
grep -n "self\.finder\|private let finder\|finder?" "Sources/Receive/ReceiverModel.swift"
```

Expected: only the new `finders` references should remain. Old references should be gone.

- [ ] **Step 3: Build**

```bash
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: build succeeds.

- [ ] **Step 4: Write tests for transport filtering**

Create `Tests/Transport/ReceiverModelTransportFilterTests.swift`:

```swift
import XCTest
@testable import NDIStream

@MainActor
final class ReceiverModelTransportFilterTests: XCTestCase {

    func testSelectedTransportPersistsToUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "receiverTransport")
        let model = ReceiverModel()
        XCTAssertEqual(model.selectedTransport, .ndi, "Default to .ndi on first launch")
        model.selectedTransport = .warpStream
        let stored = UserDefaults.standard.string(forKey: "receiverTransport")
        XCTAssertEqual(stored, "warpStream")
    }

    func testSelectedTransportRestoresFromUserDefaults() {
        UserDefaults.standard.set("warpStream", forKey: "receiverTransport")
        let model = ReceiverModel()
        XCTAssertEqual(model.selectedTransport, .warpStream)
        UserDefaults.standard.removeObject(forKey: "receiverTransport")
    }
}
```

- [ ] **Step 5: Run tests, verify pass**

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: new tests pass; existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Receive/ReceiverModel.swift Tests/Transport/ReceiverModelTransportFilterTests.swift
git commit -m "feat(receiver): multi-finder source merging + selectedTransport persistence"
```

---

### Task 8: Add `connectByRoomCode(_:)` to ReceiverModel

**Files:**
- Modify: `Sources/Receive/ReceiverModel.swift`

- [ ] **Step 1: Add the method**

Add this method to `ReceiverModel` (place it just after the existing `connect()` method around line 119):

```swift
    /// Manual room-code path. Synthesizes a `FoundSource` with `port == nil` so
    /// `TransportFactory.makeReceiver` routes through `WarpStreamVideoReceiver(roomCode:)`.
    /// Only meaningful when `selectedTransport == .warpStream` (or another transport
    /// that supports room codes); other transports will get nil from the factory.
    func connectByRoomCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces).uppercased()
        DebugLog.write("receiver connectByRoomCode requested code=\(trimmed) transport=\(selectedTransport.rawValue)")
        guard !trimmed.isEmpty else {
            statusLine = "Enter a room code"
            return
        }
        guard !isConnected else { return }

        let synthetic = FoundSource(name: "Code: \(trimmed)",
                                    address: "",
                                    transport: selectedTransport,
                                    port: nil,
                                    pinSHA256: nil,
                                    roomCode: trimmed)
        guard let r = TransportFactory.makeReceiver(for: synthetic) else {
            DebugLog.write("ERROR connectByRoomCode receiver create failed transport=\(selectedTransport.rawValue) code=\(trimmed)")
            statusLine = "Failed to connect with code \(trimmed)"
            return
        }
        r.delegate = self
        receiver = r
        selectedSourceName = synthetic.name
        isConnected = true
        tally = .waiting
        ActivityKeeper.begin("receiver")
        statusLine = "Joining \(trimmed)…"
        lastFormat = nil
        receivedFrameCount = 0
        DebugLog.write("receiver created via code transport=\(selectedTransport.rawValue) code=\(trimmed)")
        if autoRecord, !recorder.isRecording {
            DebugLog.write("auto-record start (receiver, code path)")
            recorder.start(slate: slate, includeAudio: true)
        }
    }
```

- [ ] **Step 2: Write a test**

Append to `Tests/Transport/ReceiverModelTransportFilterTests.swift`:

```swift
    func testConnectByRoomCodeWithEmptyCodeReportsStatus() {
        let model = ReceiverModel()
        model.connectByRoomCode("")
        XCTAssertEqual(model.statusLine, "Enter a room code")
        XCTAssertFalse(model.isConnected)
    }

    func testConnectByRoomCodeUppercasesAndTrims() {
        let model = ReceiverModel()
        model.selectedTransport = .warpStream
        // Stub adapter accepts and returns a no-op receiver; connection state should flip.
        model.connectByRoomCode(" abc123 ")
        // The stub WarpStreamVideoReceiver init returns a real instance, so:
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.selectedSourceName, "Code: ABC123")
        model.disconnect()
    }
```

- [ ] **Step 3: Run tests**

```bash
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Receive/ReceiverModel.swift Tests/Transport/ReceiverModelTransportFilterTests.swift
git commit -m "feat(receiver): add connectByRoomCode for manual WarpStream code entry"
```

---

## Phase 6: BroadcastController room code exposure

### Task 9: Add `currentRoomCode` reader to BroadcastController

**Files:**
- Modify: `Sources/Model/BroadcastController.swift`

The Sender UI needs to read the active WarpStream sender's room code to display it to the operator. The room code is on the stub `WarpStreamVideoSender` as `roomCode: String`. We add a non-published computed reader to `BroadcastController`.

- [ ] **Step 1: Add the computed property**

Find `BroadcastController`'s private `sender: VideoSender?` (around line 225 in BroadcastController.swift). Add the following just below it, alongside `currentSender()`:

```swift
    /// The active WarpStream sender's room code, if any. nil for other transports
    /// or when not broadcasting. Reads from the underlying sender, not state.
    var currentRoomCode: String? {
        guard transport == .warpStream, let ws = currentSender() as? WarpStreamVideoSender else {
            return nil
        }
        return ws.roomCode
    }
```

- [ ] **Step 2: Build to confirm compiles**

```bash
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Model/BroadcastController.swift
git commit -m "feat(sender): expose currentRoomCode reader for WarpStream broadcasts"
```

---

## Phase 7: Sender window UI — transport picker + room code display

### Task 10: Add transport picker to Sender window

**Files:**
- Modify: `Sources/App/NDIStreamApp.swift`

`buildSenderWindow()` lives at `Sources/App/NDIStreamApp.swift:274`. The existing pattern uses `NSSegmentedControl` with `trackingMode: .selectOne, target: self, action: #selector(...)` — see `qualityControl` at line 332.

- [ ] **Step 1: Declare the segmented control**

Find the section of `AppDelegate`'s private properties near line 143 where `qualityControl`, `fpsControl`, `pixelFormatControl` are declared. Add:

```swift
    private var senderTransportControl = NSSegmentedControl()
    private var senderRoomCodeLabel = NSTextField(labelWithString: "")
    private var senderRoomCodeCopyButton = NSButton()
    private var senderRoomCodeContainer = NSStackView()
```

- [ ] **Step 2: Add to `buildSenderWindow()`**

Find `buildSenderWindow()` around line 274. The existing layout uses an `NSStackView` adding rows. After the `qualityControl` is created (around line 332), insert this analogous picker creation:

```swift
        senderTransportControl = NSSegmentedControl(labels: ["NDI", "QuicLink", "WarpStream"],
                                                    trackingMode: .selectOne,
                                                    target: self,
                                                    action: #selector(senderTransportChanged))
        senderTransportControl.selectedSegment = AppDelegate.transportIndex(senderController.transport)
```

Add this helper at the bottom of `AppDelegate` (before the closing brace of the class):

```swift
    private static func transportIndex(_ t: VideoTransportKind) -> Int {
        switch t {
        case .ndi: return 0
        case .quicLink: return 1
        case .warpStream: return 2
        }
    }

    private static func transportFromIndex(_ i: Int) -> VideoTransportKind {
        switch i {
        case 1: return .quicLink
        case 2: return .warpStream
        default: return .ndi
        }
    }

    @objc private func senderTransportChanged() {
        let new = AppDelegate.transportFromIndex(senderTransportControl.selectedSegment)
        DebugLog.write("UI senderTransportChanged -> \(new.rawValue)")
        senderController.transport = new
        updateSenderUI()
    }

    @objc private func receiverTransportChanged() {
        let new = AppDelegate.transportFromIndex(receiverTransportControl.selectedSegment)
        DebugLog.write("UI receiverTransportChanged -> \(new.rawValue)")
        receiverModel.selectedTransport = new
        updateReceiverUI()
    }
```

- [ ] **Step 3: Insert the picker into the sender layout**

Find where `qualityControl` is added to the sender window's stack view. Right above it (so transport is the first/top control), add:

```swift
        let transportRow = NSStackView(views: [
            NSTextField(labelWithString: "Transport:"),
            senderTransportControl
        ])
        transportRow.spacing = 8
        // Add transportRow to wherever the sender window's vertical stack is built.
        // Reference the existing surrounding code; insert as the first row of the form.
```

Note: the exact insertion line depends on the existing layout code in `buildSenderWindow()`. Find the line where `qualityControl` is added to a stack view, and add `transportRow` immediately above with the same pattern.

- [ ] **Step 4: Build and run**

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -10
open ./build/Debug/NDIStream.app  # or use Xcode to run
```

Expected: app launches. Sender window shows the transport picker at the top with three segments. Clicking each updates `senderController.transport` (verify via DebugLog).

- [ ] **Step 5: Commit**

```bash
git add Sources/App/NDIStreamApp.swift
git commit -m "feat(sender ui): add transport picker (NDI / QuicLink / WarpStream)"
```

---

### Task 11: Add room-code display panel to Sender window

**Files:**
- Modify: `Sources/App/NDIStreamApp.swift`

- [ ] **Step 1: Build the room-code container**

In `buildSenderWindow()`, after the transport picker row, add:

```swift
        senderRoomCodeLabel.font = NSFont.monospacedSystemFont(ofSize: 24, weight: .semibold)
        senderRoomCodeLabel.stringValue = "—"
        senderRoomCodeLabel.isSelectable = true
        senderRoomCodeCopyButton.title = "Copy"
        senderRoomCodeCopyButton.bezelStyle = .rounded
        senderRoomCodeCopyButton.target = self
        senderRoomCodeCopyButton.action = #selector(copySenderRoomCode)

        senderRoomCodeContainer = NSStackView(views: [
            NSTextField(labelWithString: "Room Code:"),
            senderRoomCodeLabel,
            senderRoomCodeCopyButton
        ])
        senderRoomCodeContainer.spacing = 8
        senderRoomCodeContainer.isHidden = true  // shown only for WarpStream + broadcasting
        // Insert senderRoomCodeContainer below the transport row in the sender window's stack.
```

- [ ] **Step 2: Add the copy action**

In `AppDelegate`, add:

```swift
    @objc private func copySenderRoomCode() {
        let code = senderRoomCodeLabel.stringValue
        guard code != "—" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        DebugLog.write("UI copied sender room code=\(code)")
    }
```

- [ ] **Step 3: Update `updateSenderUI()` to manage visibility + content**

Find `updateSenderUI()` in `AppDelegate`. Add at the end of that function:

```swift
        let showRoomCode = (senderController.transport == .warpStream && senderController.isBroadcasting)
        senderRoomCodeContainer.isHidden = !showRoomCode
        if showRoomCode {
            senderRoomCodeLabel.stringValue = senderController.currentRoomCode ?? "—"
        } else {
            senderRoomCodeLabel.stringValue = "—"
        }
```

- [ ] **Step 4: Build and run**

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -10
```

Open the app, switch transport to WarpStream, start broadcasting. Room code panel should appear with `WS-STUB` (the stub adapter's hardcoded code). Click Copy, paste somewhere — it should paste `WS-STUB`.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/NDIStreamApp.swift
git commit -m "feat(sender ui): show WarpStream room code with Copy button when broadcasting"
```

---

## Phase 8: Receiver window UI — transport picker + code entry

### Task 12: Add transport picker to Receiver window

**Files:**
- Modify: `Sources/App/NDIStreamApp.swift`

- [ ] **Step 1: Declare the segmented control + code field**

In `AppDelegate`'s private properties (where `receiverSourceLabel` is around line 170), add:

```swift
    private var receiverTransportControl = NSSegmentedControl()
    private var receiverRoomCodeField = NSTextField(string: "")
    private var receiverJoinByCodeButton = NSButton()
    private var receiverRoomCodeContainer = NSStackView()
```

- [ ] **Step 2: Construct in `buildReceiverWindow()`**

At line 401, `buildReceiverWindow()` is defined. Inside it, after the existing source picker setup, add (analogous to the sender picker work in Task 10):

```swift
        receiverTransportControl = NSSegmentedControl(labels: ["NDI", "QuicLink", "WarpStream"],
                                                       trackingMode: .selectOne,
                                                       target: self,
                                                       action: #selector(receiverTransportChanged))
        receiverTransportControl.selectedSegment = AppDelegate.transportIndex(receiverModel.selectedTransport)

        let receiverTransportRow = NSStackView(views: [
            NSTextField(labelWithString: "Transport:"),
            receiverTransportControl
        ])
        receiverTransportRow.spacing = 8
        // Insert receiverTransportRow as the first row of the receiver window's vertical stack.
```

- [ ] **Step 3: Build and run**

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -10
```

Open the app. Receiver window should now show transport picker at top with three segments. Changing it should update `receiverModel.selectedTransport` (DebugLog confirms). The source dropdown should filter (the WarpStream stub returns no sources, so picking WarpStream shows an empty dropdown — expected).

- [ ] **Step 4: Commit**

```bash
git add Sources/App/NDIStreamApp.swift
git commit -m "feat(receiver ui): add transport picker (NDI / QuicLink / WarpStream)"
```

---

### Task 13: Add room-code entry field + Connect button to Receiver

**Files:**
- Modify: `Sources/App/NDIStreamApp.swift`

- [ ] **Step 1: Build the room-code entry row**

In `buildReceiverWindow()`, after the transport row, add:

```swift
        receiverRoomCodeField.placeholderString = "ABC123"
        receiverRoomCodeField.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        receiverRoomCodeField.delegate = self  // see Step 2

        receiverJoinByCodeButton.title = "Join"
        receiverJoinByCodeButton.bezelStyle = .rounded
        receiverJoinByCodeButton.target = self
        receiverJoinByCodeButton.action = #selector(joinByRoomCode)

        receiverRoomCodeContainer = NSStackView(views: [
            NSTextField(labelWithString: "Or join by code:"),
            receiverRoomCodeField,
            receiverJoinByCodeButton
        ])
        receiverRoomCodeContainer.spacing = 8
        receiverRoomCodeContainer.isHidden = true  // shown only for .warpStream or .quicLink
        // Insert receiverRoomCodeContainer below the receiver source dropdown row.
```

- [ ] **Step 2: Add the action and visibility update**

In `AppDelegate`, add:

```swift
    @objc private func joinByRoomCode() {
        let code = receiverRoomCodeField.stringValue
        receiverModel.connectByRoomCode(code)
        updateReceiverUI()
    }
```

If `AppDelegate` doesn't already conform to `NSTextFieldDelegate`, conform it and add `controlTextDidEndEditing` for Enter key. Otherwise, this is a button-only flow.

Update `updateReceiverUI()` to manage visibility. Find that method and add at the end:

```swift
        let codeFieldVisible = (receiverModel.selectedTransport == .warpStream
                                || receiverModel.selectedTransport == .quicLink)
        receiverRoomCodeContainer.isHidden = !codeFieldVisible
```

- [ ] **Step 3: Build and run**

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -10
```

Open the app. Select WarpStream transport in Receiver. The "Or join by code:" row should appear. Type `abc123`, click Join. Status line should read `Joining ABC123…`, DebugLog shows the stub receiver init.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/NDIStreamApp.swift
git commit -m "feat(receiver ui): add room-code entry for WarpStream / QuicLink manual join"
```

---

## Phase 9: Stats overlay

The overlay polls `currentStats()` on the active sender (in `BroadcastController`) and receiver (in `ReceiverModel`) at 1 Hz. Renders bitrate, four latency components, jitter buffer, dropped, CPU%. AppKit `NSPanel` floating above its parent window.

### Task 14: Create `StatsOverlay` AppKit panel

**Files:**
- Create: `Sources/UI/StatsOverlay.swift`

- [ ] **Step 1: Create the overlay class**

Create `Sources/UI/StatsOverlay.swift`:

```swift
import AppKit
import Foundation

/// A floating panel overlay that displays multi-component transport stats at 1 Hz.
/// One instance per window (Sender or Receiver). The overlay reads stats via the
/// provided closure each tick, rendering "—" for any nil component.
@MainActor
final class StatsOverlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private weak var parentWindow: NSWindow?
    private let title: String
    private let provider: () -> (transport: VideoTransportKind, stats: TransportStats?)

    init(title: String,
         parent: NSWindow,
         provider: @escaping () -> (transport: VideoTransportKind, stats: TransportStats?)) {
        self.title = title
        self.parentWindow = parent
        self.provider = provider

        let frame = NSRect(x: 0, y: 0, width: 240, height: 180)
        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBordered = false
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 0
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: frame)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        panel.contentView = container
    }

    func show() {
        guard let parent = parentWindow else { return }
        repositionPanel(in: parent)
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        parentWindow?.removeChildWindow(panel)
    }

    var isVisible: Bool { panel.isVisible }

    private func repositionPanel(in parent: NSWindow) {
        let parentFrame = parent.frame
        let margin: CGFloat = 12
        let x = parentFrame.maxX - panel.frame.width - margin
        let y = parentFrame.maxY - panel.frame.height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func tick() {
        if let parent = parentWindow {
            repositionPanel(in: parent)
        }
        let (transport, statsOpt) = provider()
        var lines: [String] = []
        lines.append(pad("Window:", title))
        lines.append(pad("Transport:", transport.rawValue))
        guard let s = statsOpt else {
            lines.append("(no stats)")
            label.stringValue = lines.joined(separator: "\n")
            return
        }
        lines.append(pad("Bitrate:", String(format: "%.1f Mbps", s.bitrateKbps / 1000.0)))
        lines.append("")
        lines.append("Latency")
        lines.append(pad("  Send:", fmt(s.sendLatencyMs)))
        lines.append(pad("  Wire:", fmt(s.wireLatencyMs)))
        lines.append(pad("  Receive:", fmt(s.receiveLatencyMs)))
        lines.append(pad("  ────────", ""))
        lines.append(pad("  End-to-end:", fmt(s.endToEndLatencyMs)))
        if s.jitterBufferMs != nil {
            lines.append(pad("  Jitter buf:", fmt(s.jitterBufferMs)))
        }
        lines.append("")
        lines.append(pad("Dropped:", "\(s.framesDropped)"))
        lines.append(pad("CPU:", String(format: "%.0f%%", s.cpuPercent)))
        label.stringValue = lines.joined(separator: "\n")
    }

    private func pad(_ key: String, _ value: String) -> String {
        let keyWidth = 14
        let padding = max(0, keyWidth - key.count)
        return key + String(repeating: " ", count: padding) + value
    }

    private func fmt(_ ms: Double?) -> String {
        guard let ms = ms else { return "—" }
        return String(format: "%.0f ms", ms)
    }
}
```

- [ ] **Step 2: Build (no runtime test yet)**

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/StatsOverlay.swift
git commit -m "feat(ui): StatsOverlay AppKit panel rendering multi-component transport stats"
```

---

### Task 15: Wire stats overlay into both windows + View menu toggle

**Files:**
- Modify: `Sources/App/NDIStreamApp.swift`

- [ ] **Step 1: Add overlay properties**

In `AppDelegate`'s private properties, add:

```swift
    private var senderStatsOverlay: StatsOverlay?
    private var receiverStatsOverlay: StatsOverlay?
    private var senderStatsMenuItem: NSMenuItem!
    private var receiverStatsMenuItem: NSMenuItem!
```

- [ ] **Step 2: Add View menu items**

Find `installMenu()` around line 209. Add a View menu with stat-toggle items. If a View menu already exists, append the items there; otherwise add a new menu after the existing ones. Pattern:

```swift
        let viewMenu = NSMenu(title: "View")
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)  // mainMenu is the NSApp.mainMenu reference used in installMenu

        senderStatsMenuItem = NSMenuItem(title: "Show Sender Stats",
                                          action: #selector(toggleSenderStats),
                                          keyEquivalent: "i")
        senderStatsMenuItem.keyEquivalentModifierMask = [.command]
        senderStatsMenuItem.target = self
        viewMenu.addItem(senderStatsMenuItem)

        receiverStatsMenuItem = NSMenuItem(title: "Show Receiver Stats",
                                            action: #selector(toggleReceiverStats),
                                            keyEquivalent: "I")
        receiverStatsMenuItem.keyEquivalentModifierMask = [.command, .shift]
        receiverStatsMenuItem.target = self
        viewMenu.addItem(receiverStatsMenuItem)
```

(⌘I toggles Sender stats; ⇧⌘I toggles Receiver stats. The spec calls for ⌘I as the shortcut for stats; with two windows we need two shortcuts, so Sender gets the bare ⌘I.)

- [ ] **Step 3: Implement the toggles**

In `AppDelegate`, add:

```swift
    @objc private func toggleSenderStats() {
        if let overlay = senderStatsOverlay, overlay.isVisible {
            overlay.hide()
            senderStatsMenuItem.title = "Show Sender Stats"
            return
        }
        let overlay = senderStatsOverlay ?? StatsOverlay(
            title: "Sender",
            parent: senderWindow,
            provider: { [weak self] in
                guard let self = self else {
                    return (.ndi, nil)
                }
                return (self.senderController.transport,
                        self.senderController.activeSender?.currentStats())
            }
        )
        senderStatsOverlay = overlay
        overlay.show()
        senderStatsMenuItem.title = "Hide Sender Stats"
    }

    @objc private func toggleReceiverStats() {
        if let overlay = receiverStatsOverlay, overlay.isVisible {
            overlay.hide()
            receiverStatsMenuItem.title = "Show Receiver Stats"
            return
        }
        let overlay = receiverStatsOverlay ?? StatsOverlay(
            title: "Receiver",
            parent: receiverWindow,
            provider: { [weak self] in
                guard let self = self else {
                    return (.ndi, nil)
                }
                return (self.receiverModel.selectedTransport,
                        self.receiverModel.activeReceiver?.currentStats())
            }
        )
        receiverStatsOverlay = overlay
        overlay.show()
        receiverStatsMenuItem.title = "Hide Receiver Stats"
    }
```

The closures reference `senderController.activeSender` and `receiverModel.activeReceiver` — these accessors don't exist yet. Add them in the next step.

- [ ] **Step 4: Expose `activeSender` on BroadcastController**

In `Sources/Model/BroadcastController.swift`, add a public reader (next to `currentRoomCode`):

```swift
    var activeSender: VideoSender? { currentSender() }
```

- [ ] **Step 5: Expose `activeReceiver` on ReceiverModel**

In `Sources/Receive/ReceiverModel.swift`, add:

```swift
    var activeReceiver: VideoReceiver? { receiver }
```

- [ ] **Step 6: Build + run**

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -10
```

Open the app. View menu shows "Show Sender Stats" (⌘I) and "Show Receiver Stats" (⇧⌘I). Hit ⌘I — overlay panel appears in the top-right of the Sender window, showing `Window: Sender, Transport: ndi, (no stats)` (NDI adapter returns nil stats). Hit ⌘I again — overlay hides.

- [ ] **Step 7: Commit**

```bash
git add Sources/App/NDIStreamApp.swift Sources/Model/BroadcastController.swift Sources/Receive/ReceiverModel.swift
git commit -m "feat(ui): wire StatsOverlay into View menu with ⌘I / ⇧⌘I toggles"
```

---

## Phase 10: Recording verification (smoke tests)

Recording is transport-agnostic (per spec, Section "Recording verification"): NDIStream's `Recorder` consumes `CMSampleBuffer` from any `VideoReceiverDelegate`. We add smoke tests confirming `.mov` files are written and readable for each *available* transport (NDI). QuicLink and WarpStream are stubs that don't deliver real frames yet — their recording tests are deferred until those adapters wire up.

### Task 16: Add NDI recording smoke test

**Files:**
- Create: `Tests/Transport/RecordingSmokeTests.swift`

- [ ] **Step 1: Write the test**

```swift
import XCTest
import AVFoundation
import CoreMedia
@testable import NDIStream

@MainActor
final class RecordingSmokeTests: XCTestCase {

    /// Confirms the receiver-side recording pipeline produces a readable .mov
    /// when fed synthetic CMSampleBuffers. Transport-agnostic — pins the
    /// pipeline so when QuicLink and WarpStream adapters land they slot in
    /// without breaking the recorder.
    func testReceiverRecorderProducesReadableMov() async throws {
        let recorder = Recorder(filenamePrefix: "SmokeTest")
        recorder.start(slate: "SMOKE", includeAudio: false)
        defer { recorder.stop() }

        for i in 0..<30 {
            let pb = try makeBlackPixelBuffer(width: 320, height: 240)
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            recorder.append(pixelBuffer: pb, pts: pts)
        }
        // Give the writer queue a moment to flush.
        Thread.sleep(forTimeInterval: 0.5)
        recorder.stop()
        Thread.sleep(forTimeInterval: 0.5)

        // Find the most recent .mov in ~/Movies/NDIStream/ matching the prefix.
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NDIStream")
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                      includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let smokeFiles = contents.filter { $0.lastPathComponent.hasPrefix("SmokeTest") }
        guard let latest = smokeFiles.max(by: { (a, b) in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }) else {
            XCTFail("No SmokeTest .mov produced in \(dir.path)")
            return
        }
        defer { try? FileManager.default.removeItem(at: latest) }

        let asset = AVAsset(url: latest)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty, "Recorded .mov should have at least one video track")
    }

    private func makeBlackPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA,
                                          attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pb else {
            throw NSError(domain: "test", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0, CVPixelBufferGetDataSize(pb))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
```

- [ ] **Step 2: Run the test**

```bash
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test -only-testing:NDIStreamTests/RecordingSmokeTests 2>&1 | tail -20
```

Expected: test passes. If it fails because `Recorder.append(pixelBuffer:pts:)` signature differs from what the test calls, adjust the test to match the actual signature (read `Sources/Recording/Recorder.swift` to confirm).

- [ ] **Step 3: Commit**

```bash
git add Tests/Transport/RecordingSmokeTests.swift
git commit -m "test(recording): smoke test confirms transport-agnostic .mov pipeline"
```

---

## Phase 11: Final verification

### Task 17: Run full test suite + manual smoke

- [ ] **Step 1: Full test suite**

```bash
cd "/Users/Shendge/Desktop/Claude_Apps/NDI Stream/NDIStream"
xcodegen generate
xcodebuild -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: all tests pass.

- [ ] **Step 2: Manual sender smoke**

Launch the app. In the Sender window:

1. Verify transport picker shows `NDI | QuicLink | WarpStream`.
2. Pick NDI, hit Start Broadcasting — should work as before.
3. Stop. Pick WarpStream, hit Start Broadcasting — should "start" (stub adapter no-ops) and display Room Code `WS-STUB` with a Copy button. Click Copy, paste — verify `WS-STUB`.
4. Stop. Pick QuicLink, hit Start — verify error message ("Failed to create quicLink sender") since factory still returns nil for QuicLink.

- [ ] **Step 3: Manual receiver smoke**

In the Receiver window:

1. Verify transport picker shows `NDI | QuicLink | WarpStream`.
2. Pick NDI — verify source dropdown lists NDI sources on the LAN as before.
3. Pick WarpStream — verify dropdown empties (stub finder returns no sources) and "Or join by code:" row appears.
4. Type `abc123`, click Join — verify status reads "Joining ABC123…" and DebugLog shows the stub receiver init. Disconnect.
5. Pick QuicLink — same code-entry row should appear (per spec, both code-supporting transports get the affordance).

- [ ] **Step 4: Manual stats overlay smoke**

1. With the Sender window focused, hit ⌘I — verify a translucent overlay appears in the top-right showing `Window: Sender, Transport: ndi, (no stats)`.
2. Hit ⌘I again — overlay disappears.
3. With the Receiver window focused, hit ⇧⌘I — verify overlay appears on the Receiver window.

- [ ] **Step 5: Verify transport persistence**

1. Set Sender transport to WarpStream, Receiver transport to QuicLink. Quit and relaunch.
2. Verify both transports are restored on relaunch (UserDefaults persistence working).

- [ ] **Step 6: No commit needed — final manual verification only**

---

## Done state

After Task 17:

- `.warpStream` is a first-class transport throughout NDIStream's code paths.
- `FoundSource` carries `roomCode`; factory routes the room-code path.
- `TransportStats` value type is defined; NDI adapter returns nil for now (acknowledged).
- WarpStream stub adapter (`WarpStreamTransport.swift`) compiles and exercises code paths without requiring WarpStream's SDK.
- ReceiverModel runs multiple finders concurrently, filters by selected transport, supports manual room-code joins.
- Sender + Receiver windows both show transport pickers; Sender shows room code when broadcasting WarpStream; Receiver shows code-entry field when WarpStream or QuicLink is selected.
- Stats overlay panel (⌘I / ⇧⌘I) polls `currentStats()` at 1Hz and renders the multi-component layout.
- Tests cover: enum case, FoundSource roomCode, TransportStats roundtrip + nil-latencies, factory routing for all three transports, finder mapping seam, ReceiverModel transport filtering + persistence, room-code path, recording smoke for the existing pipeline.

When WarpStream's SDK ships:

1. Add `Low_Latency_UDPstreaming` as a Swift package dependency in `project.yml`.
2. Replace the stubs in `Sources/Transport/WarpStreamTransport.swift` with real adapter wrappers importing `WarpStreamSender` / `WarpStreamReceiver`.
3. Map `WarpStreamDiscoveredSource → FoundSource` in the live finder (using the `mapForTesting` shape that's already pinned by tests).
4. Implement `currentStats() -> TransportStats?` on the live adapters by translating WarpStream's `TransportStats` type to NDIStream's `TransportStats`.

The rest of NDIStream — UI, factory routing, ReceiverModel filtering, stats overlay — keeps working unchanged.

---

## Out of scope for this plan

- Adding QuicLink's adapter file (currently `Sources/QuicLink/` has the raw classes but no `QuicLinkTransport.swift` adapter; that's separate QuicLink work).
- Adding `currentStats()` implementations to QuicLink's sender/receiver (QuicLink has no stats infrastructure today; that's a separate QuicLink plan).
- Adding real Bonjour finder for QuicLink to NDIStream's `makeFinders()` (`Sources/QuicLink/QuicLinkFinder.swift` exists but isn't connected to a `SourceFinder` adapter — that's the QuicLink wiring work).
- Modifying any code in `Low_Latency_UDPstreaming/Sources/` (per user constraint — only docs added to WarpStream).
- The full A/B shootout protocol execution (the spec describes the manual protocol; running it is a follow-up activity, not a code task).
- Codec selection / quality preset wiring inside WarpStream (handled when WarpStream's `WarpStreamResolution` parameter is consumed by the real adapter).
