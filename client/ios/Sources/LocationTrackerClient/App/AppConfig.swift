import Foundation

enum AppConfig {
    /// The AWS EC2 server (Elastic IP, so it stays fixed). Can be changed on the sign-in
    /// screen, e.g. to the local PC's LAN address (https://192.168.1.8) for development.
    static let defaultServerURL = "https://34.199.20.93"

    static let defaultEmail = "reem@example.com"

    /// SHA-256 fingerprints of the self-signed server certificates this app trusts, one per
    /// deployment, each exactly as printed by
    ///   openssl x509 -in nginx/certs/server.crt -noout -fingerprint -sha256
    /// A certificate that a public CA signs passes normal validation and never reaches this
    /// check. Update the matching entry whenever a server's certificate is regenerated.
    static let pinnedCertificateSHA256: Set<String> = [
        // AWS EC2 reem-server, 34.199.20.93
        "95:D6:39:F8:74:7C:A9:0F:9E:D3:7D:07:A5:5C:7F:E3:18:5F:A6:95:E8:BC:46:E3:08:A6:1E:85:00:A7:ED:E4",
        // Local PC (docker compose on the LAN)
        "A2:D9:FB:54:49:50:BB:D3:B7:43:B7:E1:29:82:94:9C:BB:98:A5:29:EC:71:62:FE:81:B1:AA:C8:BF:CF:08:66",
    ]

    // MARK: Uploads and battery
    //
    // Every upload wakes the cellular radio, which then stays powered for several seconds, so
    // sending in batches is the single biggest battery lever after GPS accuracy.

    /// How often queued points are sent while moving.
    static let uploadInterval: TimeInterval = 30

    /// The same, while the phone is in Low Power Mode.
    static let lowPowerUploadInterval: TimeInterval = 60

    /// How often the tracker's housekeeping runs: uploads, heartbeat, power mode.
    static let tickInterval: TimeInterval = 30

    /// While stationary no fixes arrive on their own, so one is requested this often. It
    /// keeps the admin map showing the user as online, and it gives the server the stillness
    /// points it uses to close a trip.
    /// Presence heartbeat: while running (even stationary) send one location this often so the
    /// admin map shows the user online. Not movement tracking — just "I am here".
    static let heartbeatInterval: TimeInterval = 30

    /// No movement for this long switches GPS to low-power positioning.
    static let stationaryAfter: TimeInterval = 3 * 60

    /// The same, when the motion coprocessor reports the user as still.
    static let stationaryAfterMotionStill: TimeInterval = 60

    /// Speed that counts as moving; matches the server's MovingSpeedMps.
    static let movingSpeedMps: Double = 1.0

    /// In power-saving mode iOS reports only after this much travel, which also serves as the
    /// signal that movement has resumed.
    static let stationaryDistanceFilterMeters: Double = 50

    /// Radius of the geofence kept around the last position. Leaving it relaunches the app,
    /// even after it was swiped away or the phone restarted. iOS does not reliably detect
    /// fences much smaller than 100–150 m.
    static let wakeFenceRadiusMeters: Double = 150

    /// If the app stops running (swiped away, or killed by iOS), this reminder fires after
    /// this long. It is pushed back regularly while the app is alive.
    static let watchdogDelay: TimeInterval = 20 * 60

    /// The server accepts up to 1000 points per batch.
    static let maxBatchSize = 500

    /// Oldest points are dropped beyond this while offline, so the queue cannot grow forever.
    static let maxQueuedPoints = 20_000

    /// Fixes worse than this are noise for trip detection and are not sent.
    static let maxAcceptedAccuracyMeters: Double = 150

    /// Minimum movement between fixes. The server ignores displacements under 15 m anyway.
    static let distanceFilterMeters: Double = 10
}

/// The server address, remembered between launches.
enum ServerSettings {
    private static let key = "serverURL"

    static var serverURL: String {
        get { UserDefaults.standard.string(forKey: key) ?? AppConfig.defaultServerURL }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
