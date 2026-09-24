import Foundation

enum AppConfig {
    /// The phone cannot reach the server as "localhost" — that is the phone itself. This is
    /// the PC's address on the network the phone shares with it, and it can be changed on the
    /// sign-in screen. On the PC, `ipconfig` shows it.
    static let defaultServerURL = "https://192.168.1.8"

    static let defaultEmail = "reem@example.com"

    /// SHA-256 of the server's self-signed certificate, exactly as printed by
    ///   openssl x509 -in nginx/certs/server.crt -noout -fingerprint -sha256
    /// A certificate that a public CA signs passes normal validation and never reaches this
    /// check. Update the value whenever generate-certs.sh is re-run.
    static let pinnedCertificateSHA256 =
        "A2:D9:FB:54:49:50:BB:D3:B7:43:B7:E1:29:82:94:9C:BB:98:A5:29:EC:71:62:FE:81:B1:AA:C8:BF:CF:08:66"

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
