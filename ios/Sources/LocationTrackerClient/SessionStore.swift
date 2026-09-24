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

    /// Runs when the session ends for any reason, so tracking stops and the queue is emptied.
    var onSignedOut: (() -> Void)?

    init() {
        expiryObserver = NotificationCenter.default.addObserver(
            forName: .sessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.endSession() }
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
            endSession()
        } catch {
            // Offline at launch: keep the session and keep tracking. Points queue up and the
            // token is refreshed once the server is reachable again.
            if let cached = Self.cachedProfile {
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
        endSession()
    }

    private func signedIn(_ profile: UserProfile) {
        Self.cachedProfile = profile
        state = .signedIn(profile)
    }

    private func endSession() {
        guard state != .signedOut else { return }
        TokenStore.clear()
        Self.cachedProfile = nil
        onSignedOut?()
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
