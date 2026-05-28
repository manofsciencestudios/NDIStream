import Foundation
import Network

/// Discovers QuicLink sources over Bonjour. Browses `QuicLinkProtocol.bonjourServiceType`,
/// resolves each result's host/port, reads the TXT record (`src` = name, `pin` = cert hash
/// hex), and emits a `FoundSource` tagged `.quicLink` carrying the port + pin so the
/// receiver can connect and pin directly.
///
/// Not exercised by the loopback integration test (which connects directly via the sender's
/// test-visible port/pin); this just has to compile and behave reasonably for the app.
final class QuicLinkFinder: SourceFinder {

    var onSourcesChanged: (([FoundSource]) -> Void)?

    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "quiclink.finder")
    private let lock = NSLock()
    /// De-duped by source name.
    private var sourcesByName: [String: FoundSource] = [:]
    /// Per-result resolve connections, held while resolving. Guarded by `lock`.
    private var resolvers: [NWBrowser.Result: NWConnection] = [:]

    init() {
        let params = NWParameters()
        params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: QuicLinkProtocol.bonjourServiceType,
                                                       domain: nil),
                            using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let e) = state { NSLog("QuicLinkFinder: browser failed: \(e)") }
        }
        browser.start(queue: queue)
    }

    func currentSources() -> [FoundSource] {
        lock.lock(); defer { lock.unlock() }
        return Array(sourcesByName.values).sorted { $0.name < $1.name }
    }

    func stop() {
        browser.cancel()
        lock.lock()
        for (_, c) in resolvers { c.cancel() }
        resolvers.removeAll()
        sourcesByName.removeAll()
        lock.unlock()
    }

    // MARK: - Results

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        // Read the name + pin straight from the advertised TXT record; resolve the
        // endpoint's host/port via a transient connection (Bonjour endpoints carry the
        // service identity, not the IP, until resolved).
        for result in results {
            guard case let .service(name: serviceName, type: _, domain: _, interface: _) = result.endpoint
            else { continue }
            var sourceName = serviceName
            var pin: Data?
            if case let .bonjour(txt) = result.metadata {
                if let s = txt[QuicLinkProtocol.txtKeySourceName] { sourceName = s }
                if let hex = txt[QuicLinkProtocol.txtKeyPinSHA256Hex] { pin = Self.dataFromHex(hex) }
            }
            resolve(result: result, name: sourceName, pin: pin)
        }
        // Prune any names no longer advertised.
        let liveNames = Set(results.compactMap { r -> String? in
            if case let .service(name: n, type: _, domain: _, interface: _) = r.endpoint { return n }
            return nil
        })
        lock.lock()
        sourcesByName = sourcesByName.filter { liveNames.contains($0.value.name) || liveNames.contains($0.key) }
        lock.unlock()
    }

    private func resolve(result: NWBrowser.Result, name: String, pin: Data?) {
        lock.lock()
        let alreadyResolving = resolvers[result] != nil
        lock.unlock()
        guard !alreadyResolving else { return }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        lock.lock(); resolvers[result] = connection; lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let inner = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host: host, port: port) = inner {
                    self.emit(name: name, host: "\(host)", port: port.rawValue, pin: pin)
                }
                connection.cancel()
            case .failed, .cancelled:
                self.lock.lock(); self.resolvers[result] = nil; self.lock.unlock()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func emit(name: String, host: String, port: UInt16, pin: Data?) {
        let source = FoundSource(name: name, address: host, transport: .quicLink,
                                 port: port, pinSHA256: pin)
        lock.lock()
        sourcesByName[name] = source
        let snapshot = Array(sourcesByName.values).sorted { $0.name < $1.name }
        lock.unlock()
        onSourcesChanged?(snapshot)
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
