import CoreMedia
import CoreVideo
import Foundation
import Network

/// QuicLink video sender: a QUIC `NWListener` with a self-signed local identity,
/// advertised over Bonjour with the cert pin in its TXT record.
///
/// ## Stream model (proven in QuicServerStreamSpike)
/// Network.framework forbids a QUIC SERVER from opening streams to a client
/// (`NWConnection(from:)` on a listener-side group fails with "server, prohibit joining
/// protocols"). The only supported server->client data path is: the CLIENT opens a
/// bidirectional stream and the SERVER replies on that same stream. So QuicLink uses a
/// **client-pull / server-reply** model:
///   - The receiver keeps a pool of open "frame request" streams.
///   - Each inbound stream sends a 1-byte request; the sender holds it open and, when the
///     next encoded frame is ready, replies with the serialized `VideoPacket`
///     (`isComplete: true` = one frame = one complete message), then the stream closes.
///   - The receiver immediately opens a replacement stream, keeping the pipe full.
/// This preserves drop-don't-stall (each frame is its own stream) while staying entirely
/// within the proven API.
///
/// Scope (Plan 2c): video only, always HEVC, all-intra.
final class QuicLinkSender: VideoSender {

    // MARK: - Networking

    private let tls: QuicTLS
    private let sourceName: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "quiclink.sender")

    /// Inbound request streams awaiting the next frame. Each gets the next encoded packet.
    /// Guarded by `lock`.
    private let lock = NSLock()
    private var waitingStreams: [NWConnection] = []
    /// Most recent serialized packet. Served immediately to a request that arrives between
    /// frames; the receiver's JitterBuffer dedupes by pts, so re-serving the same frame to a
    /// fast poller is harmless. Guarded by `lock`.
    private var lastFrameData: Data?
    /// Most recent packet, used by `repeatLastFrame`. Guarded by `lock`.
    private var lastPacket: VideoPacket?

    // MARK: - Encoding

    private var encoder: VideoEncoder?

    // MARK: - Test-visible accessors (for @testable direct connect)

    /// The UDP port the QUIC listener bound to, once ready. nil until `.ready`.
    var listeningPort: UInt16? { listener.port?.rawValue }

    /// SHA-256 of the leaf cert DER — the pin a receiver must present in its verify block.
    var pinSHA256: Data { tls.pinSHA256 }

    // MARK: - Init

    init?(sourceName: String) {
        guard let tls = QuicTLS.loadOrCreate() else {
            NSLog("QuicLinkSender: QuicTLS.loadOrCreate() failed")
            return nil
        }
        self.tls = tls
        self.sourceName = sourceName

        let quic = NWProtocolQUIC.Options(alpn: [QuicLinkProtocol.alpn])
        quic.isDatagram = false
        quic.direction = .bidirectional
        quic.idleTimeout = 30_000
        tls.attachServer(to: quic)
        let params = NWParameters(quic: quic)

        do {
            listener = try NWListener(using: params, on: .any)
        } catch {
            NSLog("QuicLinkSender: NWListener init failed: \(error)")
            return nil
        }

        // Advertise over Bonjour: TXT carries src = source name, pin = cert hash hex.
        let txt = NWTXTRecord([
            QuicLinkProtocol.txtKeySourceName: sourceName,
            QuicLinkProtocol.txtKeyPinSHA256Hex: tls.pinHex
        ])
        if ProcessInfo.processInfo.environment["QUICLINK_NO_BONJOUR"] == nil {
            listener.service = NWListener.Service(name: sourceName,
                                                  type: QuicLinkProtocol.bonjourServiceType,
                                                  txtRecord: txt)
        }

        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                NSLog("QuicLinkSender: listener ready on port \(listener?.port?.rawValue ?? 0)")
            case .failed(let e):
                NSLog("QuicLinkSender: listener failed: \(e)")
            default:
                break
            }
        }

        // Each inbound QUIC stream from a receiver arrives as an NWConnection. We start it,
        // read its 1-byte frame request, then hold it until the next encoded frame.
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleInboundRequest(connection)
        }

        listener.start(queue: queue)
    }

    // MARK: - Inbound request handling

    private func handleInboundRequest(_ connection: NWConnection) {
        NSLog("QuicLinkSender: inbound request stream")
        connection.stateUpdateHandler = { [weak self] state in
            NSLog("QuicLinkSender: inbound stream state: \(state)")
            switch state {
            case .failed, .cancelled:
                self?.removeWaiting(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Read the (small) request. If a frame is already buffered, serve it immediately
        // (the receiver dedupes by pts, so a repeat is harmless and keeps latency low even
        // when the request arrived between encodes). Otherwise enqueue for the next frame.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16) { [weak self] _, _, _, _ in
            guard let self else { return }
            self.lock.lock()
            let buffered = self.lastFrameData
            if buffered == nil { self.waitingStreams.append(connection) }
            self.lock.unlock()
            if let buffered { self.reply(on: connection, data: buffered) }
        }
    }

    /// Send one serialized packet on a request stream and close its send side.
    private func reply(on connection: NWConnection, data: Data) {
        connection.send(content: data, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            self?.removeWaiting(connection)
            connection.cancel()
        })
    }

    private func removeWaiting(_ connection: NWConnection) {
        lock.lock()
        waitingStreams.removeAll { $0 === connection }
        lock.unlock()
    }

    // MARK: - VideoSender

    func send(pixelBuffer: CVPixelBuffer, frameRateN: Int32, frameRateD: Int32) {
        if encoder == nil {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let fps = frameRateD > 0 ? max(1, Int(frameRateN / frameRateD)) : 30
            guard let enc = VideoEncoder(width: width, height: height, codec: .hevc,
                                         fps: fps, bitrate: 8_000_000) else {
                NSLog("QuicLinkSender: VideoEncoder init failed")
                return
            }
            enc.onEncodedFrame = { [weak self] frame in
                guard let self else { return }
                guard let sets = CodecParameterSets.extract(from: frame.formatDescription,
                                                            codec: .hevc) else {
                    NSLog("QuicLinkSender: parameter-set extraction failed")
                    return
                }
                let ptsNanos = Int64(CMTimeGetSeconds(frame.pts) * 1_000_000_000)
                let packet = VideoPacket(codec: .hevc,
                                         isKeyframe: frame.isKeyframe,
                                         ptsNanos: ptsNanos,
                                         width: UInt16(width),
                                         height: UInt16(height),
                                         parameterSets: sets,
                                         payload: frame.data)
                self.publish(packet)
            }
            encoder = enc
        }

        // Monotonic host-clock pts so the receiver's jitter buffer can order frames.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        encoder?.encode(pixelBuffer, pts: pts)
    }

    /// Buffer the newest frame and fan it out to every stream currently awaiting one.
    private func publish(_ packet: VideoPacket) {
        let data = packet.serialize()
        lock.lock()
        lastPacket = packet
        lastFrameData = data
        let toServe = waitingStreams
        waitingStreams.removeAll()
        lock.unlock()
        for stream in toServe { reply(on: stream, data: data) }
    }

    func repeatLastFrame(frameRateN: Int32, frameRateD: Int32) {
        // Re-publish the last packet to any waiting receivers (keeps a stalled picture
        // fresh). No-op until something has been encoded.
        lock.lock(); let packet = lastPacket; lock.unlock()
        if let packet { publish(packet) }
    }

    func sendAudio(_ sampleBuffer: CMSampleBuffer) {
        // No-op for now: audio over QuicLink lands in Plan 2d.
    }

    func stop() {
        lock.lock()
        let streams = waitingStreams
        waitingStreams.removeAll()
        lock.unlock()
        for s in streams { s.cancel() }
        listener.cancel()
        encoder?.invalidate()
        encoder = nil
    }
}
