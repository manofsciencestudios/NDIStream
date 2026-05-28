# QuicLink Plan 2a — Abstraction Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce transport-agnostic Swift protocols (`VideoSender`, `VideoReceiver` + delegate, `SourceFinder`) and NDI adapter classes, then rewire `BroadcastController` and `ReceiverModel` to talk to those protocols via a `TransportFactory`. The NDI path must keep working exactly as today; no QUIC code is added here.

**Architecture:** The existing ObjC classes (`NDISender`, `NDIReceiver`, `NDIFinder`) are wrapped by thin Swift adapters that conform to the new protocols. A `TransportFactory` picks the backend by a `VideoTransportKind` (only `.ndi` is functional in this plan; `.quicLink` returns `nil`, to be implemented in Plan 2c). This is a pure, behavior-preserving refactor that creates the seam the QuicLink backend will later plug into.

**Tech Stack:** Swift 5.9, AppKit/AVFoundation, the existing ObjC NDI layer, XcodeGen, XCTest. macOS 13.

---

## Context for the implementer

- XcodeGen project: `project.yml` is source of truth; `NDIStream.xcodeproj` is gitignored/regenerated. After creating NEW source files under `Sources/`, run `xcodegen generate` before building.
- Working dir: `/Users/mike/Desktop/Desktop/Code Projects/NDI Stream ` (trailing space — quote it). Branch: `feature/quiclink-foundations`.
- Build: `xcodebuild build -project NDIStream.xcodeproj -scheme NDIStream -configuration Debug -destination 'platform=macOS'`
- Test: `xcodebuild test -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS'`
- SourceKit may show phantom "No such module 'XCTest'" / "Cannot find type X" diagnostics — ignore them; `xcodebuild` is authoritative.

**This is a refactor with no automated coverage of the controllers** (they are `@MainActor` AppKit/AVFoundation objects). The acceptance bar for the refactor tasks is: **the app builds cleanly and the existing unit suite still passes.** A final **manual NDI smoke test** (launch app, broadcast a camera, receive it on a second instance/source, confirm recording) is performed by the human controller after the build is green — it is NOT something the implementer subagent can drive, so the implementer's job ends at "builds + unit tests pass."

### Relevant current signatures (do not change the ObjC layer)
- `NDISender(sourceName:clockVideo:)`, `.send(_ pixelBuffer:frameRateN:frameRateD:)`, `.repeatLastFrame(withFrameRateN:frameRateD:)`, `.sendAudio(_:)`, `.stop()`
- `NDIReceiver(sourceName:sourceAddress:)`, `.delegate` (weak), `.stop()`; delegate protocol `NDIReceiverDelegate` with `receiverDidReceive(_:width:height:frameRateN:frameRateD:fourCC:)` (Int32/UInt32), `receiverDidDisconnect()`, optional `receiverDidStall(forSeconds:)`, `receiverDidResume()`, `receiverDidReceiveAudio(_:sampleRate:channels:samplesPerChannel:channelStrideBytes:)`
- `NDIFinder.startNew()` → optional; `.onSourcesChanged: (([NDIFoundSource]) -> Void)?`; `.currentSources() -> [NDIFoundSource]`; `.stop()`. `NDIFoundSource` has `.name`, `.address`.

## File structure (created/modified by this plan)

- Create: `Sources/Transport/VideoTransport.swift` — protocols, `FoundSource`, `VideoTransportKind`.
- Create: `Sources/Transport/NDITransport.swift` — `NDIVideoSender`, `NDIVideoReceiver`, `NDISourceFinder` adapters + `TransportFactory`.
- Create: `Tests/Transport/NDITransportTests.swift` — unit test for `FoundSource` mapping + factory selection.
- Modify: `Sources/Model/BroadcastController.swift` — use `VideoSender` + `transport` selector.
- Modify: `Sources/Receive/ReceiverModel.swift` — use `VideoReceiver`/`SourceFinder`/`FoundSource`/`VideoReceiverDelegate`.

