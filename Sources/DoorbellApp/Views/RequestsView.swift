import SwiftUI

/// Accept once so both friends can knock on each other's door.
struct RequestsView: View {
    @EnvironmentObject private var hallway: HallwayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SubHeader("Requests")
            if hallway.requests.isEmpty {
                Spacer()
                Text("No Requests")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.inkTertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(hallway.requests) { person in
                            PersonRow(profile: person) {
                                PillButton(title: "Decline") { hallway.ignore(person) }
                                PillButton(title: "Accept", prominent: true) { hallway.accept(person) }
                            }
                            if person.id != hallway.requests.last?.id {
                                Divider().overlay(DesignTokens.hairline)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }
}
