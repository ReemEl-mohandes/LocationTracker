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

    // Injected abstractions (DIP). Defaults are the production concretes, so existing callers
    // (`SessionStore()`) are unaffected; tests pass fakes.
    private let auth: AuthAPI
    private let tokens: TokenStoring

    init(auth: AuthAPI = APIClient.shared, tokens: TokenStoring = KeychainTokenStore()) {
        self.auth = auth
        self.tokens = tokens
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
        guard tokens.load() != nil else {
            // After a reboot, before the first unlock, the Keychain can't be read, so a missing
            // token proves nothing. Stay in `.restoring`; the app calls restoreIfPending() when
            // the phone is unlocked. Signing out here would strand the UI on the sign-in screen
            // even though the saved session is valid.
            if !tokens.isUnlockedSinceBoot { return }
            state = .signedOut
            return
        }
        do {
            let profile = try await auth.me()
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

    /// Retries restore() if it was deferred because the phone was still locked after a reboot.
    func restoreIfPending() async {
        guard state == .restoring else { return }
        await restore()
    }

    func login(email: String, password: String) async throws {
        let profile = try await auth.login(email: email, password: password)
        signedIn(profile)
    }

    func register(email: String, password: String, displayName: String) async throws {
        let profile = try await auth.register(email: email, password: password, displayName: displayName)
        signedIn(profile)
    }

    func logout() async {
        await auth.logout()
        endSession(explicit: true)
    }

    private func signedIn(_ profile: UserProfile) {
        Self.cachedProfile = profile
        onSignedIn?(profile)
        state = .signedIn(profile)
    }

    private func endSession(explicit: Bool) {
        guard state != .signedOut else { return }
        tokens.clear()
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
