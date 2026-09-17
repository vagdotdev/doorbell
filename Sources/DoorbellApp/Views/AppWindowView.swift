import AppKit
import SwiftUI

struct AppWindowView: View {
    @EnvironmentObject private var hallway: HallwayStore
    @EnvironmentObject private var model: AppWindowModel
    private var needsOnboarding: Bool {
        !model.introSeen || hallway.account != .ready || hallway.me.map { !model.completed.contains($0.id) } != false
    }
    var body: some View {
        Group {
            if needsOnboarding { onboarding }
            else { settings }
        }
        .background(Color.black)
        .tint(DesignTokens.utility)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("DOORBELL").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(3).foregroundStyle(.secondary)
                Spacer()
                Text(!model.introSeen ? "01 / 03" : hallway.account == .ready ? "03 / 03" : "02 / 03")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !model.introSeen {
                Text("Your friends, in the notch.").font(.system(size: 32, weight: .semibold))
                Text("Two kinds of people. You decide who is which.").font(.title3).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    KindCard(symbol: "person.2", title: "Friends",
                             detail: "Can call you. You see who it is and answer, or not.")
                    KindCard(symbol: "star.fill", title: "Close friends", tint: DesignTokens.openDoor,
                             detail: "Can walk straight into your room. No answering needed.")
                }
                .padding(.vertical, 8)
                HStack {
                    if !AppConfig.current.useSupabase { Text("Demo mode · sample friends, no network").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Get Started") { model.next() }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            } else if hallway.account != .ready {
                AccountView()
            } else if let me = hallway.me {
                Text("A face. A voice. You're in.").font(.system(size: 30, weight: .semibold))
                Text("Choose what Doorbell can use. Nothing starts recording here.").font(.title3).foregroundStyle(.secondary)
                PermissionsContent().padding(.vertical, 18)
                Text("You can change these anytime in Settings. Without access, your friends won't see or hear you.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text("@\(me.handle)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { model.complete(me.id) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }
            Spacer(minLength: 0)
            Text("No online status. Nothing is recorded.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 64).padding(.top, 52).padding(.bottom, 32)
    }

    private var settings: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Doorbell").font(.system(size: 23, weight: .semibold)).padding(.bottom, 30)
                ForEach(AppWindowModel.Page.allCases) { page in
                    Button { model.page = page } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.symbol).frame(width: 20)
                            Text(page.rawValue)
                            Spacer()
                            if page == .friends, !hallway.requests.isEmpty {
                                Text("\(hallway.requests.count)").font(.caption).foregroundStyle(DesignTokens.utility)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 9).fill(model.page == page ? Color.white.opacity(0.09) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(model.page == page ? .white : .gray)
                    .accessibilityAddTraits(model.page == page ? .isSelected : [])
                }
                Spacer()
                if let me = hallway.me {
                    AvatarView(profile: me, size: 34)
                    Text(me.displayName).font(.headline).lineLimit(1)
                    Text("@\(me.handle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !AppConfig.current.useSupabase {
                    Text("Demo mode").font(.caption).foregroundStyle(DesignTokens.utility).padding(.top, 8)
                }
            }
            .padding(.horizontal, 20).padding(.top, 56).padding(.bottom, 28)
            .frame(width: 190).background(Color.white.opacity(0.025))
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                if let problem = hallway.problem {
                    HStack {
                        Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Retry") { Task { await hallway.refresh() } }.disabled(hallway.isRefreshing || hallway.busy)
                        Button { hallway.problem = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss error")
                    }
                    .padding(14).background(Color.orange.opacity(0.13)).padding(.bottom, 18)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch model.page {
                        case .friends: FriendsPage()
                        case .audio: AudioSettingsPage()
                        case .window: WindowSettingsPage()
                        case .settings: AccountSettingsPage()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 28)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 32).padding(.top, 56)
        }
        .task {
            while !Task.isCancelled {
                if NSApp.windows.contains(where: { $0.identifier?.rawValue == "DoorbellAppWindow" && $0.isVisible }) {
                    await hallway.refresh()
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
}

/// One of the two kinds of people, said plainly.
private struct KindCard: View {
    let symbol: String
    let title: String
    var tint: Color = .white
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(tint)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.035)))
    }
}

struct PageHeading: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
