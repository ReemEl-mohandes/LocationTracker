import Foundation
import Network
import UIKit

/// Points waiting to be sent, persisted to disk so a dead zone, a server outage or the app
/// being killed does not lose them. They are sent oldest first, in batches, and removed only
/// once the server has acknowledged them.
@MainActor
final class UploadQueue: ObservableObject {
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var lastUploadSummary: String?
    @Published private(set) var lastError: String?
    /// Persisted so a trip that ends after a relaunch is still noticed as ending.
    @Published private(set) var activeTripId: Int64? {
        didSet { UserDefaults.standard.set(activeTripId.map(String.init), forKey: Self.activeTripKey) }
    }

    private var pending: [LocationPoint] = []
    private var isFlushing = false
    private var notBefore: Date?

    /// False while the saved backlog exists but cannot be read (the phone has not been
    /// unlocked since it restarted). Nothing is written then: saving the in-memory list would
    /// overwrite the backlog.
    private var diskLoaded = true

    // Injected abstractions (DIP). Defaults are the production concretes.
    private let api: LocationAPI
    private let tokens: TokenStoring

    private static let ownerKey = "queueOwner"
    private static let activeTripKey = "lastActiveTripId"
    private let pathMonitor = NWPathMonitor()
    private var wasOnline = true
    private var offlineSince: Date?
    private var offlineNotified = false

    /// No "offline" notice for dropouts shorter than this (a lift, a tunnel).
    private static let offlineNoticeDelay: TimeInterval = 60

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-locations.json")
    }()

    init(api: LocationAPI = APIClient.shared, tokens: TokenStoring = KeychainTokenStore()) {
        self.api = api
        self.tokens = tokens
        if let saved = loadFromDisk() {
            pending = saved
        } else {
            diskLoaded = false
        }
        pendingCount = pending.count
        activeTripId = UserDefaults.standard.string(forKey: Self.activeTripKey).flatMap { Int64($0) }

        // Upload the backlog the moment Wi-Fi or mobile data comes back, instead of waiting
        // for the next scheduled attempt.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let cameBack = online && !self.wasOnline
                let wentAway = !online && self.wasOnline
                self.wasOnline = online
                if wentAway {
                    self.scheduleOfflineNotice()
                }
                if cameBack {
                    self.offlineSince = nil
                    self.notBefore = nil
                    let before = self.pending.count
                    await self.flush()
                    if self.offlineNotified {
                        self.offlineNotified = false
                        Notifier.backOnline(uploaded: max(0, before - self.pending.count))
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "upload-queue.path"))
    }

    private func scheduleOfflineNotice() {
        let since = Date()
        offlineSince = since
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.offlineNoticeDelay))
            guard let self, self.offlineSince == since, !self.wasOnline,
                  self.tokens.load() != nil else { return }
            self.offlineNotified = true
            Notifier.offline(pending: self.pending.count)
        }
    }

    /// A trip the server reported as open is no longer open: it has ended. Fetch the final,
    /// smoothed figures for the summary. A 404 means the server discarded it as noise.
    private func tripEnded(_ id: Int64) {
        Task {
            if let trip = try? await api.myTrip(id: id), !trip.isActive {
                Notifier.tripRecorded(trip)
            }
        }
    }

    /// nil when the file exists but is still locked; an empty list when there is no file.
    private func loadFromDisk() -> [LocationPoint]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? JSON.decoder.decode([LocationPoint].self, from: data)) ?? []
    }

    /// Called when the phone is unlocked. Points recorded before the first unlock after a
    /// restart were held in memory; they are merged with the saved backlog, then uploaded.
    func reloadAfterUnlock() async {
        if !diskLoaded, let saved = loadFromDisk() {
            let merged = (saved + pending).sorted { $0.recordedAtUtc < $1.recordedAtUtc }
            var unique: [LocationPoint] = []
            for point in merged where unique.last != point { unique.append(point) }
            pending = unique
            diskLoaded = true
            activeTripId = UserDefaults.standard.string(forKey: Self.activeTripKey).flatMap { Int64($0) }
            persist()
        }
        await flush()
    }

    /// Ties the backlog to the signed-in user. Points queued under someone else are dropped:
    /// one user's history must never be uploaded under another's session.
    func claim(for userId: UUID) {
        let owner = UserDefaults.standard.string(forKey: Self.ownerKey).flatMap(UUID.init(uuidString:))
        if let owner, owner != userId {
            clear()
        }
        UserDefaults.standard.set(userId.uuidString, forKey: Self.ownerKey)
    }

    func enqueue(_ point: LocationPoint) {
        pending.append(point)
        if pending.count > AppConfig.maxQueuedPoints {
            pending.removeFirst(pending.count - AppConfig.maxQueuedPoints)
        }
        persist()
    }

    /// Discards everything queued, for sign-out: one user's backlog must never be uploaded
    /// under the next user's session.
    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.ownerKey)
        pending.removeAll()
        activeTripId = nil
        lastUploadAt = nil
        lastUploadSummary = nil
        lastError = nil
        persist()
    }

    func flush() async {
        guard !isFlushing, !pending.isEmpty, tokens.load() != nil else { return }
        if let notBefore, notBefore > Date() { return }

        isFlushing = true
        // In the background iOS may suspend the app mid-request; asking for a little extra
        // time lets the batch in flight finish and be removed from the queue.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "upload-locations")
        defer {
            isFlushing = false
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }

        while !pending.isEmpty {
            // Points only ever get appended while a batch is in flight, so the prefix sent is
            // still the prefix when the response arrives.
            let batch = Array(pending.prefix(AppConfig.maxBatchSize))

            do {
                let result = try await api.uploadBatch(batch)
                dropSent(batch.count)
                if let previous = activeTripId, previous != result.activeTripId {
                    tripEnded(previous)
                }
                activeTripId = result.activeTripId
                lastUploadAt = Date()
                lastUploadSummary = result.rejected == 0
                    ? "\(result.accepted) sent"
                    : "\(result.accepted) sent, \(result.rejected) rejected by server"
                lastError = nil
                notBefore = nil
            } catch APIError.rateLimited(let retryAfter) {
                notBefore = Date().addingTimeInterval(retryAfter ?? 30)
                lastError = "Server is busy; retrying shortly."
                return
            } catch APIError.server(let status, let message) where (400..<500).contains(status) {
                // The server will reject this batch no matter how often it is resent; keeping
                // it would block every point queued behind it.
                dropSent(batch.count)
                lastError = "Server rejected \(batch.count) points: \(message ?? "HTTP \(status)")"
            } catch {
                // Offline, timed out, 5xx or signed out: keep the points and try again later.
                lastError = error.localizedDescription
                return
            }
        }
    }

    private func dropSent(_ count: Int) {
        pending.removeFirst(min(count, pending.count))
        persist()
    }

    private func persist() {
        pendingCount = pending.count
        guard diskLoaded else { return }
        guard let data = try? JSON.encoder.encode(pending) else { return }
        // Location history is sensitive; keep it encrypted whenever the device is locked
        // after first unlock, which still allows background writes.
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
