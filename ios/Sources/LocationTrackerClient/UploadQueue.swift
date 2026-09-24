import Foundation
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
    @Published private(set) var activeTripId: Int64?

    private var pending: [LocationPoint] = []
    private var isFlushing = false
    private var notBefore: Date?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-locations.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSON.decoder.decode([LocationPoint].self, from: data) {
            pending = saved
        }
        pendingCount = pending.count
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
        pending.removeAll()
        activeTripId = nil
        lastUploadAt = nil
        lastUploadSummary = nil
        lastError = nil
        persist()
    }

    func flush() async {
        guard !isFlushing, !pending.isEmpty, TokenStore.load() != nil else { return }
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
                let result = try await APIClient.shared.uploadBatch(batch)
                dropSent(batch.count)
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
        guard let data = try? JSON.encoder.encode(pending) else { return }
        // Location history is sensitive; keep it encrypted whenever the device is locked
        // after first unlock, which still allows background writes.
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
