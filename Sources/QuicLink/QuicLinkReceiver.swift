import CoreMedia
import CoreVideo
import Foundation
import Network
import VideoToolbox

/// QuicLink video receiver: a QUIC client that pins the sender's cert.
///
/// ## Stream model (proven in QuicServerStreamSpike)
/// Network.framework only allows the CLIENT to open QUIC streams; the server replies on
/// the same stream. So the receiver runs a **request/reply pull loop**: it opens a client
/// request, sends one byte, reads one `VideoPacket` reply (the next encoded frame), then
/// opens the next request. Each frame on its own stream preserves drop-don't-stall.
///
/// Parsed packets feed a `JitterBuffer`; a display timer pops ready packets and decodes
/// them off the network thread. Decoded pixel buffers are wrapped in `CMSampleBuffer`s and
/// handed to the delegate. The decoder is (re)built from each packet's parameter sets.
final class QuicLinkReceiver: VideoReceiver {

    weak var delegate: VideoReceiverDelegate?

    /// One request at a time avoids racing multiple in-process QUIC handshakes on loopback.
    private static let poolSize = 1

    // MARK: - Networking

    private let endpoint: NWEndpoint
    private let params: NWParameters
    private let netQueue = QuicLinkProtocol.networkQueue
    /// Single serial queue that owns the jitter buffer + decoder (both single-threaded).
    private let decodeQueue = DispatchQueue(label: "quiclink.receiver.decode")
    private let activeLock = NSLock()
    private var activeRequests: [NWConnection] = []
    private var stopped = false

    // MARK: - Decode pipeline (decodeQueue only)

    private let jitter = JitterBuffer(maxDepth: 2)
    private var decoder: VideoDecoder?
    private var currentParameterSets: [Data] = []
    private var displayTimer: DispatchSourceTimer?

    // MARK: - Init

    init?(host: String, port: UInt16, pinSHA256: Data) {
        let quic = QuicTLS.clientOptions(alpn: QuicLinkProtocol.alpn, pinSHA256: pinSHA256)
        quic.isDatagram = false
        quic.direction = .bidirectional
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            NSLog("QuicLinkReceiver: invalid port \(port)")
            return nil
        }
        // Build the host as an IP literal when possible. `NWEndpoint.Host(<String var>)`
        // produces a `.name` (DNS) endpoint even for "127.0.0.1", which never resolves on
        // loopback and leaves the connection group stuck before `.preparing`. Parsing the IP
        // explicitly yields a `.ipv4`/`.ipv6` endpoint that connects directly (matching the
        // proven spike, which used a string *literal* the compiler parsed as an IP).
        let nwHost: NWEndpoint.Host
        if let v4 = IPv4Address(host) {
            nwHost = .ipv4(v4)
        } else if let v6 = IPv6Address(host) {
            nwHost = .ipv6(v6)
        } else {
            nwHost = NWEndpoint.Host(host)
        }
        endpoint = NWEndpoint.hostPort(host: nwHost, port: nwPort)
        params = NWParameters(quic: quic)
        startDisplayTimer()
        netQueue.async {
            for _ in 0..<Self.poolSize { self.openRequestStream() }
        }
    }

    // MARK: - Request/reply pull pool

    /// Open one frame-request stream: send a 1-byte request, read the full reply (one
    /// complete `VideoPacket`), push it to the jitter buffer, then open a replacement.
    private func openRequestStream() {
        if stopped { return }
        let stream = NWConnection(to: endpoint, using: params)
        retainRequest(stream)
        stream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Half-close our send side after the 1-byte request. The stream remains
                // bidirectional, allowing the server to reply on its send side.
                stream.send(content: Data([0x01]), isComplete: true,
                            completion: .contentProcessed { _ in })
                self.receiveReply(on: stream, accumulated: Data())
            case .failed:
                self.close(stream)
            default:
                break
            }
        }
        stream.start(queue: netQueue)
    }

    /// Accumulate reply bytes until they form a complete `VideoPacket`, then enqueue.
    private func receiveReply(on stream: NWConnection, accumulated: Data) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var total = accumulated
            if let data, !data.isEmpty { total.append(data) }
            if error == nil, let packet = VideoPacket.parse(total) {
                self.decodeQueue.async { self.jitter.push(packet) }
                self.close(stream)
            } else if isComplete || error != nil {
                if error == nil { NSLog("QuicLinkReceiver: failed to parse packet bytes=\(total.count)") }
                self.close(stream)
            } else {
                self.receiveReply(on: stream, accumulated: total)
            }
        }
    }

    private func retainRequest(_ stream: NWConnection) {
        activeLock.lock()
        activeRequests.append(stream)
        activeLock.unlock()
    }

    private func close(_ stream: NWConnection) {
        activeLock.lock()
        activeRequests.removeAll { $0 === stream }
        activeLock.unlock()
        stream.cancel()
        netQueue.async {
            guard !self.stopped else { return }
            self.openRequestStream()
        }
    }

    // MARK: - Display timer (decodeQueue)

    private func startDisplayTimer() {
        let timer = DispatchSource.makeTimerSource(queue: decodeQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in self?.drainAndDecode() }
        displayTimer = timer
        timer.resume()
    }

    /// Pop every ready packet and decode it. Runs on decodeQueue only.
    private func drainAndDecode() {
        while let packet = jitter.pop() {
            decode(packet)
        }
    }

    private func decode(_ packet: VideoPacket) {
        if decoder == nil || packet.parameterSets != currentParameterSets {
            guard let fmt = CodecParameterSets.makeFormatDescription(codec: packet.codec,
                                                                     parameterSets: packet.parameterSets),
                  let newDecoder = VideoDecoder(formatDescription: fmt) else {
                NSLog("QuicLinkReceiver: failed to build decoder from parameter sets")
                return
            }
            decoder?.invalidate()
            newDecoder.onDecodedFrame = { [weak self] pixelBuffer, pts in
                self?.deliver(pixelBuffer: pixelBuffer, pts: pts)
            }
            decoder = newDecoder
            currentParameterSets = packet.parameterSets
        }
        let pts = CMTime(value: packet.ptsNanos, timescale: 1_000_000_000)
        decoder?.decode(packet.payload, pts: pts, isKeyframe: packet.isKeyframe)
    }

    private func deliver(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        guard let sampleBuffer = Self.makeSampleBuffer(pixelBuffer: pixelBuffer, pts: pts) else { return }
        delegate?.videoReceiverDidReceive(sampleBuffer: sampleBuffer,
                                          width: width, height: height,
                                          frameRateN: 30, frameRateD: 1,
                                          fourCC: kCMVideoCodecType_HEVC)
    }

    // MARK: - VideoReceiver

    func stop() {
        netQueue.async { self.stopped = true }
        activeLock.lock()
        let requests = activeRequests
        activeRequests.removeAll()
        activeLock.unlock()
        for request in requests { request.cancel() }
        decodeQueue.async {
            self.displayTimer?.cancel()
            self.displayTimer = nil
            self.decoder?.invalidate()
            self.decoder = nil
        }
    }

    // MARK: - CMSampleBuffer wrapping

    private static func makeSampleBuffer(pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription)
        guard fdStatus == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}
