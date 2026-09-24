import CoreLocation
import SwiftUI

struct TrackingView: View {
    let profile: UserProfile

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var tracker: LocationTracker
    @Environment(\.openURL) private var openURL

    @State private var trips: [Trip] = []
    @State private var tripsError: String?

    var body: some View {
        NavigationStack {
            List {
                trackingSection
                statusSection
                tripsSection
            }
            .navigationTitle("Hi, \(profile.displayName)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { Task { await session.logout() } }
                }
            }
            .refreshable {
                await queue.flush()
                await loadTrips()
            }
            .onAppear { tracker.autoStart() }
            .task {
                // Refresh the trip list while this screen is visible. The task is cancelled
                // automatically when the view goes away.
                while !Task.isCancelled {
                    await loadTrips()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }

    // MARK: - Sections

    private var trackingSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { tracker.isTracking },
                set: { $0 ? tracker.start() : tracker.pauseByUser() }
            )) {
                Label("Share my location", systemImage: tracker.isTracking ? "location.fill" : "location.slash")
            }

            if tracker.isDenied || tracker.needsAlwaysPermission {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        } footer: {
            if tracker.isDenied {
                Text("Location access is off for this app. Turn it on in Settings.")
            } else if tracker.needsAlwaysPermission {
                Text("Set location access to \"Always\" so tracking continues when the app is in the background.")
            } else if let error = tracker.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            if let location = tracker.lastLocation {
                LabeledContent("Last fix") {
                    VStack(alignment: .trailing) {
                        Text(String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude))
                            .monospacedDigit()
                        Text("±\(Int(location.horizontalAccuracy)) m · \(location.timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if location.speed >= 0 {
                    LabeledContent("Speed", value: String(format: "%.1f km/h", location.speed * 3.6))
                }
            } else {
                LabeledContent("Last fix", value: tracker.isTracking ? "Waiting for GPS…" : "—")
            }

            LabeledContent("Waiting to send", value: "\(queue.pendingCount)")

            if let uploaded = queue.lastUploadAt {
                LabeledContent("Last upload") {
                    VStack(alignment: .trailing) {
                        Text(uploaded.formatted(date: .omitted, time: .standard))
                        if let summary = queue.lastUploadSummary {
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let tripId = queue.activeTripId {
                LabeledContent("Current trip", value: "#\(tripId) in progress")
            }

            if let error = queue.lastError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }

            LabeledContent("Server", value: ServerSettings.serverURL)
                .font(.footnote)
        }
    }

    private var tripsSection: some View {
        Section("My trips") {
            if let tripsError {
                Text(tripsError).font(.footnote).foregroundStyle(.orange)
            }
            if trips.isEmpty && tripsError == nil {
                Text("No trips yet. Start moving with location sharing on.")
                    .foregroundStyle(.secondary)
            }
            ForEach(trips) { trip in
                TripRow(trip: trip)
            }
        }
    }

    private func loadTrips() async {
        do {
            trips = try await APIClient.shared.myTrips()
            tripsError = nil
        } catch is CancellationError {
            return
        } catch {
            tripsError = error.localizedDescription
        }
    }
}

private struct TripRow: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(distance).bold()
                if trip.isActive {
                    Text("IN PROGRESS")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer()
                if let duration = trip.duration {
                    Text(duration).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text("\(trip.startedAtUtc.formatted(date: .abbreviated, time: .shortened)) · \(trip.pointCount) points · max \(String(format: "%.0f", trip.maxSpeedMps * 3.6)) km/h")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var distance: String {
        trip.distanceMeters >= 1000
            ? String(format: "%.2f km", trip.distanceMeters / 1000)
            : "\(Int(trip.distanceMeters)) m"
    }
}