---

### Task 1: Transport protocols

**Files:**
- Create: `Sources/Transport/VideoTransport.swift`

- [ ] **Step 1: Write the protocols file**

Create `Sources/Transport/VideoTransport.swift`:

```swift
import CoreMedia
import CoreVideo
import Foundation

/// Which transport carries video/audio. Persisted as a raw string in UserDefaults.
enum VideoTransportKind: String, CaseIterable {
    case ndi
    case quicLink
}

/// A discovered source the receiver can connect to, tagged by transport.
struct FoundSource: Equatable {
    let name: String
    let address: String
    let transport: VideoTransportKind
}

/// Sends camera frames + audio over some transport. Mirrors the NDISender surface.
protocol VideoSender: AnyObject {
    func send(pixelBuffer: CVPixelBuffer, frameRateN: Int32, frameRateD: Int32)
    func repeatLastFrame(frameRateN: Int32, frameRateD: Int32)
    func sendAudio(_ sampleBuffer: CMSampleBuffer)
    func stop()
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
}

/// Discovers sources on the network for one transport.
protocol SourceFinder: AnyObject {
    var onSourcesChanged: (([FoundSource]) -> Void)? { get set }
    func currentSources() -> [FoundSource]
    func stop()
}
```

- [ ] **Step 2: Regenerate + build**

Run:
```bash
xcodegen generate
xcodebuild build -project NDIStream.xcodeproj -scheme NDIStream -configuration Debug -destination 'platform=macOS'
```
Expected: `** BUILD SUCCEEDED **` (the file only declares types; nothing uses them yet).

- [ ] **Step 3: Commit**

```bash
git add project.yml Sources/Transport/VideoTransport.swift
git commit -m "feat: add transport-agnostic protocols for video send/receive/discover"
```

---

### Task 2: NDI adapters + TransportFactory

**Files:**
- Create: `Sources/Transport/NDITransport.swift`
- Test: `Tests/Transport/NDITransportTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/Transport/NDITransportTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
xcodebuild test -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' -only-testing:NDIStreamTests/NDITransportTests
```
Expected: compile failure — `TransportFactory` / `NDISourceFinder` undefined.

- [ ] **Step 3: Implement `Sources/Transport/NDITransport.swift`**

```swift
import CoreMedia
import CoreVideo
import Foundation

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

/// Wraps NDIFinder, mapping NDIFoundSource → FoundSource tagged `.ndi`.
final class NDISourceFinder: SourceFinder {
    var onSourcesChanged: (([FoundSource]) -> Void)?
    private let finder: NDIFinder?

    init() {
        finder = NDIFinder.startNew()
        finder?.onSourcesChanged = { [weak self] sources in
            self?.onSourcesChanged?(sources.map { Self.map($0.name, $0.address) })
        }
    }

    func currentSources() -> [FoundSource] {
        (finder?.currentSources() ?? []).map { Self.map($0.name, $0.address) }
    }

    func stop() { finder?.stop() }

    static func map(_ name: String, _ address: String) -> FoundSource {
        FoundSource(name: name, address: address, transport: .ndi)
    }

    /// Test seam for the pure mapping (avoids needing a live NDI runtime in unit tests).
    static func mapForTesting(name: String, address: String) -> FoundSource {
        map(name, address)
    }
}

/// Picks transport backends by kind. Only `.ndi` is functional in Plan 2a;
/// `.quicLink` returns nil until Plan 2c implements it.
enum TransportFactory {
    static func makeSender(transport: VideoTransportKind, sourceName: String,
                           clockVideo: Bool) -> VideoSender? {
        switch transport {
        case .ndi: return NDIVideoSender(sourceName: sourceName, clockVideo: clockVideo)
        case .quicLink: return nil
        }
    }

    static func makeReceiver(for source: FoundSource) -> VideoReceiver? {
        switch source.transport {
        case .ndi: return NDIVideoReceiver(sourceName: source.name, sourceAddress: source.address)
        case .quicLink: return nil
        }
    }

    /// The finder(s) the receiver should run. Plan 2c adds a QuicLink finder alongside NDI.
    static func makeFinder() -> SourceFinder {
        NDISourceFinder()
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run:
```bash
xcodegen generate
xcodebuild test -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS' -only-testing:NDIStreamTests/NDITransportTests
```
Expected: all three tests PASS.

- [ ] **Step 5: Commit**

```bash
git add project.yml Sources/Transport/NDITransport.swift Tests/Transport/NDITransportTests.swift
git commit -m "feat: add NDI transport adapters and TransportFactory"
```

---

### Task 3: Rewire BroadcastController to VideoSender + transport selector

**Files:**
- Modify: `Sources/Model/BroadcastController.swift`

- [ ] **Step 1: Change the sender storage type**

In `Sources/Model/BroadcastController.swift`, replace the three sender-related members:

Replace:
```swift
    private var sender: NDISender?
