import Foundation

// Service boundaries (spec/services.md S3, S4) as narrow protocols the controllers depend on
// instead of concrete singletons. Dependency Inversion: high-level code (SessionStore,
// UploadQueue) depends on these abstractions, injected via constructors. Interface Segregation:
// the API is split so the session store sees only auth and the queue sees only uploads/trips —
// neither depends on a god interface.
//
// The concrete implementations are unchanged (`APIClient`, `TokenStore`); this only adds the
// seams, so behavior is identical and the app still builds. Fakes for these live in the (Mac-run)
// test plan in spec/services.md.

// MARK: - S3: backend API, segregated

protocol AuthAPI {
    func login(email: String, password: String) async throws -> UserProfile
    func register(email: String, password: String, displayName: String) async throws -> UserProfile
    func me() async throws -> UserProfile
    func logout() async
}

protocol LocationAPI {
    func uploadBatch(_ points: [LocationPoint]) async throws -> BatchIngestResponse
    func myTrip(id: Int64) async throws -> Trip
    func myTrips(pageSize: Int) async throws -> [Trip]
    func myActiveTrip() async throws -> Trip?
}

// APIClient already implements every method with these exact signatures.
extension APIClient: AuthAPI, LocationAPI {}

// MARK: - S4: secure token store

protocol TokenStoring {
    func load() -> SessionTokens?
    func save(_ tokens: SessionTokens)
    func clear()
    var isUnlockedSinceBoot: Bool { get }
}

/// The production store: forwards to the existing Keychain-backed `TokenStore` enum.
struct KeychainTokenStore: TokenStoring {
    func load() -> SessionTokens? { TokenStore.load() }
    func save(_ tokens: SessionTokens) { TokenStore.save(tokens) }
    func clear() { TokenStore.clear() }
    var isUnlockedSinceBoot: Bool { TokenStore.isUnlockedSinceBoot }
}
