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
}
