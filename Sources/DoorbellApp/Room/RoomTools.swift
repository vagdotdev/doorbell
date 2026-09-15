import AVFoundation
import LiveKit
import SwiftUI

struct MediaStatus: View {
    @ObservedObject var media: MediaSession
    @ObservedObject var room: RoomSession
    private var text: String? {
        if let problem = room.problem ?? media.problem { return problem }
        switch media.phase {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .failed: return "Connection lost. Leave and knock again."
        default: return nil
        }
    }
    var body: some View {
        if let text {
            Text(text).font(.system(size: 12)).foregroundStyle(DesignTokens.inkSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 8)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

struct SharePicker: View {
    @ObservedObject var media: MediaSession
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [MediaSession.ShareSource] = []
    @State private var problem: String?
    @State private var loading = true
    @State private var starting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("What do you want to share?").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }.disabled(starting)
            }
            Text("Only the screen or window you choose.").font(.system(size: 12)).foregroundStyle(.secondary)
            if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 160) }
            else if let problem {
                Text(problem).font(.system(size: 13))
                Button("Open Screen Recording Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                Button("Try Again") { Task { await load() } }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(sources) { source in
                            Button {
                                starting = true
                                Task {
                                    await media.startScreenShare(source)
                                    starting = false
                                    if media.sharing { dismiss() } else { problem = media.problem ?? "Couldn’t start sharing." }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: source.isDisplay ? "display" : "macwindow").frame(width: 22)
                                    Text(source.title).lineLimit(2)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }.padding(12).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(starting || !media.isConnected)
                        }
                    }
                }.frame(height: 260)
            }
        }.padding(24).frame(width: 500).background(Color.black).preferredColorScheme(.dark)
            .task { await load() }
    }
    private func load() async {
        loading = true; problem = nil
        do {
            sources = try await media.shareSources()
            if sources.isEmpty { problem = "No shareable windows found. Open a window and try again." }
        } catch { problem = "Allow Screen Recording for Doorbell in macOS Settings, then try again." }
        loading = false
    }
}

struct DevicePicker: View {
    @ObservedObject var media: MediaSession
    @Environment(\.dismiss) private var dismiss
    @State private var inputs: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []
    @State private var cameras: [AVCaptureDevice] = []
    @State private var input = "system"
    @State private var output = "system"
    @State private var camera = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Devices").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            Picker("Microphone", selection: $input) {
                Text("System default").tag("system")
                ForEach(inputs.filter { !$0.isDefault }) { Text($0.name).tag($0.deviceId) }
            }.onChange(of: input) { _, id in
                if id == "system" { AudioManager.shared.inputDevice = AudioManager.shared.defaultInputDevice }
                else if let device = inputs.first(where: { $0.deviceId == id }) { AudioManager.shared.inputDevice = device }
            }
            Picker("Speakers", selection: $output) {
                Text("System default").tag("system")
                ForEach(outputs.filter { !$0.isDefault }) { Text($0.name).tag($0.deviceId) }
            }.onChange(of: output) { _, id in
                if id == "system" { AudioManager.shared.outputDevice = AudioManager.shared.defaultOutputDevice }
                else if let device = outputs.first(where: { $0.deviceId == id }) { AudioManager.shared.outputDevice = device }
            }
            Picker("Camera", selection: $camera) {
                Text("Current camera").tag("")
                ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }.disabled(!media.camOn || media.isUpdating)
                .onChange(of: camera) { _, id in
                    if let device = cameras.first(where: { $0.uniqueID == id }) { Task { await media.setCameraDevice(device) } }
                }
            if let problem = media.problem { Text(problem).font(.system(size: 12)).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 430).background(Color.black).preferredColorScheme(.dark)
            .task {
                inputs = AudioManager.shared.inputDevices; outputs = AudioManager.shared.outputDevices
                let currentInput = AudioManager.shared.inputDevice; let currentOutput = AudioManager.shared.outputDevice
                input = !currentInput.isDefault && inputs.contains(where: { $0.deviceId == currentInput.deviceId }) ? currentInput.deviceId : "system"
                output = !currentOutput.isDefault && outputs.contains(where: { $0.deviceId == currentOutput.deviceId }) ? currentOutput.deviceId : "system"
                cameras = (try? await CameraCapturer.captureDevices()) ?? []
            }
    }
}
