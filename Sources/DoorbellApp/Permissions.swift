import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class PermissionStore: ObservableObject {
    @Published private(set) var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var requesting = false
    func refresh() {
        camera = AVCaptureDevice.authorizationStatus(for: .video)
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    func request(_ type: AVMediaType) {
        guard !requesting else { return }
        NSApp.activate(ignoringOtherApps: true)
        requesting = true
        Task {
            _ = await AVCaptureDevice.requestAccess(for: type)
            refresh()
            requesting = false
        }
    }
    static func openSettings(_ type: AVMediaType) {
        let pane = type == .video ? "Privacy_Camera" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionsContent: View {
    @StateObject private var permissions = PermissionStore()
    var body: some View {
        VStack(spacing: 0) {
            permissionRow("Camera", detail: "Friends see you on a call.", symbol: "video", type: .video, status: permissions.camera)
            Divider().padding(.vertical, 18)
            permissionRow("Microphone", detail: "Friends hear you on a call.", symbol: "mic", type: .audio, status: permissions.microphone)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
    }
    private func permissionRow(_ title: String, detail: String, symbol: String, type: AVMediaType, status: AVAuthorizationStatus) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 21)).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if status == .denied { Text("Access is off. Enable it in System Settings.").font(.caption).foregroundStyle(.orange) }
                if status == .restricted { Text("Access is restricted by this Mac's administrator.").font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            switch status {
            case .authorized: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(DesignTokens.utility)
            case .notDetermined: Button("Allow") { permissions.request(type) }.disabled(permissions.requesting)
            case .denied: Button("Open Settings") { PermissionStore.openSettings(type) }
            case .restricted: Text("Restricted").foregroundStyle(.secondary)
            @unknown default: Text("Unavailable").foregroundStyle(.secondary)
            }
        }
    }
}
