import SwiftUI

/// Everyone you know on Doorbell, in three sections. A green star marks a close
/// friend — someone who can walk straight into your room — and puts them first.
struct FriendsPage: View {
    @EnvironmentObject private var hallway: HallwayStore

    private enum Section: String, CaseIterable, Identifiable {
        case friends = "Friends", requests = "Requests", followers = "Followers"
        var id: String { rawValue }
    }
    private enum Field { case filter, find }

    @State private var section: Section = .friends
    @State private var filtering = false
    @State private var adding = false
    @State private var query = ""
    @State private var found: [Profile] = []
    @State private var searched = false
    @State private var searchTask: Task<Void, Never>?
    @State private var removing: Profile?
    @FocusState private var focus: Field?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            PageHeading(title: "Friends")
            Spacer()
            HeaderButton(symbol: "magnifyingglass", active: filtering, label: "Search friends") {
                filtering.toggle(); adding = false; query = ""
                focus = filtering ? .filter : nil
            }
            HeaderButton(symbol: "plus", active: adding, label: "Add a friend") {
                adding.toggle(); filtering = false; query = ""; found = []; searched = false
                focus = adding ? .find : nil
            }
        }
        .alert("Remove @\(removing?.handle ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { hallway.removeFollower(removing) }; removing = nil }
        } message: { Text("They'll need to send a new request to reach you again. A call already in progress isn't ended.") }

        if adding {
            field("Find people by @handle", focus: .find)
            if found.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).count < 2 ? "Type a handle to find someone."
                     : searched ? "No one by that handle." : " ")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                list(found) { person in trailing(for: person) }
            }
        } else {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { s in
                    Text(s == .requests && !hallway.requests.isEmpty ? "Requests · \(hallway.requests.count)" : s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented).labelsHidden()

            if filtering { field("Search by name or @handle", focus: .filter) }

            switch section {
            case .friends: friendsSection
            case .requests: requestsSection
            case .followers: followersSection
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var friendsSection: some View {
        let shown = friends.filter(matches)
        if shown.isEmpty {
            empty(friends.isEmpty ? "No friends yet." : "No one matches.",
                  friends.isEmpty ? "Add someone by their @handle. Once you follow each other, either of you can call." : nil)
        } else {
            list(shown.map(\.profile)) { profile in
                if let door = shown.first(where: { $0.id == profile.id }) { star(for: door) }
            } menu: { profile in
                if hallway.doors.contains(where: { $0.id == profile.id }) {
                    Button("Unfollow @\(profile.handle)", role: .destructive) { hallway.unfollow(profile) }
                }
                if hallway.followers.contains(where: { $0.id == profile.id }) {
                    Button("Remove follower", role: .destructive) { removing = profile }
                }
            }
        }
    }

    @ViewBuilder private var requestsSection: some View {
        let shown = hallway.requests.filter(matches)
        if shown.isEmpty {
            empty("No requests.", "When someone asks to follow you, they'll appear here.")
        } else {
            list(shown) { person in
                Button("Decline") { hallway.ignore(person) }
                Button("Accept") { hallway.accept(person) }.buttonStyle(.borderedProminent)
            }
            .disabled(hallway.busy || hallway.isRefreshing)
        }
    }

    @ViewBuilder private var followersSection: some View {
        let shown = hallway.followers.filter { matches($0.profile) }
        if shown.isEmpty {
            empty("No followers yet.", "People who follow you can call you. Removing someone stops that.")
        } else {
            list(shown.map(\.profile)) { person in
                Button("Remove", role: .destructive) { removing = person }.disabled(hallway.busy)
            }
        }
    }

    // MARK: Data

    /// People you follow and people who follow you, once each. Close friends first.
    private var friends: [Door] {
        var byID: [String: Door] = [:]
        for door in hallway.doors { byID[door.id] = door }
        for follower in hallway.followers where byID[follower.id] == nil { byID[follower.id] = follower }
        return byID.values.sorted { a, b in
            if a.isCloseFriend != b.isCloseFriend { return a.isCloseFriend }
            return a.profile.displayName.localizedCaseInsensitiveCompare(b.profile.displayName) == .orderedAscending
        }
    }

    private func matches(_ door: Door) -> Bool { matches(door.profile) }
    private func matches(_ profile: Profile) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
        guard filtering, !q.isEmpty else { return true }
        return profile.displayName.lowercased().contains(q) || profile.handle.contains(q)
    }

    private func findPeople() {
        let q = query
        Task {
            let results = await hallway.search(q)
            guard q == query else { return }
            found = results
            searched = true
        }
    }

    // MARK: Pieces

    private func star(for door: Door) -> some View {
        Button { hallway.setCloseFriend(door.profile, !door.isCloseFriend) } label: {
            Image(systemName: door.isCloseFriend ? "star.fill" : "star")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(door.isCloseFriend ? DesignTokens.openDoor : Color.secondary.opacity(door.followsMe ? 1 : 0.4))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!door.followsMe || hallway.busy || hallway.isRefreshing)
        .help(door.followsMe
              ? (door.isCloseFriend ? "Close friend: walks straight into your room" : "Make a close friend")
              : "Available once they follow you back")
        .accessibilityLabel(door.isCloseFriend ? "Close friend" : "Make close friend")
    }

    @ViewBuilder
    private func trailing(for person: Profile) -> some View {
        switch hallway.relationship(to: person) {
        case .none: Button("Follow") { hallway.request(person) }.buttonStyle(.borderedProminent).disabled(hallway.busy)
        case .requested: Text("Requested").font(.callout).foregroundStyle(.secondary)
        case .following: Text("Following").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func field(_ placeholder: String, focus which: Field) -> some View {
        TextField(placeholder, text: $query)
            .textFieldStyle(.roundedBorder).controlSize(.large)
            .focused($focus, equals: which)
            .onSubmit { if adding { findPeople() } }
            .onChange(of: query) { _, _ in
                guard adding else { return }
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    findPeople()
                }
            }
    }

    private func list<Controls: View>(_ people: [Profile], @ViewBuilder controls: @escaping (Profile) -> Controls) -> some View {
        list(people, controls: controls) { _ in EmptyView() }
    }

    private func list<Controls: View, Menu: View>(_ people: [Profile],
                                                   @ViewBuilder controls: @escaping (Profile) -> Controls,
                                                   @ViewBuilder menu: @escaping (Profile) -> Menu) -> some View {
        VStack(spacing: 0) {
            ForEach(people) { profile in
                HStack(spacing: 12) {
                    AvatarView(profile: profile, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text("@\(profile.handle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    controls(profile)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .contextMenu { menu(profile) }
                if profile.id != people.last?.id { Divider() }
            }
        }
    }

    private func empty(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 12)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let active: Bool
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? .black : (hovering ? .white : .secondary))
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? DesignTokens.utility : Color.white.opacity(hovering ? 0.10 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}
