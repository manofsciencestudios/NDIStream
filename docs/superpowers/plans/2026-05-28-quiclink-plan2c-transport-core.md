# QuicLink Plan 2c — Transport Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the working QuicLink transport — `QuicLinkSender`, `QuicLinkReceiver`, `QuicLinkFinder`, and the `QuicTLS` identity/pinning helper — conforming to the Plan 2a seam protocols, using Plan 1's `FrameProtocol`/`VideoEncoder`/`VideoDecoder` and the spike-verified Network.framework QUIC + TLS API. End state: NDIStream can send and receive video+audio over QuicLink, proven by an in-process loopback integration test, with the drop-never-stall jitter buffer in place.

**Architecture:** Sender = QUIC server (`NWListener`) advertising over Bonjour with its cert pin in the TXT record; receiver = QUIC client (`NWConnectionGroup`) that pins the advertised cert. Every video frame is all-intra and **carries its own codec parameter sets**, so any frame is independently decodable and join-in-progress needs no video handshake. Each frame is sent on its own QUIC stream (drop-don't-stall); the receiver runs a hard-deadline jitter buffer and decodes off the network thread.

**Tech Stack:** Swift 5.9, Network.framework (QUIC: `NWListener`/`NWConnectionGroup`/`NWMultiplexGroup`/`NWBrowser`), Security (`SecIdentity`/`sec_protocol_*`), VideoToolbox, CoreMedia. macOS 13, Apple Silicon.

---

## Read this first — scope, risk, and how to execute

This plan is **large and networking-heavy**. Unlike Plans 1/2a (deterministic, fully-specified code), the Sender/Receiver tasks involve async choreography that is **developed iteratively against the compiler and the loopback runtime** — exactly as the spike was. The spike (`Tests/Spikes/QuicLoopbackSpikeTests.swift`) already verified every API call used here; **read it before starting Tasks 4–5**, it is the working reference for: building QUIC `NWParameters`, attaching a local identity, the pinning verify block, opening streams via `NWConnection(from: group)`, and accepting inbound streams via `listener.newConnectionHandler`.

The acceptance gate for the whole plan is **Task 7: an in-process loopback integration test** that sends real encoded frames sender→receiver over QUIC and asserts they decode — plus a drop-don't-stall assertion. Implementers should treat "the integration test passes" as truth, and iterate the async code until it does. It is fine to report DONE_WITH_CONCERNS and surface specific async/timing issues for the controller.

**Dependencies already in the tree (from Plans 1 & 2a):**
- `FrameProtocol.swift`: `QLCodec`, `VideoFrameHeader` (extended in Task 1 here).
- `VideoEncoder` (all-intra; note: its Plan-1 per-frame `CompleteFrames` flush is replaced by streaming emission in Task 4) / `VideoDecoder`.
- Seam: `VideoSender`, `VideoReceiver`(+`VideoReceiverDelegate`), `SourceFinder`, `FoundSource`, `VideoTransportKind`, `TransportFactory`.
- Verified spike for QUIC+TLS API shapes.

**Project facts:** XcodeGen (`xcodegen generate` after adding files); dir `/Users/mike/Desktop/Desktop/Code Projects/NDI Stream ` (trailing space — quote it); branch `feature/quiclink-foundations`. Build/test via `xcodebuild ... -scheme NDIStream -destination 'platform=macOS'`. SourceKit cross-file diagnostics are phantom; `xcodebuild` is authoritative.

## File structure

- Modify: `Sources/QuicLink/FrameProtocol.swift` — carry parameter sets + add audio/control message framing.
- Create: `Sources/QuicLink/CodecParameterSets.swift` — extract/rebuild HEVC/H264 parameter sets ↔ `CMFormatDescription`.
- Create: `Sources/QuicLink/QuicTLS.swift` — self-signed identity (generate once, persist), pin (DER SHA-256), server-attach + client-pin helpers.
- Create: `Sources/QuicLink/QuicLinkProtocol.swift` — shared constants: Bonjour service type, ALPN, TXT keys, control-message cod(capabilities).
- Create: `Sources/QuicLink/QuicLinkFinder.swift` — `SourceFinder` via `NWBrowser`.
- Create: `Sources/QuicLink/QuicLinkSender.swift` — `VideoSender` via `NWListener` + encoder + fan-out.
- Create: `Sources/QuicLink/JitterBuffer.swift` — hard-deadline playout buffer (pure, unit-tested).
- Create: `Sources/QuicLink/QuicLinkReceiver.swift` — `VideoReceiver` via `NWConnectionGroup` + jitter buffer + decoder.
- Modify: `Sources/Transport/VideoTransport.swift` — extend `FoundSource` with optional `pinSHA256` + `port`.
- Modify: `Sources/Transport/NDITransport.swift` — `TransportFactory` wires `.quicLink`; `makeFinders()` returns NDI + QuicLink.
- Modify: `Sources/Receive/ReceiverModel.swift` — run multiple finders, merge sources.
- Create: `Tests/QuicLink/FrameProtocolParamSetsTests.swift`, `Tests/QuicLink/JitterBufferTests.swift`, `Tests/QuicLink/QuicLinkLoopbackTests.swift`.

UI toggle (`NDI / Direct`), congestion-adaptive bitrate, and multi-receiver fan-out polish are **Plan 2d** (this plan supports a single receiver cleanly and structures for many).

---

### Task 1: Extend FrameProtocol to carry parameter sets + message kinds

All-intra frames are self-contained only if each carries its codec parameter sets (HEVC VPS/SPS/PPS or H264 SPS/PPS). This task extends the wire format and adds a message-kind byte so one stream type can carry video, and a separate stream can carry audio/control.

**Files:** Modify `Sources/QuicLink/FrameProtocol.swift`; create `Tests/QuicLink/FrameProtocolParamSetsTests.swift`.

- [ ] **Step 1: Failing test** — create `Tests/QuicLink/FrameProtocolParamSetsTests.swift`:

```swift
import XCTest
@testable import NDIStream

final class FrameProtocolParamSetsTests: XCTestCase {
    func testVideoPacketRoundTripWithParameterSets() throws {
        let vps = Data([0x40, 0x01, 0x0c]); let sps = Data([0x42, 0x01]); let pps = Data([0x44, 0x01])
        let payload = Data([0xAA, 0xBB, 0xCC])
        let packet = VideoPacket(codec: .hevc, isKeyframe: true, ptsNanos: 99,
                                 width: 1920, height: 1080,
                                 parameterSets: [vps, sps, pps], payload: payload)
        let wire = packet.serialize()
        let parsed = try XCTUnwrap(VideoPacket.parse(wire))
        XCTAssertEqual(parsed.codec, .hevc)
        XCTAssertEqual(parsed.parameterSets, [vps, sps, pps])
        XCTAssertEqual(parsed.payload, payload)
        XCTAssertEqual(parsed.width, 1920)
        XCTAssertEqual(parsed.ptsNanos, 99)
    }

    func testParseRejectsTruncated() {
        let packet = VideoPacket(codec: .h264, isKeyframe: true, ptsNanos: 0, width: 2, height: 2,
                                 parameterSets: [Data([1, 2])], payload: Data([9]))
        var wire = packet.serialize()
        wire.removeLast(3)
        XCTAssertNil(VideoPacket.parse(wire))
    }
}
```

- [ ] **Step 2: Run, verify it fails** (`VideoPacket` undefined).

- [ ] **Step 3: Implement** — replace the contents of `Sources/QuicLink/FrameProtocol.swift` with the following (keeps `QLCodec`; replaces the bare `VideoFrameHeader` with a richer `VideoPacket` that includes parameter sets; keeps the big-endian helpers):

```swift
import Foundation

enum QLCodec: UInt8 {
    case h264 = 0
    case hevc = 1
}

/// One QuicLink video frame on the wire: a header, the codec parameter sets
/// (carried on every all-intra frame so any frame is independently decodable),
/// then the AVCC payload. All multi-byte fields are big-endian.
///
/// Header layout (fixed 24 bytes):
///   magic(2)=0x514C, version(1), codec(1), flags(1: bit0 keyframe), reserved(1),
///   ptsNanos(8), width(2), height(2), parameterSetsLength(4), payloadLength(4)
/// Then `parameterSetsLength` bytes of parameter-set blob:
///   count(1), then for each set: length(4) + bytes
/// Then `payloadLength` bytes of AVCC payload.
struct VideoPacket: Equatable {
    static let magic: UInt16 = 0x514C
    static let version: UInt8 = 2
    static let headerByteCount = 24
    private static let keyframeFlag: UInt8 = 0x01

    var codec: QLCodec
    var isKeyframe: Bool
    var ptsNanos: Int64
    var width: UInt16
    var height: UInt16
    var parameterSets: [Data]
    var payload: Data

    func serialize() -> Data {
        let psBlob = Self.encodeParameterSets(parameterSets)
        var d = Data(capacity: Self.headerByteCount + psBlob.count + payload.count)
        d.appendBE(Self.magic)
        d.append(Self.version)
        d.append(codec.rawValue)
        d.append(isKeyframe ? Self.keyframeFlag : 0)
        d.append(0) // reserved
        d.appendBE(UInt64(bitPattern: ptsNanos))
        d.appendBE(width)
        d.appendBE(height)
        d.appendBE(UInt32(psBlob.count))
        d.appendBE(UInt32(payload.count))
        d.append(psBlob)
        d.append(payload)
        return d
    }

    static func parse(_ data: Data) -> VideoPacket? {
        guard data.count >= headerByteCount else { return nil }
        var c = ByteCursor(data)
        guard c.readBE() as UInt16 == magic else { return nil }
        guard c.readByte() == version else { return nil }
        guard let codec = QLCodec(rawValue: c.readByte()) else { return nil }
        let flags = c.readByte()
        _ = c.readByte()
        let pts = Int64(bitPattern: c.readBE() as UInt64)
        let width: UInt16 = c.readBE()
        let height: UInt16 = c.readBE()
        let psLen = Int(c.readBE() as UInt32)
        let payLen = Int(c.readBE() as UInt32)
        guard data.count >= headerByteCount + psLen + payLen else { return nil }
        let psStart = data.startIndex + headerByteCount
        let psBlob = data.subdata(in: psStart ..< psStart + psLen)
        guard let sets = decodeParameterSets(psBlob) else { return nil }
        let payStart = psStart + psLen
        let payload = data.subdata(in: payStart ..< payStart + payLen)
        return VideoPacket(codec: codec, isKeyframe: (flags & keyframeFlag) != 0,
                           ptsNanos: pts, width: width, height: height,
                           parameterSets: sets, payload: payload)
    }

    private static func encodeParameterSets(_ sets: [Data]) -> Data {
        var d = Data()
        d.append(UInt8(sets.count))
        for s in sets { d.appendBE(UInt32(s.count)); d.append(s) }
        return d
    }

    private static func decodeParameterSets(_ blob: Data) -> [Data]? {
        guard !blob.isEmpty else { return [] }
        var c = ByteCursor(blob)
        let count = Int(c.readByte())
        var sets: [Data] = []
        for _ in 0..<count {
            guard c.remaining >= 4 else { return nil }
            let len = Int(c.readBE() as UInt32)
            guard c.remaining >= len else { return nil }
            sets.append(c.readBytes(len))
        }
        return sets
    }
}

extension Data {
    mutating func appendBE(_ v: UInt16) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: UInt64) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
}

struct ByteCursor {
    let data: Data
    var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }
    var remaining: Int { data.endIndex - offset }
    mutating func readByte() -> UInt8 { defer { offset += 1 }; return data[offset] }
    mutating func readBytes(_ n: Int) -> Data { defer { offset += n }; return data.subdata(in: offset ..< offset + n) }
    mutating func readBE() -> UInt16 { defer { offset += 2 }; return (UInt16(data[offset]) << 8) | UInt16(data[offset+1]) }
    mutating func readBE() -> UInt32 { defer { offset += 4 }; var v: UInt32 = 0; for i in 0..<4 { v = (v << 8) | UInt32(data[offset+i]) }; return v }
    mutating func readBE() -> UInt64 { defer { offset += 8 }; var v: UInt64 = 0; for i in 0..<8 { v = (v << 8) | UInt64(data[offset+i]) }; return v }
}
```

> Note: this replaces `VideoFrameHeader` with `VideoPacket`. Plan 1's `FrameProtocolTests` and the codec round-trip test reference `VideoFrameHeader` — UPDATE those two test files to use `VideoPacket` (same fields plus `parameterSets: []` where they previously passed none, and `.payload`/`.parse` accessors). Keep their assertions equivalent. Run the FULL suite at the end of this task and confirm green.

- [ ] **Step 4: Run** the new test + the updated Plan-1 tests; all pass. **Step 5: Commit** (`feat: carry codec parameter sets in QuicLink video packets`).

---

### Task 2: CodecParameterSets — extract/rebuild ↔ CMFormatDescription

**Files:** Create `Sources/QuicLink/CodecParameterSets.swift`; test `Tests/QuicLink/CodecParameterSetsTests.swift`.

- [ ] **Step 1: Failing test** — encode a real frame (reuse `VideoEncoder` + `PixelBufferFactory`), extract its parameter sets from the `CMFormatDescription`, rebuild a `CMFormatDescription`, and assert the rebuilt one decodes the frame (round-trip through `VideoDecoder`). Test body:

```swift
import XCTest
import CoreMedia
import VideoToolbox
@testable import NDIStream

final class CodecParameterSetsTests: XCTestCase {
    func testExtractAndRebuildHEVC() throws {
        let enc = try XCTUnwrap(VideoEncoder(width: 320, height: 240, codec: .hevc, fps: 30, bitrate: 2_000_000))
        let exp = expectation(description: "encoded"); var frame: VideoEncoder.EncodedFrame?
        enc.onEncodedFrame = { if frame == nil { frame = $0; exp.fulfill() } }
        enc.encode(PixelBufferFactory.solid(width: 320, height: 240), pts: CMTime(value: 0, timescale: 30))
        wait(for: [exp], timeout: 5.0); let f = try XCTUnwrap(frame)

        let sets = try XCTUnwrap(CodecParameterSets.extract(from: f.formatDescription, codec: .hevc))
        XCTAssertEqual(sets.count, 3) // VPS, SPS, PPS
        let rebuilt = try XCTUnwrap(CodecParameterSets.makeFormatDescription(codec: .hevc, parameterSets: sets))

        let dec = try XCTUnwrap(VideoDecoder(formatDescription: rebuilt))
        let decoded = expectation(description: "decoded"); var pb: CVPixelBuffer?
        dec.onDecodedFrame = { b, _ in if pb == nil { pb = b; decoded.fulfill() } }
        dec.decode(f.data, pts: f.pts, isKeyframe: true)
        wait(for: [decoded], timeout: 5.0)
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(pb)), 320)
        enc.invalidate(); dec.invalidate()
    }
}
```

- [ ] **Step 2/3: Implement** `Sources/QuicLink/CodecParameterSets.swift`:

```swift
import CoreMedia
import Foundation

enum CodecParameterSets {
    /// Extract the parameter sets (HEVC: VPS,SPS,PPS / H264: SPS,PPS) from a format description.
    static func extract(from fmt: CMFormatDescription, codec: QLCodec) -> [Data]? {
        var count = 0
        // First query the count (index 0, nil pointers, get count out).
        let probe: OSStatus = codec == .hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard probe == noErr, count > 0 else { return nil }
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st: OSStatus = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard st == noErr, let ptr else { return nil }
            sets.append(Data(bytes: ptr, count: size))
        }
        return sets
    }

    /// Rebuild a format description from parameter sets (NAL length = 4, matching VideoToolbox AVCC).
    static func makeFormatDescription(codec: QLCodec, parameterSets: [Data]) -> CMFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        let pointers = parameterSets.map { $0.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! } }
        let sizes = parameterSets.map { $0.count }
        var fmt: CMFormatDescription?
        // NOTE: the pointers above must stay valid for the call; bind within a withUnsafe… nest if
        // the compiler/ASAN complains. The implementer should use nested withUnsafeBufferPointer
        // closures to guarantee lifetime — see implementation note below.
        let status: OSStatus = codec == .hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        return status == noErr ? fmt : nil
    }
}
```

> IMPLEMENTATION NOTE (lifetime): the `pointers` array built with `withUnsafeBytes { ... baseAddress! }` escapes the closure — that is undefined behavior. The implementer MUST rewrite `makeFormatDescription` to nest the parameter-set buffers' `withUnsafeBufferPointer` closures (or copy into stable `[UnsafePointer<UInt8>]` backed by manually-managed memory) so the pointers are valid during the `CMVideoFormatDescriptionCreateFrom…` call. The test above is the gate: if the rebuilt format description decodes the frame, the lifetime is correct. Iterate until the test passes.

- [ ] **Step 4/5: Run test (pass), commit** (`feat: extract/rebuild HEVC/H264 parameter sets`).

---

### Task 3: QuicTLS — self-signed identity + pinning (productionizes the spike)

**Files:** Create `Sources/QuicLink/QuicTLS.swift`, `Sources/QuicLink/QuicLinkProtocol.swift`; test `Tests/QuicLink/QuicTLSTests.swift`.

The spike proved the mechanics (`Tests/Spikes/QuicLoopbackSpikeTests.swift`). This task packages them: generate a self-signed identity once and persist it (Application Support), expose the DER-SHA256 pin, and provide server-attach + client-pin helpers used by sender/receiver.

- [ ] **Step 1:** Create `Sources/QuicLink/QuicLinkProtocol.swift` with shared constants:

```swift
import Foundation

enum QuicLinkProtocol {
    static let bonjourServiceType = "_ndistream-ql._udp"
    static let alpn = "ndistream-quiclink-v1"
    static let txtKeySourceName = "src"
    static let txtKeyPinSHA256Hex = "pin"
    /// Control-stream message kinds (first byte of a control message).
    enum ControlKind: UInt8 { case capabilities = 1, codecChoice = 2, heartbeat = 3, tally = 4 }
}
```

- [ ] **Step 2:** Implement `Sources/QuicLink/QuicTLS.swift`. Port the spike's working recipe: generate self-signed cert+key via `/usr/bin/openssl` into Application Support (`~/Library/Application Support/NDIStream/quiclink-identity.p12`) IF not present, `SecPKCS12Import` to a `SecIdentity`, wrap as `sec_identity_t`, and expose `certSHA256` (DER hash). Provide:
  - `static func loadOrCreate() -> QuicTLS?` (idempotent; reuses the persisted p12)
  - `var identity: sec_identity_t`, `var pinSHA256: Data`, `var pinHex: String`
  - `func attachServer(to options: NWProtocolQUIC.Options)` → `sec_protocol_options_set_local_identity`
  - `static func clientOptions(pinSHA256: Data) -> NWProtocolQUIC.Options` → sets a `sec_protocol_options_set_verify_block` that pins the leaf cert's DER SHA-256 (copy the spike's verify block verbatim).
  Reuse the spike's openssl-pkcs12 invocation (LibreSSL legacy PBE; no `-legacy`). Reuse the spike's `SecTrustCopyCertificateChain` + SHA-256 comparison.

