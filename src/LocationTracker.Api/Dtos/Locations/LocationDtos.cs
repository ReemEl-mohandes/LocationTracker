using System.ComponentModel.DataAnnotations;

namespace LocationTracker.Api.Dtos.Locations;

public record CreateLocationRequest
{
    [Required, Range(-90d, 90d)]
    public double Latitude { get; init; }

    [Required, Range(-180d, 180d)]
    public double Longitude { get; init; }

    [Range(0d, 100_000d)]
    public double? AccuracyMeters { get; init; }

    [Range(0d, 1000d)]
    public double? Speed { get; init; }

    [Range(0d, 360d)]
    public double? Heading { get; init; }

    /// <summary>Device-reported instant. Omitted means "now".</summary>
    public DateTime? RecordedAtUtc { get; init; }
}

public record CreateLocationBatchRequest
{
    [Required, MinLength(1)]
    public List<CreateLocationRequest> Points { get; init; } = new();
}

public record LocationResponse(
    long Id,
    double Latitude,
    double Longitude,
    double? AccuracyMeters,
    double? Speed,
    double? Heading,
    DateTime RecordedAtUtc,
    DateTime ReceivedAtUtc,
    long? TripId);

/// <summary>A point stripped to what a map path needs, for trip replay.</summary>
public record TrackPointResponse(double Latitude, double Longitude, DateTime RecordedAtUtc);

public record LocationIngestResponse(LocationResponse Location, long? ActiveTripId, bool TripStarted, bool TripEnded);

public record BatchIngestResponse(int Accepted, int Rejected, long? ActiveTripId, IReadOnlyList<string> Warnings);

/// <summary>An admin's map view: one row per user, their most recent fix.</summary>
public record UserLatestLocationResponse(
    Guid UserId,
    string Email,
    string DisplayName,
    LocationResponse? Latest,
    long? ActiveTripId);
