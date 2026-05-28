import Foundation

enum QuicLinkProtocol {
    static let networkQueue = DispatchQueue(label: "quiclink.network")
    static let bonjourServiceType = "_ndistream-ql._udp"
    static let alpn = "ndistream-quiclink-v1"
    static let txtKeySourceName = "src"
    static let txtKeyPinSHA256Hex = "pin"
    /// Control-stream message kinds (first byte of a control message).
    enum ControlKind: UInt8 { case capabilities = 1, codecChoice = 2, heartbeat = 3, tally = 4 }
}