- [ ] **Step 3:** Test `Tests/QuicLink/QuicTLSTests.swift`: `loadOrCreate()` twice returns the SAME pin (idempotent persistence); `pinHex` is 64 hex chars. (Full handshake is already proven by the spike; do not duplicate it here.)

- [ ] **Step 4/5: Run, commit** (`feat: QuicTLS self-signed identity + pinning`).

> SECURITY NOTE to record in the design spec when this lands: the pin is distributed via the Bonjour TXT record (same channel as discovery), so pinning gives encryption + passive-MITM protection but not active-on-path-MITM protection on a hostile LAN. Acceptable for a private set network; trust-on-first-use or out-of-band pin exchange is the hardening follow-up.

---

### Task 4: QuicLinkSender + QuicLinkFinder (advertise side)

**Files:** Create `Sources/QuicLink/QuicLinkSender.swift`, `Sources/QuicLink/QuicLinkFinder.swift`. (No standalone unit test — exercised by Task 7's loopback integration test.)

- [ ] **Step 1: `QuicLinkSender: VideoSender`.** Responsibilities (read the spike for exact API):
  - `init?(sourceName:)`: `QuicTLS.loadOrCreate()`; build server `NWProtocolQUIC.Options` (ALPN, `direction = .bidirectional`, attach identity); start `NWListener`; set `service` for Bonjour advertise with TXT (`src` = sourceName, `pin` = pinHex); on `listener.newConnectionGroupHandler`/`newConnectionHandler`, retain the inbound connection group and run the control-stream read loop (receive `capabilities`, reply `codecChoice`).
  - Hold a `VideoEncoder?` created lazily on the first `send(pixelBuffer:)` using that frame's dimensions and the negotiated codec (HEVC unless a connected receiver reported no-HEVC → H264). Use **streaming emission**: set `onEncodedFrame` once; do NOT call `CompleteFrames` per frame (that was a Plan-1 test-only shim).
  - `send(pixelBuffer:frameRateN:frameRateD:)`: feed the encoder. In `onEncodedFrame`: extract parameter sets via `CodecParameterSets.extract`, build a `VideoPacket`, `serialize()`, and for EACH connected receiver group open a new stream `NWConnection(from: group)` and send the packet with `isComplete: true` (closes the stream = one complete frame message). Encode once, fan out the bytes.
  - `sendAudio(_:)`: convert to planar float (reuse the approach in `NDISender.mm`'s audio path — or send interleaved PCM with a small audio header on a dedicated long-lived audio stream per receiver). Keep audio simple: one audio packet per buffer on its own stream.
  - `stop()`: cancel listener + all groups + encoder.invalidate().

- [ ] **Step 2: `QuicLinkFinder: SourceFinder`.** `NWBrowser` for `QuicLinkProtocol.bonjourServiceType`; on results changed, resolve each endpoint and read its TXT (`src`, `pin`); emit `FoundSource(name:, address: "host:port", transport: .quicLink, pinSHA256: <from hex>, port: <port>)` (see Task 6 for the `FoundSource` extension). De-dupe by name.

- [ ] **Step 3: Build only** (`xcodebuild build`). These compile against the verified API; runtime correctness is proven in Task 7. **Commit** (`feat: QuicLinkSender + QuicLinkFinder`).

---

### Task 5: JitterBuffer + QuicLinkReceiver (receive side)

**Files:** Create `Sources/QuicLink/JitterBuffer.swift` (+ `Tests/QuicLink/JitterBufferTests.swift`), `Sources/QuicLink/QuicLinkReceiver.swift`.

- [ ] **Step 1: JitterBuffer (pure, TDD).** A small ordered buffer keyed by pts with a hard deadline: `push(packet, pts)`; a `pop()` returns the next in-order packet whose playout time has arrived and DROPS any packet older than the newest-by-more-than-deadline. The key property to test: given frames arriving out of order and one arriving "too late," `pop` yields frames in pts order and never blocks waiting for the late one (it is dropped). Test:

```swift
import XCTest
@testable import NDIStream

final class JitterBufferTests: XCTestCase {
    func testDropsLateFrameAndKeepsAdvancing() {
        let jb = JitterBuffer(maxDepth: 3)
        jb.push(id: 1, ptsNanos: 1000)
        jb.push(id: 3, ptsNanos: 3000)   // out of order, 2 missing
        jb.push(id: 4, ptsNanos: 4000)   // depth exceeded -> oldest gap (2) abandoned
        var out: [Int] = []
        while let p = jb.popReady(nowDeadlinePassedForOldest: true) { out.append(p.id) }
        XCTAssertEqual(out, [1, 3, 4], "in pts order, never stalling for the missing frame 2")
    }
}
```
Implement `JitterBuffer` accordingly (a small sorted structure with a max depth; when depth exceeds `maxDepth`, release the oldest even if a gap precedes it — drop-don't-stall). Keep it a plain class with `id`/`ptsNanos` and the parsed `VideoPacket` as payload.

- [ ] **Step 2: `QuicLinkReceiver: VideoReceiver`.** (read the spike for client/group/stream API):
  - `init?(host:port:pinSHA256:)`: build client `NWProtocolQUIC.Options` via `QuicTLS.clientOptions(pinSHA256:)`; `NWConnectionGroup` over `NWMultiplexGroup(to: endpoint)`; mandatory `newConnectionHandler` to accept inbound per-frame streams; open the control stream and send `capabilities` (HEVC decode via `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)`).
  - For each inbound stream: receive the full message (read until `isComplete`), `VideoPacket.parse`, push into the `JitterBuffer`.
  - A display timer pops ready frames; for each, lazily build/refresh the `VideoDecoder` from the packet's parameter sets (rebuild if they change), `decode` on a dedicated decode `DispatchQueue` (NOT the network thread), and on decoded pixel buffer call `delegate?.videoReceiverDidReceive(sampleBuffer:width:height:frameRateN:frameRateD:fourCC:)` — wrapping the decoded `CVPixelBuffer` in a `CMSampleBuffer` (use `CMSampleBufferCreateForImageBuffer`).
  - Audio stream: parse PCM packets → `delegate?.videoReceiverDidReceiveAudio(...)`.
  - Heartbeat/stall: if no frame for N seconds, `delegate?.videoReceiverDidStall(forSeconds:)`; on resume, `videoReceiverDidResume()`. On group failure, `videoReceiverDidDisconnect()`.
  - `stop()`: cancel group, decoder.invalidate(), stop timer.

- [ ] **Step 3: Build + run JitterBufferTests** (pass). **Commit** (`feat: JitterBuffer + QuicLinkReceiver`).

---

### Task 6: Wire the seam (FoundSource extension, TransportFactory, ReceiverModel multi-finder)

**Files:** Modify `Sources/Transport/VideoTransport.swift`, `Sources/Transport/NDITransport.swift`, `Sources/Receive/ReceiverModel.swift`.

- [ ] **Step 1:** Extend `FoundSource` with QuicLink connection info (NDI leaves them nil):

```swift
struct FoundSource: Equatable {
    let name: String
    let address: String
    let transport: VideoTransportKind
    var port: UInt16? = nil
    var pinSHA256: Data? = nil
}
```
(NDI construction sites pass only name/address/transport — defaults keep them compiling.)

- [ ] **Step 2:** In `TransportFactory`: implement the `.quicLink` branches — `makeSender(.quicLink, sourceName:, clockVideo:)` → `QuicLinkSender(sourceName:)`; `makeReceiver(for:)` `.quicLink` → `QuicLinkReceiver(host: source.address-host, port: source.port!, pinSHA256: source.pinSHA256!)`. Replace `makeFinder()` with `makeFinders() -> [SourceFinder]` returning `[NDISourceFinder(), QuicLinkFinder()]`.

- [ ] **Step 3:** In `ReceiverModel`: change the single `finder` to an array of finders from `makeFinders()`; merge their `onSourcesChanged` outputs into `availableSources` (keep a per-finder latest list, concatenate + sort; tag is already on each `FoundSource`). Keep the existing auto-select logic operating on the merged list.

- [ ] **Step 4:** Build + full suite. **Commit** (`feat: wire QuicLink into TransportFactory and ReceiverModel`).

---

### Task 7: Loopback integration test (the acceptance gate)

**Files:** Create `Tests/QuicLink/QuicLinkLoopbackTests.swift`.

- [ ] **Step 1:** In-process end-to-end test: create a `QuicLinkSender(sourceName: "Loopback")`; discover it with a `QuicLinkFinder` (or connect directly by reading the sender's advertised port/pin — simplest is to expose the sender's port + `QuicTLS.pinSHA256` via test-only accessors and build the receiver directly, avoiding Bonjour timing in the test); create a `QuicLinkReceiver` to it with a delegate that captures decoded frames; drive `sender.send(pixelBuffer:)` with `PixelBufferFactory.solid` frames at ~30fps for ~1s; assert the delegate received decoded frames of the right dimensions.

- [ ] **Step 2:** Add a drop-don't-stall assertion at the integration level if feasible (e.g. inject a gap and assert playback continued). If hard to simulate over real QUIC in-process, rely on `JitterBufferTests` for that property and note it.

- [ ] **Step 3:** Iterate the Sender/Receiver async code until this test reliably passes. **Step 4: Commit** (`test: QuicLink end-to-end loopback integration`).

- [ ] **Step 5: Full suite green**, then hand back to controller for hardware validation (two Macs) — covered in Plan 2d along with the UI toggle.

---

## Self-Review (planning)

**Spec coverage:** Sender pipeline (encode→packetize→stream-per-frame), receiver pipeline (discover→connect→jitter→decode→deliver), all-intra self-contained frames, drop-don't-stall (JitterBuffer), PCM audio, TLS pinning, Bonjour discovery, seam wiring — all mapped to Tasks 1–7. Deferred to **Plan 2d**: UI toggle, congestion-adaptive bitrate, multi-receiver fan-out hardening, hardware validation.

**Placeholders:** None in the deterministic tasks (1,2,3,6,7 have concrete code/tests). Tasks 4–5 (Sender/Receiver) intentionally specify architecture + responsibilities + the exact verified API source (the spike) rather than full line-by-line code, because the async choreography must be developed against the runtime — this is called out explicitly and gated by Task 7's integration test. This is the honest treatment of networking code, not a hidden placeholder.

**Type consistency:** `VideoPacket` (Task 1) is produced by the sender (Task 4) and consumed by the receiver/JitterBuffer (Task 5). `CodecParameterSets` (Task 2) is used by both. `QuicTLS`/`QuicLinkProtocol` (Task 3) by sender+receiver. `FoundSource.port/pinSHA256` (Task 6) produced by `QuicLinkFinder` (Task 4), consumed by `TransportFactory.makeReceiver` (Task 6). Seam protocol method names match Plan 2a.

**Risk:** Tasks 4–5 are the hard part. Mitigation: the spike already compiled+ran every API call they use; Task 7 is an automatable acceptance gate; implementers may report DONE_WITH_CONCERNS with specific async issues for controller help.

## Execution Handoff
After 2c: **Plan 2d** — UI transport toggle, congestion-adaptive bitrate, multi-receiver fan-out, and two-Mac hardware validation (including a real RF-congestion drop-don't-stall check against NDI).
