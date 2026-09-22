using LocationTracker.Api.Dtos.Locations;
using LocationTracker.Api.Entities;

namespace LocationTracker.Api.Dtos.Trips;

public record TripResponse(
    long Id,
    Guid UserId,
    DateTime StartedAtUtc,
    DateTime? EndedAtUtc,
    double DistanceMeters,
    double DistanceKilometers,
    int? DurationSeconds,
    string? Duration,
    double StartLatitude,
    double StartLongitude,
    double EndLatitude,
    double EndLongitude,
    int PointCount,
    double MaxSpeedMps,
    double? AverageSpeedMps,
    TripEndReason? EndReason,
    bool IsActive);

public record TripDetailResponse(TripResponse Trip, IReadOnlyList<TrackPointResponse> Path);
