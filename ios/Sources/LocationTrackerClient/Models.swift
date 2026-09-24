import Foundation

// Mirrors of the API's DTOs. The server serializes camelCase, which matches Swift property
// names, so no CodingKeys are needed.

struct LoginRequest: Encodable {
    let email: String
    let password: String
}

struct RegisterRequest: Encodable {
    let email: String
    let password: String
    let displayName: String
}

struct AuthResponse: Decodable {
    let id: UUID
    let email: String
    let displayName: String
    let roles: [String]
    let accessTokenExpiresAtUtc: Date
}

struct UserProfile: Codable, Equatable {
    let id: UUID
    let email: String
    let displayName: String
    let roles: [String]
}

/// One fix, in the shape POST /api/locations/batch expects.
struct LocationPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?
    let speed: Double?
    let heading: Double?
    let recordedAtUtc: Date
}

struct LocationBatchRequest: Encodable {
    let points: [LocationPoint]
}

struct BatchIngestResponse: Decodable {
    let accepted: Int
    let rejected: Int
    let activeTripId: Int64?
    let warnings: [String]
}

struct Trip: Decodable, Identifiable, Equatable {
    let id: Int64
    let startedAtUtc: Date
    let endedAtUtc: Date?
    let distanceMeters: Double
    let durationSeconds: Int?
    let duration: String?
    let pointCount: Int
    let maxSpeedMps: Double
    let averageSpeedMps: Double?
    let endReason: String?
    let isActive: Bool
}

struct PagedResult<Item: Decodable>: Decodable {
    let items: [Item]
    let page: Int
    let pageSize: Int
    let totalCount: Int64
}

struct ServerErrorBody: Decodable {
    let message: String?
    let errors: [String: [String]]?
}

// MARK: - JSON

enum JSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = ServerDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(raw)")
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ServerDate.format(date))
        }
        return encoder
    }()
}

/// .NET writes anywhere from zero to seven fractional-second digits ("…:22Z",
/// "…:56.708553Z"). ISO8601DateFormatter only handles exactly three reliably, so the fraction
/// is normalised to three digits before parsing.
enum ServerDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func format(_ date: Date) -> String {
        withFraction.string(from: date)
    }

    static func parse(_ raw: String) -> Date? {
        var s = raw
        // Every timestamp the API emits is UTC; tolerate one that lost its designator.
        if !s.hasSuffix("Z") && s.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) == nil {
            s += "Z"
        }

        guard let dot = s.firstIndex(of: ".") else {
            return withoutFraction.date(from: s)
        }

        let fractionStart = s.index(after: dot)
        let fractionEnd = s[fractionStart...].firstIndex(where: { !$0.isNumber }) ?? s.endIndex
        let digits = String((String(s[fractionStart..<fractionEnd]) + "000").prefix(3))
        s = String(s[..<fractionStart]) + digits + String(s[fractionEnd...])
        return withFraction.date(from: s)
    }
}
