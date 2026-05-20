import SwiftUI

struct SenderView: View {
    @EnvironmentObject var controller: BroadcastController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Camera").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $controller.selectedCameraID) {
                    ForEach(controller.availableCameras, id: \.uniqueID) { dev in
                        Text(dev.localizedName).tag(dev.uniqueID)
                    }
                }
                .labelsHidden()
                .disabled(controller.availableCameras.isEmpty)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("NDI source name").font(.subheadline).foregroundStyle(.secondary)
                TextField("Mac Camera", text: $controller.sourceName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.isBroadcasting)
            }

            PreviewView(session: controller.cameraManager.session)
                .frame(width: 400, height: 225)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Quality").font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: $controller.quality) {
                        ForEach(QualityPreset.allCases) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                HStack {
                    Text("Frame rate").font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Picker("", selection: $controller.targetFPS) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    Spacer()
                }
                Toggle(isOn: $controller.smoothPacing) {
                    Text("Smooth pacing (+1 frame latency)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
            }

            RecordControlRow(recorder: controller.recorder, isEnabled: controller.isBroadcasting)

            Button(action: toggle) {
                Text(controller.isBroadcasting ? "Stop Broadcasting" : "Start Broadcasting")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(controller.isTransitioning || controller.availableCameras.isEmpty)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer()
            }
        }
        .padding(20)
        .onAppear { controller.refreshCameras() }
    }

    private func toggle() {
        if controller.isBroadcasting { controller.stop() } else { controller.start() }
    }

    private var statusColor: Color {
        switch controller.status {
        case .idle: return .gray
        case .live: return .green
        case .error: return .red
        }
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return "Idle"
        case .live(let w, let h, let fps):
            if w == 0 || h == 0 {
                return "Broadcasting as '\(controller.sourceName)' • starting…"
            }
            return "Broadcasting as '\(controller.sourceName)' • \(w)×\(h) @ \(fps) fps"
        case .error(let msg): return msg
        }
    }
}
