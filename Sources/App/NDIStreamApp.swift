import SwiftUI

@main
struct NDIStreamApp: App {
    @StateObject private var senderController = BroadcastController()
    @StateObject private var receiverModel = ReceiverModel()

    var body: some Scene {
        Window("NDIStream — Sender", id: "sender") {
            SenderView()
                .environmentObject(senderController)
                .frame(width: 440, height: 700)
                .fixedSize()
        }
        .windowResizability(.contentSize)

        Window("NDIStream — Receiver", id: "receiver") {
            ReceiverView()
                .environmentObject(receiverModel)
                .frame(minWidth: 480, idealWidth: 800, minHeight: 320, idealHeight: 500)
        }
        .windowResizability(.contentMinSize)
    }
}
