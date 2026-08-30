import SwiftUI

/// What a signed-in launch shows, until the study screen replaces it.
///
/// It exists to prove the whole chain end to end — keychain, token renewal,
/// `Session.run`, a real authenticated call — with one number on screen. The
/// study screen is built on exactly this and nothing more.
struct HomeView: View {
    @EnvironmentObject private var session: Session
    let name: String

    @State private var due: Int?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            count
            Spacer()
            actions
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Theme.bg)
        .tint(Theme.accent)
        .safeAreaInset(edge: .top) {
            Text("Signed in as \(name)")
                .font(.footnote)
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .task { await load() }
    }

    private var count: some View {
        VStack(spacing: 8) {
            if let due {
                Text("\(due)")
                    .font(.system(size: 76, weight: .light, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())
                Text(due == 1 ? "card due" : "cards due")
                    .font(.headline)
                    .foregroundStyle(Theme.textMuted)
            } else if failure == nil {
                ProgressView().frame(height: 90)
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
            }
        }
        .animation(Theme.normal, value: due)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SoftButtonStyle())

            Button("Sign out") { session.signOut() }
                .buttonStyle(SoftButtonStyle(tint: Theme.danger))
        }
        .padding(.bottom, 16)
    }

    private func load() async {
        failure = nil
        do {
            // Through `run`, not through `client` directly: that is what renews
            // a token which expired while the phone was in a pocket.
            due = try await session.run { try await $0.remainingDue() }
        } catch let error as APIError {
            failure = error.message
        } catch {
            failure = error.localizedDescription
        }
    }
}
