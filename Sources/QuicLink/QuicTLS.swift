import Network
import Security
import CryptoKit
import Foundation

final class QuicTLS {
    let identity: sec_identity_t
    let pinSHA256: Data          // SHA-256 of the leaf cert DER
    var pinHex: String { pinSHA256.map { String(format: "%02x", $0) }.joined() }

    private init(identity: sec_identity_t, pinSHA256: Data) {
        self.identity = identity
        self.pinSHA256 = pinSHA256
    }

    // MARK: - Load or create

    /// Loads the persisted self-signed identity, generating it once if absent.
    /// Path: ~/Library/Application Support/NDIStream/quiclink-identity.p12
    static func loadOrCreate() -> QuicTLS? {
        // 1. Determine the App Support path; create the NDIStream dir if needed.
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else {
            NSLog("QuicTLS: cannot resolve Application Support directory")
            return nil
        }
        let dir = appSupport.appendingPathComponent("NDIStream", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
        } catch {
            NSLog("QuicTLS: failed to create NDIStream directory: \(error)")
            return nil
        }

        let p12URL = dir.appendingPathComponent("quiclink-identity.p12")
        let p12Password = "ndistream-quiclink"

        // 2. If the .p12 does not exist, generate cert+key via /usr/bin/openssl
        //    (RSA-2048, self-signed, CN=NDIStream, -days 3650) and export to the .p12
        //    with a fixed passphrase. LibreSSL's default PBE is the legacy format
        //    that SecPKCS12Import accepts; no -legacy flag is needed (or recognized).
        if !FileManager.default.fileExists(atPath: p12URL.path) {
            NSLog("QuicTLS: no persisted identity found; generating…")
            guard generateP12(at: p12URL, password: p12Password) else {
                return nil
            }
        }

        // 3. Load the .p12 with SecPKCS12Import -> SecIdentity.
        let p12Data: Data
        do {
            p12Data = try Data(contentsOf: p12URL)
        } catch {
            NSLog("QuicTLS: failed to read .p12 at \(p12URL.path): \(error)")
            return nil
        }

        let importOptions = [kSecImportExportPassphrase as String: p12Password] as CFDictionary
        var items: CFArray?
        let importStatus = SecPKCS12Import(p12Data as CFData, importOptions, &items)
        guard importStatus == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let secIdentityAny = first[kSecImportItemIdentity as String] else {
            NSLog("QuicTLS: SecPKCS12Import failed: OSStatus \(importStatus)")
            return nil
        }
        let secIdentity = secIdentityAny as! SecIdentity // swiftlint:disable:this force_cast

        // 4. SecIdentityCopyCertificate -> SecCertificateCopyData -> SHA-256 = pin.
        var certRef: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(secIdentity, &certRef)
        guard certStatus == errSecSuccess, let cert = certRef else {
            NSLog("QuicTLS: SecIdentityCopyCertificate failed: OSStatus \(certStatus)")
            return nil
        }
        let certDER = SecCertificateCopyData(cert) as Data
        let pinSHA256 = Data(SHA256.hash(data: certDER))

        // 5. sec_identity_create(identity) -> sec_identity_t.
        guard let secIdentityT = sec_identity_create(secIdentity) else {
            NSLog("QuicTLS: sec_identity_create returned nil")
            return nil
        }

        NSLog("QuicTLS: identity loaded; pin=\(pinSHA256.map { String(format: "%02x", $0) }.joined())")
        return QuicTLS(identity: secIdentityT, pinSHA256: pinSHA256)
    }

    // MARK: - Server / client QUIC options

    /// Attach this identity to server QUIC options.
    func attachServer(to options: NWProtocolQUIC.Options) {
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
    }

    /// Build client QUIC options whose verify block pins the given cert DER SHA-256.
    /// Lifted verbatim from the spike: SecTrustCopyCertificateChain -> leaf ->
    /// SHA-256 of SecCertificateCopyData -> compare to expected -> complete(match).
    static func clientOptions(alpn: String, pinSHA256: Data) -> NWProtocolQUIC.Options {
        let quic = NWProtocolQUIC.Options(alpn: [alpn])
        let sec = quic.securityProtocolOptions

        sec_protocol_options_set_verify_block(sec, { _, sec_trust, complete in
            let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
            // PIN: compare the presented leaf cert DER hash to the expected pin.
            // Do NOT rely on SecTrustEvaluate chain-of-trust — it would reject a
            // self-signed leaf.
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            let presented = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
            complete(presented == pinSHA256)
        }, DispatchQueue(label: "quiclink.tls.verify"))

        return quic
    }

    // MARK: - Private helpers

    /// Generate a self-signed RSA-2048 cert+key, bundle to PKCS#12 and write to `url`.
    /// Returns true on success, false (with NSLog) on any failure.
    private static func generateP12(at url: URL, password: String) -> Bool {
        let fm = FileManager.default
        // Use a throw-away temp dir for the intermediate PEM files.
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(
            "quictls-gen-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true) }
        catch {
            NSLog("QuicTLS: failed to create temp dir: \(error)")
            return false
        }
        defer { try? fm.removeItem(at: tmpDir) }

        let keyPath  = tmpDir.appendingPathComponent("key.pem").path
        let certPath = tmpDir.appendingPathComponent("cert.pem").path

        // Step A: generate self-signed RSA-2048 cert, CN=NDIStream, valid 3650 days.
        guard runOpenSSL([
            "req", "-x509", "-nodes",
            "-newkey", "rsa:2048",
            "-keyout", keyPath,
            "-out",    certPath,
            "-days",   "3650",
            "-subj",   "/CN=NDIStream"
        ]) else { return false }

        // Step B: export cert+key to PKCS#12.
        // LibreSSL (the system openssl on macOS) emits the legacy PBE format that
        // SecPKCS12Import accepts. No -legacy flag needed or recognized here.
        guard runOpenSSL([
            "pkcs12", "-export",
            "-inkey",   keyPath,
            "-in",      certPath,
            "-out",     url.path,
            "-passout", "pass:\(password)"
        ]) else { return false }

        NSLog("QuicTLS: generated new identity at \(url.path)")
        return true
    }

    @discardableResult
    private static func runOpenSSL(_ args: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do { try proc.run() } catch {
            NSLog("QuicTLS: failed to launch openssl: \(error)")
            return false
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errOut = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            NSLog("QuicTLS: openssl \(args.first ?? "") exited \(proc.terminationStatus): \(errOut)")
            return false
        }
        return true
    }
}
