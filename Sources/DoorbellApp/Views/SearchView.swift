import SwiftUI

/// Find a friend by handle and send a request.
struct SearchView: View {
    @EnvironmentObject private var hallway: HallwayStore
    @EnvironmentObject private var door: DoorController
    @State private var query = ""
    @State private var results: [Profile] = []
    @State private var searched = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SubHeader {
                HStack(spacing: 6) {
                    Text("@")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignTokens.inkTertiary)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignTokens.ink)
                        .focused($focused)
                        .onSubmit { runSearch() }
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(DesignTokens.raised))
            }

            Group {
                if results.isEmpty {
                    Spacer()
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.inkTertiary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(results) { person in
                                PersonRow(profile: person) { trailing(for: person) }
                                if person.id != results.last?.id {
                                    Divider().overlay(DesignTokens.hairline)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                runSearch()
            }
        }
    }

    private var hint: String {
        if hallway.account != .ready { return "Finish setup first" }
        if query.trimmingCharacters(in: .whitespaces).count < 2 { return "Type at least 2 characters" }
        return searched ? "No Results" : ""
    }

    @ViewBuilder
    private func trailing(for person: Profile) -> some View {
        if person.openDoorPolicy, let friend = hallway.doors.first(where: { $0.id == person.id }) {
            PillButton(title: "Walk In", prominent: true) {
                door.visit(friend)
            }
            .help("Their door is open to friends. Quiet Door or another call may pause entry.")
        } else {
        switch hallway.relationship(to: person) {
        case .none:
            if hallway.requests.contains(where: { $0.id == person.id }) {
                PillButton(title: "Accept", prominent: true) { hallway.accept(person) }
            } else {
                PillButton(title: "Add Friend", prominent: true) { hallway.request(person) }
            }
        case .requested:
            Text("Requested")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.inkTertiary)
        case .following:
            Text("Friends")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.inkSecondary)
        }
        }
    }

    private func runSearch() {
        let q = query
        Task {
            let found = await hallway.search(q)
            guard q == query else { return }
            results = found
            searched = true
        }
    }
}
