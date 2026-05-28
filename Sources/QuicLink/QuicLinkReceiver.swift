import CoreMedia
import CoreVideo
import Foundation
import Network
import VideoToolbox

/// QuicLink video receiver: a QUIC client that pins the sender's cert.
///
/// ## Stream model (proven in QuicServerStreamSpike)
/// Network.framework only allows the CLIENT to open QUIC streams; the server replies on
/// the same stream. So the receiver runs a **request/reply pull pool**: it keeps a small
/// pool of open streams, each of which sends a 1-byte request and then reads one complete
/// `VideoPacket` reply (the next encoded frame). When a stream completes, the receiver
/// immediately opens a replacement, keeping the pipe full so the sender always has a
/// waiting stream to deliver the next frame on. Each frame on its own stream preserves
/// drop-don't-stall.
///
/// Parsed packets feed a `JitterBuffer`; a display timer pops ready packets and decodes
/// them off the network thread. Decoded pixel buffers are wrapped in `CMSampleBuffer`s and
/// handed to the delegate. The decoder is (re)built from each packet's parameter sets.
final class QuicLinkReceiver: VideoReceiver {

    weak var delegate: VideoReceiverDelegate?

    /// How many frame-request streams to keep outstanding. A small pool absorbs RTT so the
    /// sender (almost) always has a waiting stream when it encodes the next frame.
    private static let poolSize = 4

    // MARK: - Networking

    private let group: NWConnectionGroup
    private let netQueue = DispatchQueue(label: "quiclink.receiver.net")
    /// Single serial queue that owns the jitter buffer + decoder (both single-threaded).
    private let decodeQueue = DispatchQueue(label: "quiclink.receiver.decode")
    private var groupReady = false
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
        let endpoint = NWEndpoint.hostPort(host: nwHost, port: nwPort)
        let params = NWParameters(quic: quic)
        // NOTE: do NOT set `params.requiredInterfaceType = .loopback`. The proven spike
        // (QuicLoopbackSpikeTests) reaches `.ready` reliably with no interface constraint;
        // forcing the loopback interface type made the group park in `waiting(Network is
        // down)` and reach `.ready` only intermittently.
        group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: params)

        // Mandatory handler; we don't expect server-initiated streams, but the group
        // refuses to start without it.
        group.newConnectionHandler = { conn in conn.start(queue: self.netQueue) }

        group.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            NSLog("QuicLinkReceiver: group state: \(state)")
            switch state {
            case .ready:
                NSLog("QuicLinkReceiver: group ready")
                self.onGroupReady()
            case .failed(let e):
                NSLog("QuicLinkReceiver: group failed: \(e)")
                self.delegate?.videoReceiverDidDisconnect()
            case .cancelled:
                self.delegate?.videoReceiverDidDisconnect()
            default:
                break
            }
        }

        group.start(queue: netQueue)
        startDisplayTimer()
    }

    // MARK: - Request/reply pull pool

    private func onGroupReady() {
        netQueue.async {
            guard !self.groupReady, !self.stopped else { return }
            self.groupReady = true
            for _ in 0..<Self.poolSize { self.openRequestStream() }
        }
    }

    /// Open one frame-request stream: send a 1-byte request, read the full reply (one
    /// complete `VideoPacket`), push it to the jitter buffer, then open a replacement.
    private func openRequestStream() {
        if stopped { return }
        guard let stream = NWConnection(from: group) else {
            NSLog("QuicLinkReceiver: NWConnection(from: group) returned nil")
            return
        }
        stream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Request the next frame; keep our send side OPEN (isComplete: false) so the
                // bidirectional stream stays open for the server's reply.
                stream.send(content: Data([0x01]), isComplete: false,
                            completion: .contentProcessed { _ in })
                self.receiveReply(on: stream, accumulated: Data())
            case .failed:
                stream.cancel()
                self.reopenAfterClose()
            default:
                break
            }
        }
        stream.start(queue: netQueue)
    }

    /// Accumulate the full reply message until `isComplete`, then parse + enqueue.
    private func receiveReply(on stream: NWConnection, accumulated: Data) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var total = accumulated
            if let data, !data.isEmpty { total.append(data) }
            if isComplete || error != nil {
                if error == nil, let packet = VideoPacket.parse(total) {
                    self.decodeQueue.async { self.jitter.push(packet) }
                }
                stream.cancel()
                self.reopenAfterClose()
            } else {
                self.receiveReply(on: stream, accumulated: total)
            }
        }
    }

    /// Keep the pool full: replace a stream that just finished.
    private func reopenAfterClose() {
        netQueue.async {
            guard self.groupReady, !self.stopped else { return }
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
        group.cancel()
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
