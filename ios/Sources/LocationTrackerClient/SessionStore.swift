import Foundation

@MainActor
final class SessionStore: ObservableObject {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(UserProfile)
    }

    @Published private(set) var state: State = .restoring

    private static let profileKey = "cachedProfile"
    private var expiryObserver: NSObjectProtocol?

    /// Runs when the session ends. `explicit` is true for a sign-out the user chose, false when
    /// the server ended the session; only the first should discard the offline backlog.
    var onSignedOut: ((_ explicit: Bool) -> Void)?

    /// Runs whenever a user is signed in, including on restore at launch.
    var onSignedIn: ((UserProfile) -> Void)?

    init() {
        expiryObserver = NotificationCenter.default.addObserver(
            forName: .sessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.endSession(explicit: false) }
        }
    }

    var profile: UserProfile? {
        if case .signedIn(let profile) = state { return profile }
        return nil
    }

    func restore() async {
        guard TokenStore.load() != nil else {
            state = .signedOut
            return
        }
        do {
            let profile = try await APIClient.shared.me()
            signedIn(profile)
        } catch APIError.unauthorized {
            endSession(explicit: false)
        } catch {
            // Offline at launch: keep the session and keep tracking. Points queue up and the
            // token is refreshed once the server is reachable again.
            if let cached = Self.cachedProfile {
                onSignedIn?(cached)
                state = .signedIn(cached)
            } else {
                state = .signedOut
            }
        }
    }

    func login(email: String, password: String) async throws {
        let profile = try await APIClient.shared.login(email: email, password: password)
        signedIn(profile)
    }

    func register(email: String, password: String, displayName: String) async throws {
        let profile = try await APIClient.shared.register(email: email, password: password, displayName: displayName)
        signedIn(profile)
    }

    func logout() async {
        await APIClient.shared.logout()
        endSession(explicit: true)
    }

    private func signedIn(_ profile: UserProfile) {
        Self.cachedProfile = profile
        onSignedIn?(profile)
        state = .signedIn(profile)
    }

    private func endSession(explicit: Bool) {
        guard state != .signedOut else { return }
        TokenStore.clear()
        Self.cachedProfile = nil
        onSignedOut?(explicit)
        state = .signedOut
    }

    private static var cachedProfile: UserProfile? {
        get {
            UserDefaults.standard.data(forKey: profileKey).flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: profileKey)
        }
    }
}
