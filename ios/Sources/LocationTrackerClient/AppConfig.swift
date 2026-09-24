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

    /// How often queued points are sent. Points go up in batches: one request per interval
    /// instead of one per fix keeps well inside the server's 60-per-minute write limit.
    static let uploadInterval: TimeInterval = 10

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