```
with:
```swift
    private var sender: VideoSender?
```

Replace:
```swift
    private func setSender(_ s: NDISender?) {
```
with:
```swift
    private func setSender(_ s: VideoSender?) {
```

Replace:
```swift
    private func currentSender() -> NDISender? {
```
with:
```swift
    private func currentSender() -> VideoSender? {
```

- [ ] **Step 2: Add a persisted `transport` property**

Add this published property near the other `@Published` declarations (e.g. just after the `lowestLatency` block, before `lowestLatencyRelaunchRequired`):

```swift
    @Published var transport: VideoTransportKind {
        didSet {
            UserDefaults.standard.set(transport.rawValue, forKey: "senderTransport")
            if isBroadcasting { restartSender() }
        }
    }
```

And initialize it in `init()` (add near the other UserDefaults reads, before the final `DebugLog.write`):

```swift
        self.transport = UserDefaults.standard.string(forKey: "senderTransport")
            .flatMap(VideoTransportKind.init(rawValue:)) ?? .ndi
```

- [ ] **Step 3: Use the factory at the two creation sites**

Replace (in `start()`):
```swift
            guard let s = NDISender(sourceName: self.sourceName, clockVideo: self.smoothPacing) else {
                DebugLog.write("ERROR NDISender create failed sourceName=\(self.sourceName)")
                self.status = .error("Failed to create NDI sender. Is the NDI runtime installed?")
                self.isTransitioning = false
                return
            }
            DebugLog.write("NDISender created sourceName=\(self.sourceName) clockVideo=\(self.smoothPacing)")
```
with:
```swift
            guard let s = TransportFactory.makeSender(transport: self.transport,
                                                      sourceName: self.sourceName,
                                                      clockVideo: self.smoothPacing) else {
                DebugLog.write("ERROR sender create failed transport=\(self.transport.rawValue) sourceName=\(self.sourceName)")
                self.status = .error("Failed to create \(self.transport.rawValue) sender.")
                self.isTransitioning = false
                return
            }
            DebugLog.write("sender created transport=\(self.transport.rawValue) sourceName=\(self.sourceName) clockVideo=\(self.smoothPacing)")
```

Replace (in `restartSender()`):
```swift
        let fresh = NDISender(sourceName: sourceName, clockVideo: smoothPacing)
```
with:
```swift
        let fresh = TransportFactory.makeSender(transport: transport,
                                                sourceName: sourceName, clockVideo: smoothPacing)
```

- [ ] **Step 4: Fix the two protocol-renamed call sites**

Replace:
```swift
                    snd.send(pb, frameRateN: fpsN, frameRateD: fpsD)
```
with:
```swift
                    snd.send(pixelBuffer: pb, frameRateN: fpsN, frameRateD: fpsD)
```

Replace:
```swift
                snd.repeatLastFrame(withFrameRateN: fpsN, frameRateD: fpsD)
```
with:
```swift
                snd.repeatLastFrame(frameRateN: fpsN, frameRateD: fpsD)
```

(The `currentSender()?.sendAudio(sampleBuffer)` and `outgoing?.stop()` call sites are unchanged — those method names match the protocol.)

- [ ] **Step 5: Build**

Run:
```bash
xcodebuild build -project NDIStream.xcodeproj -scheme NDIStream -configuration Debug -destination 'platform=macOS'
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Model/BroadcastController.swift
git commit -m "refactor: BroadcastController uses VideoSender via TransportFactory"
```

---

### Task 4: Rewire ReceiverModel to VideoReceiver/SourceFinder/FoundSource

**Files:**
- Modify: `Sources/Receive/ReceiverModel.swift`

- [ ] **Step 1: Change stored types**

Replace:
```swift
    @Published var availableSources: [NDIFoundSource] = []
```
with:
```swift
    @Published var availableSources: [FoundSource] = []
```

Replace:
```swift
    private let finder: NDIFinder?
    private var receiver: NDIReceiver?
```
with:
```swift
    private let finder: SourceFinder?
    private var receiver: VideoReceiver?
```

- [ ] **Step 2: Use the factory for the finder**

Replace:
```swift
        self.finder = NDIFinder.startNew()
```
with:
```swift
        self.finder = TransportFactory.makeFinder()
```

(The `finder?.onSourcesChanged = { ... }` closure and `finder?.currentSources()` calls now receive `[FoundSource]` — their bodies use `.name`/`.address`, which `FoundSource` has, so they compile unchanged.)

- [ ] **Step 3: Use the factory for the receiver in `connect()`**

Replace:
```swift
        guard let r = NDIReceiver(sourceName: source.name, sourceAddress: source.address) else {
            DebugLog.write("ERROR receiver create failed name=\(source.name) address=\(source.address)")
            statusLine = "Failed to create receiver"
            return
        }
        r.delegate = self
        receiver = r
```
with:
```swift
        guard let r = TransportFactory.makeReceiver(for: source) else {
            DebugLog.write("ERROR receiver create failed name=\(source.name) address=\(source.address) transport=\(source.transport.rawValue)")
            statusLine = "Failed to create receiver"
            return
        }
        r.delegate = self
        receiver = r
```

- [ ] **Step 4: Update the delegate conformance**

Replace:
```swift
extension ReceiverModel: NDIReceiverDelegate {
    nonisolated func receiverDidReceive(_ sampleBuffer: CMSampleBuffer,
                                        width: Int32,
                                        height: Int32,
                                        frameRateN: Int32,
                                        frameRateD: Int32,
                                        fourCC: UInt32) {
```
with:
```swift
extension ReceiverModel: VideoReceiverDelegate {
    nonisolated func videoReceiverDidReceive(sampleBuffer: CMSampleBuffer,
                                             width: Int32,
                                             height: Int32,
                                             frameRateN: Int32,
                                             frameRateD: Int32,
                                             fourCC: UInt32) {
```

Replace:
```swift
    nonisolated func receiverDidDisconnect() {
```
with:
```swift
    nonisolated func videoReceiverDidDisconnect() {
```

Replace:
```swift
    nonisolated func receiverDidStall(forSeconds seconds: Int) {
```
with:
```swift
    nonisolated func videoReceiverDidStall(forSeconds seconds: Int) {
```

Replace:
```swift
    nonisolated func receiverDidResume() {
```
with:
```swift
    nonisolated func videoReceiverDidResume() {
```

Replace:
```swift
    nonisolated func receiverDidReceiveAudio(_ samples: UnsafePointer<Float>,
                                              sampleRate: Int32,
                                              channels: Int32,
                                              samplesPerChannel: Int32,
                                              channelStrideBytes: Int32) {
```
with:
```swift
    nonisolated func videoReceiverDidReceiveAudio(samples: UnsafePointer<Float>,
                                                  sampleRate: Int32,
                                                  channels: Int32,
                                                  samplesPerChannel: Int32,
                                                  channelStrideBytes: Int32) {
```

(All method BODIES are unchanged — only the names/labels/conformance change. The body of `videoReceiverDidReceive` still does `let w = Int(width)` etc.)

- [ ] **Step 5: Build**

Run:
```bash
xcodebuild build -project NDIStream.xcodeproj -scheme NDIStream -configuration Debug -destination 'platform=macOS'
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Receive/ReceiverModel.swift
git commit -m "refactor: ReceiverModel uses VideoReceiver/SourceFinder/FoundSource"
```

---

### Task 5: Full build + suite + manual NDI smoke

**Files:** none (verification only)

- [ ] **Step 1: Full build + unit suite**

Run:
```bash
xcodegen generate
xcodebuild test -project NDIStream.xcodeproj -scheme NDIStream -destination 'platform=macOS'
```
Expected: `** TEST SUCCEEDED **`, all existing tests still pass (SmokeTest, FrameProtocolTests, VideoCodecTests, NDITransportTests, QuicLoopbackSpikeTests).

- [ ] **Step 2: Manual NDI smoke test (HUMAN controller, not the implementer subagent)**

This step is performed by the human running the session, because it requires driving the GUI. The implementer subagent should STOP after Step 1 and report DONE so the controller can run this:
- Launch the app. Start Broadcasting with a camera.
- Open the Receiver, confirm the broadcast appears as a source, Connect, confirm live video.
- Start/stop a recording on each side; confirm files land in `~/Movies/NDIStream/`.
- Toggle Start/Stop broadcasting a couple of times; confirm no regressions vs. before the refactor.

If anything regresses, that is a bug introduced by the refactor — fix before declaring 2a done.

- [ ] **Step 3: (after manual smoke passes) no extra commit needed** — the refactor commits from Tasks 1–4 stand.

---

## Self-Review (completed during planning)

**Spec coverage:** Plan 2a implements the "abstraction seam" described in the design spec's Architecture section (`VideoSender` / `VideoReceiver` + delegate / `SourceFinder` / `FoundSource` tagged by transport; `BroadcastController`/`ReceiverModel` gain a `transport` selector). The receiver-decodes-before-delivery property is preserved trivially because the NDI adapter forwards the same already-decoded sample buffers. QuicLink backends are explicitly deferred to Plan 2c (factory returns nil), matching the staged decomposition.

**Placeholder scan:** No "TBD"/"TODO" in shipping code. `.quicLink` returning `nil` is intentional and tested (Task 2 tests assert it), not a placeholder.

**Type consistency:** `VideoTransportKind` (Task 1) is used by `TransportFactory` (Task 2) and the `transport` property (Task 3). `FoundSource` (Task 1) is produced by `NDISourceFinder` (Task 2) and consumed by `ReceiverModel.availableSources` (Task 4). `VideoReceiverDelegate` method names defined in Task 1 (`videoReceiverDidReceive(sampleBuffer:...)`, `videoReceiverDidDisconnect`, `videoReceiverDidStall(forSeconds:)`, `videoReceiverDidResume`, `videoReceiverDidReceiveAudio(samples:...)`) exactly match the NDI adapter's forwarding calls (Task 2) and `ReceiverModel`'s conformance (Task 4). `VideoSender` methods (`send(pixelBuffer:...)`, `repeatLastFrame(frameRateN:...)`, `sendAudio`, `stop`) match the adapter (Task 2) and the updated `BroadcastController` call sites (Task 3).

**Risk:** The only behavioral risk is the controller refactor. Mitigated by: (a) method bodies are unchanged, only types/names; (b) full build + unit suite; (c) mandatory manual NDI smoke before sign-off.

---

## Execution Handoff

After this plan: Plan 2b (QuicTLS) and Plan 2c (QuicLink transport core) follow. The seam created here is what 2c's `QuicLinkSender`/`QuicLinkReceiver`/`QuicLinkFinder` conform to, and `TransportFactory`'s `.quicLink` branches are where they get wired in.
