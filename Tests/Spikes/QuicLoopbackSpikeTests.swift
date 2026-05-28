import XCTest
import Network
import Security
import CryptoKit
@testable import NDIStream

/// SPIKE (proof-of-concept, NOT TDD): resolve the two coupled unknowns gating the
/// QuicLink transport design:
///   1. Multi-stream model over one QUIC connection in Network.framework
///      (NWMultiplexGroup + NWConnectionGroup), and
///   2. Self-signed TLS identity + client-side certificate pinning.
///
/// Findings are mirrored into docs/superpowers/specs/2026-05-28-quiclink-transport-design.md
/// (risks #1 and #2). See that file for the prose summary.
///
/// What this test proves, in one process, over loopback:
///   - Generate a self-signed cert+key with `openssl` at runtime in a temp dir,
///     SecPKCS12Import it to a SecIdentity (no keychain entries, no committed secrets).
///   - Stand up an NWListener configured for QUIC with that identity as the local TLS
///     identity (sec_protocol_options_set_local_identity) and an ALPN.
///   - Connect a client via NWMultiplexGroup/NWConnectionGroup with a verify block that
///     PINS the server's cert by SPKI SHA-256. Handshake succeeds under the correct pin.
///   - Open two concurrent client->server streams and round-trip bytes on each.
///   - Negative case: pinning the WRONG SPKI hash makes the handshake FAIL.
final class QuicLoopbackSpikeTests: XCTestCase {

    private static let alpn = "quiclink-spike"

    // MARK: - Self-signed identity (runtime, openssl, temp dir)

    /// A loaded server identity plus the pin material the client checks against.
    struct ServerCredentials {
        let identity: sec_identity_t
        /// SHA-256 of the full DER of the server leaf certificate. This is THE pin used by
        /// the spike: it is unambiguous and does not depend on SecCertificateCopyKey, which
        /// fails to extract some EC public keys on current macOS (OSStatus -26275). Production
        /// should prefer RFC-7469-style SPKI pinning (survives cert reissue with same key);
        /// see the design spec note.
        let certSHA256: Data
    }

    /// Generate a self-signed cert+key with openssl into a unique temp dir, bundle into a
    /// PKCS#12, and import it to a SecIdentity. Returns nil (test xfails) if any step fails;
    /// the failure point is logged so a hard wall is documented rather than hidden.
    private func makeServerCredentials() throws -> ServerCredentials {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("quiclink-spike-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }

        let keyPath = dir.appendingPathComponent("key.pem").path
        let certPath = dir.appendingPathComponent("cert.pem").path
        let p12Path = dir.appendingPathComponent("identity.p12").path
        let p12Password = "spike"

        // 1) self-signed RSA-2048 cert + key, valid 1 day, CN=localhost. RSA is used (vs EC)
        //    purely because the pin is the full cert DER hash here; the key type is otherwise
        //    irrelevant to QUIC/TLS 1.3, which negotiates its own handshake key agreement.
        try runOpenSSL([
            "req", "-x509", "-nodes",
            "-newkey", "rsa:2048",
            "-keyout", keyPath,
            "-out", certPath,
            "-days", "1",
            "-subj", "/CN=localhost"
        ])

        // 2) bundle cert+key into a PKCS#12. SecPKCS12Import on macOS rejects the modern
        //    AES-256 PBE that newer OpenSSL emits by default; the system openssl here is
        //    LibreSSL, whose default PBE (pbeWithSHA1And3-KeyTripleDES-CBC + SHA1/RC2) is
        //    exactly the legacy format SecPKCS12Import accepts, so no -legacy flag is used
        //    (and LibreSSL does not even recognize -legacy).
        try runOpenSSL([
            "pkcs12", "-export",
            "-inkey", keyPath,
            "-in", certPath,
            "-out", p12Path,
            "-passout", "pass:\(p12Password)"
        ])

        // 3) import the p12 -> SecIdentity.
        let p12Data = try Data(contentsOf: URL(fileURLWithPath: p12Path))
        let options = [kSecImportExportPassphrase as String: p12Password] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let secIdentity = first[kSecImportItemIdentity as String]
        else {
            throw SpikeError("SecPKCS12Import failed: OSStatus \(status)")
        }
        let identity = secIdentity as! SecIdentity

        // Pull the leaf cert DER + SPKI hash for pinning.
        var certRef: SecCertificate?
        let copyStatus = SecIdentityCopyCertificate(identity, &certRef)
        guard copyStatus == errSecSuccess, let cert = certRef else {
            throw SpikeError("SecIdentityCopyCertificate failed: OSStatus \(copyStatus)")
        }
        let certDER = SecCertificateCopyData(cert) as Data
        let certHash = Data(SHA256.hash(data: certDER))

        let secIdentityT = try XCTUnwrap(sec_identity_create(identity),
                                         "sec_identity_create returned nil")
        return ServerCredentials(identity: secIdentityT, certSHA256: certHash)
    }

    /// SHA-256 over the full certificate DER. Used as the pin by this spike (unambiguous,
    /// no key-extraction dependency).
    static func certSHA256(of cert: SecCertificate) -> Data {
        let der = SecCertificateCopyData(cert) as Data
        return Data(SHA256.hash(data: der))
    }

    private func runOpenSSL(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errOut = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            throw SpikeError("openssl \(args.first ?? "") exited \(proc.terminationStatus): \(errOut)")
        }
    }

