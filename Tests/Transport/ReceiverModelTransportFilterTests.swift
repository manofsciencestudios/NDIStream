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
}
