import SwiftUI

struct ReceiverView: View {
    @EnvironmentObject var model: ReceiverModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $model.selectedSourceName) {
                    if model.availableSources.isEmpty {
                        Text("No sources found").tag("")
                    } else {
                        if !model.availableSources.contains(where: { $0.name == model.selectedSourceName }) &&
                            !model.selectedSourceName.isEmpty {
                            Text("\(model.selectedSourceName) (offline)").tag(model.selectedSourceName)
                        }
                        ForEach(model.availableSources, id: \.name) { src in
                            Text(src.name).tag(src.name)
                        }
                    }
                }
                .labelsHidden()
                .disabled(model.isConnected)
                .frame(maxWidth: 320)

                Button(model.isConnected ? "Disconnect" : "Connect") {
                    if model.isConnected { model.disconnect() } else { model.connect() }
                }
                .disabled(!model.isConnected && (model.selectedSourceName.isEmpty || !model.availableSources.contains(where: { $0.name == model.selectedSourceName })))

                Text(model.statusLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                RecordControlRow(recorder: model.recorder, isEnabled: model.isConnected)
                    .frame(maxWidth: 200)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color(NSColor.windowBackgroundColor))

            DisplayLayerHostView(displayLayer: model.displayLayer)
                .background(Color.black)
        }
        .background(Color.black)
    }
}