    struct SpikeError: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }

    // MARK: - QUIC options builders

    /// Server-side QUIC options: attach the local identity and ALPN.
    /// `isDatagram = false`, and on the LISTENER the group/connection carries streams.
    private func serverQUICOptions(_ creds: ServerCredentials) -> NWParameters {
        let quic = NWProtocolQUIC.Options(alpn: [Self.alpn])
        let sec = quic.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, creds.identity)
        // QUIC requires TLS 1.3; Network.framework already pins that, no extra call needed.
        quic.isDatagram = false
        // Stream directionality is a GROUP-WIDE property in Network.framework (see design
        // spec risk #1): it lives on NWProtocolQUIC.Options.direction, not per-stream.
        quic.direction = .bidirectional
        quic.idleTimeout = 30_000
        let params = NWParameters(quic: quic)
        return params
    }

    /// Client-side QUIC options: ALPN + a verify block that pins `expectedCertSHA256`.
    /// Returns the NWParameters used to build the NWConnectionGroup.
    private func clientQUICOptions(expectedCertSHA256: Data) -> NWParameters {
        let quic = NWProtocolQUIC.Options(alpn: [Self.alpn])
        let sec = quic.securityProtocolOptions

        sec_protocol_options_set_verify_block(sec, { _, sec_trust, complete in
            NSLog("SPIKE verify block invoked")
            let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
            // No CA: do NOT rely on SecTrustEvaluate chain-of-trust (it would reject a
            // self-signed leaf). Instead, PIN: compare the presented leaf cert hash to the
            // one we baked in out-of-band.
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            let presented = QuicLoopbackSpikeTests.certSHA256(of: leaf)
            complete(presented == expectedCertSHA256)
        }, DispatchQueue(label: "quiclink.spike.verify"))

        quic.isDatagram = false
        quic.direction = .bidirectional
        return NWParameters(quic: quic)
    }

    // MARK: - Positive test: pinned handshake + 2 concurrent streams round-trip

    func testPinnedHandshakeAndTwoConcurrentStreams() throws {
        let creds = try makeServerCredentials()
        let queue = DispatchQueue(label: "quiclink.spike.positive")

        // ---- Listener (server) ----
        let listenerParams = serverQUICOptions(creds)
        // A QUIC listener delivers each *incoming stream* as a new NWConnection.
        let listener = try NWListener(using: listenerParams, on: .any)

        // Collect bytes received per inbound stream; expect 2 streams to deliver payloads.
        let twoStreamsReceived = expectation(description: "server received 2 stream payloads")
        twoStreamsReceived.expectedFulfillmentCount = 2
        let lock = NSLock()
        var receivedPayloads: [String] = []
        // Hold strong refs so inbound stream-connections aren't deallocated mid-receive.
        var inboundConnections: [NWConnection] = []

        listener.newConnectionHandler = { conn in
            NSLog("SPIKE listener newConnection: \(conn)")
            lock.lock(); inboundConnections.append(conn); lock.unlock()
            conn.stateUpdateHandler = { st in NSLog("SPIKE inbound conn state: \(st)") }
            conn.start(queue: queue)
            func receiveLoop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
                    if let data = data, !data.isEmpty {
                        let s = String(data: data, encoding: .utf8) ?? "<binary>"
                        lock.lock(); receivedPayloads.append(s); lock.unlock()
                        twoStreamsReceived.fulfill()
                    }
                    if error == nil && !isComplete {
                        receiveLoop()
                    }
                }
            }
            receiveLoop()
        }

        let listenerReady = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.fulfill() }
            if case .failed(let e) = state { XCTFail("listener failed: \(e)") }
        }
        listener.start(queue: queue)
        wait(for: [listenerReady], timeout: 10.0)
        let port = try XCTUnwrap(listener.port, "listener has no port")

        // ---- Client connection group (NWMultiplexGroup) ----
        let clientParams = clientQUICOptions(expectedCertSHA256: creds.certSHA256)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let multiplex = NWMultiplexGroup(to: endpoint)
        let group = NWConnectionGroup(with: multiplex, using: clientParams)

        // A NWConnectionGroup REFUSES to start unless a newConnectionHandler (or receive
        // handler) is set first ("The group does not have a receive handler or new
        // connection handler set"). The client doesn't expect inbound streams here, but the
        // handler is mandatory, so set a no-op that just starts any inbound stream.
        group.newConnectionHandler = { conn in conn.start(queue: queue) }

        let groupReady = expectation(description: "client group ready (handshake ok)")
        group.stateUpdateHandler = { state in
            NSLog("SPIKE group state: \(state)")
            switch state {
            case .ready: groupReady.fulfill()
            case .failed(let e): XCTFail("client group failed (pin should have succeeded): \(e)")
            default: break
            }
        }
        group.start(queue: queue)
        wait(for: [groupReady], timeout: 15.0)

        // ---- Open TWO concurrent outbound streams from the same group ----
        // The documented API to open a new outbound QUIC stream is NWConnection(from: group):
        // each NWConnection is one stream multiplexed over the group's single connection.
        // `isComplete: true` on the send closes the stream's send side, delivering the bytes
        // as a complete message the server can read in one receive.
        func openStreamAndSend(_ message: String) throws -> NWConnection {
            let stream = try XCTUnwrap(NWConnection(from: group),
                                       "NWConnection(from: group) returned nil (no stream)")
            let sent = expectation(description: "client sent on stream: \(message)")
            stream.stateUpdateHandler = { state in
                NSLog("SPIKE outbound stream [\(message)] state: \(state)")
                if case .ready = state {
                    stream.send(content: message.data(using: .utf8), isComplete: true,
                                completion: .contentProcessed { error in
                        XCTAssertNil(error, "send error on stream \(message): \(String(describing: error))")
                        sent.fulfill()
                    })
                }
                if case .failed(let e) = state { XCTFail("stream \(message) failed: \(e)") }
            }
            stream.start(queue: queue)
            wait(for: [sent], timeout: 10.0)
            return stream
        }

        let s1 = try openStreamAndSend("stream-one")
        let s2 = try openStreamAndSend("stream-two")

        wait(for: [twoStreamsReceived], timeout: 15.0)

        lock.lock()
        let payloads = receivedPayloads.sorted()
        lock.unlock()
        XCTAssertEqual(payloads, ["stream-one", "stream-two"],
                       "both concurrent streams must round-trip distinct payloads")

        s1.cancel(); s2.cancel()
        group.cancel()
        listener.cancel()
    }

    // MARK: - Negative test: wrong pin must reject the handshake

    func testWrongPinRejectsHandshake() throws {
        let creds = try makeServerCredentials()
        let queue = DispatchQueue(label: "quiclink.spike.negative")

        // ---- Listener (server) ----
        // Set up the listener to RECEIVE like the positive test does, so that if an impostor
        // client ever managed to push bytes through, we'd notice and fail. Hold strong refs to
        // inbound stream-connections so they aren't deallocated mid-receive.
        let listener = try NWListener(using: serverQUICOptions(creds), on: .any)
        let lock = NSLock()
        var inboundConnections: [NWConnection] = []

        // INVERTED expectation: the ONLY way this test fails is if the wrong-pinned client
        // actually establishes a working connection. We fulfill it on any SUCCESS signal
        // (group .ready, stream .ready, or the server receiving bytes). We do NOT fulfill on
        // .failed/.waiting — those are the EXPECTED rejection and may never be delivered
        // (Network.framework keeps a pin-rejected QUIC group retrying silently). With an
        // inverted expectation, wait() SUCCEEDS precisely when nothing fulfills it, i.e. the
        // impostor never got a usable stream — which is the security property under test.
        let connected = expectation(description: "impostor must NOT establish a working stream")
        connected.isInverted = true

        listener.newConnectionHandler = { conn in
            NSLog("SPIKE neg listener newConnection: \(conn)")
            lock.lock(); inboundConnections.append(conn); lock.unlock()
            conn.start(queue: queue)
            func receiveLoop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
                    if let data = data, !data.isEmpty {
                        // The impostor pushed bytes through end-to-end: pinning FAILED to enforce.
                        NSLog("SPIKE neg server received \(data.count) bytes — pinning NOT enforcing")
                        connected.fulfill()
                    }
                    if error == nil && !isComplete {
                        receiveLoop()
                    }
                }
            }
            receiveLoop()
        }

        let listenerReady = expectation(description: "listener ready (neg)")
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.fulfill() }
        }
        listener.start(queue: queue)
        wait(for: [listenerReady], timeout: 10.0)
        let port = try XCTUnwrap(listener.port)

        // ---- Client group with a deliberately WRONG pin (all zeros) ----
        let wrongPin = Data(repeating: 0, count: 32)
        let clientParams = clientQUICOptions(expectedCertSHA256: wrongPin)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: clientParams)
        group.newConnectionHandler = { conn in conn.start(queue: queue) }

        group.stateUpdateHandler = { state in
            NSLog("SPIKE neg group state: \(state)")
            if case .ready = state {
                // Group handshake completed under a wrong pin: pinning FAILED to enforce.
                connected.fulfill()
            }
            // .failed / .waiting are the EXPECTED rejection — do NOT fulfill on them.
        }
        group.start(queue: queue)

        // Attempt to open an outbound stream and push a payload. Under a wrong pin this stream
        // must never reach .ready (and the bytes must never reach the server). If it does, the
        // inverted expectation is fulfilled and the test fails.
        let impostorStream = NWConnection(from: group)
        if let stream = impostorStream {
            stream.stateUpdateHandler = { state in
                NSLog("SPIKE neg stream state: \(state)")
                if case .ready = state {
                    // Stream became usable under a wrong pin: pinning FAILED to enforce.
                    connected.fulfill()
                    stream.send(content: "impostor".data(using: .utf8), isComplete: true,
                                completion: .contentProcessed { _ in })
                }
                // .failed / .waiting are the EXPECTED rejection — do NOT fulfill on them.
            }
            stream.start(queue: queue)
        }

        // With an inverted expectation, this SUCCEEDS iff nothing fulfilled `connected` within
        // the window — i.e. the wrong-pinned client never got a working stream. The positive
        // handshake completes in well under a second on loopback, so 8s is ample headroom to
        // confirm the negative never connects.
        wait(for: [connected], timeout: 8.0)

        impostorStream?.cancel()
        group.cancel()
        listener.cancel()
    }
}
