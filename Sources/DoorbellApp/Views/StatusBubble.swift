import SwiftUI

/// A speech bubble over a door, its tail pointing at the face below.
struct StatusBubble<Content: View>: View {
    var dim = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(dim ? DesignTokens.inkSecondary : DesignTokens.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 9)
            .padding(.top, 5)
            .padding(.bottom, 5 + BubbleShape.tail.height)
            .background(BubbleShape().fill(Color(white: dim ? 0.1 : 0.17)))
            .overlay(BubbleShape().stroke(dim ? DesignTokens.hairline : .white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}

/// One contour, so the hairline has no seam where the tail meets the body.
struct BubbleShape: Shape {
    static let tail = CGSize(width: 10, height: 5)
    var radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - Self.tail.height)
        let r = min(radius, body.height / 2, body.width / 2)
        let mid = body.midX, half = Self.tail.width / 2
        var path = Path()
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
        path.addLine(to: CGPoint(x: mid + half, y: body.maxY))
        path.addLine(to: CGPoint(x: mid, y: rect.maxY))
        path.addLine(to: CGPoint(x: mid - half, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: r)
        path.closeSubpath()
        return path
    }
}

private let bubbleWidth: CGFloat = 110

private func clears(_ status: DoorStatus) -> String {
    "Clears at \(status.expiresAt.formatted(date: .omitted, time: .shortened))"
}

/// A friend's line over their door. Read-only; nothing at all when they have none.
struct DoorStatusBubble: View {
    let status: DoorStatus?
    @Environment(\.splashOnScreen) private var splashOnScreen

    var body: some View {
        if let status, status.isShowing() {
            StatusBubble {
                Text(status.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: bubbleWidth)
            .opacity(splashOnScreen ? 0 : 1)
            .help("\(status.text) · \(clears(status))")
            .accessibilityLabel("Status: \(status.text)")
        }
    }
}

/// My own line: "Add status" until I write one; click to edit, × to take it down.
struct MyStatusBubble: View {
    @EnvironmentObject private var hallway: HallwayStore
    @EnvironmentObject private var state: NotchState
    @Environment(\.splashOnScreen) private var splashOnScreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var hovering = false
    @State private var cancelled = false
    @FocusState private var focused: Bool

    private var current: DoorStatus? {
        hallway.myStatus.flatMap { $0.isShowing() ? $0 : nil }
    }

    var body: some View {
        Group {
            if state.isTyping {
                editor
            } else if let status = current {
                shown(status)
            } else {
                add
            }
        }
        .frame(width: bubbleWidth)
        .onHover { hovering = $0 }
        .opacity(splashOnScreen ? 0 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: state.isTyping)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: current)
        .onChange(of: state.isTyping) { was, now in
            // Enter saves, Esc cancels, clicking away keeps what I wrote. Empty takes it down.
            guard was, !now, !cancelled else { return }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hallway.clearStatus() }
            else { hallway.setStatus(draft) }
        }
    }

    private var add: some View {
        Button { begin(with: "") } label: {
            StatusBubble(dim: !hovering) {
                Label("Add status", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
            }
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
        .help("A short line over your door for 6 hours")
    }

    private func shown(_ status: DoorStatus) -> some View {
        Button { begin(with: status.text) } label: {
            StatusBubble {
                Text(status.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { hallway.clearStatus() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(DesignTokens.ink)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color(white: 0.28)))
                        .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .transition(.scale.combined(with: .opacity))
                .help("Remove status")
                .accessibilityLabel("Remove status")
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
        .help("\(clears(status)) · click to edit")
        .accessibilityLabel("Your status: \(status.text)")
    }

    private var editor: some View {
        StatusBubble {
            TextField("What's up?", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { state.isTyping = false }
                .onExitCommand { cancelled = true; state.isTyping = false }
                .onChange(of: draft) { _, text in
                    if text.count > DoorStatus.maxLength { draft = String(text.prefix(DoorStatus.maxLength)) }
                }
        }
        .onAppear { focused = true }
        .onChange(of: focused) { was, now in if was, !now, state.isTyping { state.isTyping = false } }
    }

    private func begin(with text: String) {
        draft = text
        cancelled = false
        state.isTyping = true
    }
}
