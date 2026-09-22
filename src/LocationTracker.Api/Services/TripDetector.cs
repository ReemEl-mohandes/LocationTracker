using LocationTracker.Api.Common;
using LocationTracker.Api.Entities;
using Microsoft.Extensions.Options;

namespace LocationTracker.Api.Services;

/// <summary>
/// Carries detection state across a sequence of points so a batch upload costs the same
/// queries as a single ping. The caller loads the starting state once, replays points
/// through the detector, then persists.
/// </summary>
public class DetectionContext
{
    public Location? PreviousPoint { get; set; }
    public Trip? ActiveTrip { get; set; }

    /// <summary>
    /// Implausible segments do not advance PreviousPoint, so the detector stays anchored to
    /// the last trusted fix. This counts how long that has been going on — see the resync
    /// note in the detector.
    /// </summary>
    public int ConsecutiveRejectedSegments { get; set; }

    /// <summary>
    /// Trips closed below the minimum distance. They cannot be deleted mid-detection because
    /// their points may already be persisted from earlier requests, so the caller disposes of
    /// them after SaveChanges, inside the same transaction.
    /// </summary>
    public List<Trip> TripsToDiscard { get; } = new();

    public bool AnyTripStarted { get; set; }
    public bool AnyTripEnded { get; set; }
}

public interface ITripDetector
{
    void ProcessPoint(DetectionContext context, Location point);
    void CloseTrip(Trip trip, TripEndReason reason, List<Trip>? discardSink = null);
}

public class TripDetector : ITripDetector
{
    /// <summary>
    /// After this many consecutive implausible segments the detector accepts the newest point
    /// as its anchor without crediting distance. Without the escape hatch a single bad fix
    /// that happens to sit near the device could wedge detection permanently.
    /// </summary>
    private const int ResyncAfterRejectedSegments = 3;

    private readonly TripDetectionOptions _options;
    private readonly ILogger<TripDetector> _logger;

    public TripDetector(IOptions<TripDetectionOptions> options, ILogger<TripDetector> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public void ProcessPoint(DetectionContext ctx, Location point)
    {
        var previous = ctx.PreviousPoint;

        // Nothing to measure against yet.
        if (previous is null)
        {
            ctx.PreviousPoint = point;
            return;
        }

        var elapsed = point.RecordedAtUtc - previous.RecordedAtUtc;

        // Duplicate or out-of-order timestamps carry no usable velocity. The point is still
        // stored, it just contributes nothing to detection.
        if (elapsed <= TimeSpan.Zero)
            return;

        // The client went dark. Whatever it was doing in the interval is unknown, so the
        // open trip is closed at its last confirmed movement rather than bridged across
        // the silence with a straight line.
        if (elapsed > TimeSpan.FromMinutes(_options.GapTimeoutMinutes))
        {
            if (ctx.ActiveTrip is not null)
            {
                CloseTrip(ctx.ActiveTrip, TripEndReason.ReportingGap, ctx.TripsToDiscard);
                ctx.ActiveTrip = null;
                ctx.AnyTripEnded = true;
            }

            ctx.PreviousPoint = point;
            ctx.ConsecutiveRejectedSegments = 0;
            return;
        }

        var distance = GeoMath.HaversineMeters(
            previous.Latitude, previous.Longitude, point.Latitude, point.Longitude);

        var speed = distance / elapsed.TotalSeconds;

        // A fix that implies impossible speed is a GPS artefact, not travel. Crediting it
        // would add kilometres in a single segment.
        if (speed > _options.MaxPlausibleSpeedMps)
        {
            ctx.ConsecutiveRejectedSegments++;

            if (ctx.ConsecutiveRejectedSegments >= ResyncAfterRejectedSegments)
            {
                _logger.LogWarning(
                    "Re-anchoring after {Count} implausible segments for user {UserId}",
                    ctx.ConsecutiveRejectedSegments, point.UserId);

                ctx.PreviousPoint = point;
                ctx.ConsecutiveRejectedSegments = 0;
            }

            return;
        }

        ctx.ConsecutiveRejectedSegments = 0;

        // Two noise gates. A stationary phone wanders several metres between fixes; without
        // these a parked device manufactures kilometres of travel overnight.
        var farEnough = distance >= _options.MinDisplacementMeters;
        var trustworthy = point.AccuracyMeters is null || point.AccuracyMeters <= distance;
        var isMoving = farEnough && trustworthy && speed >= _options.MovingSpeedMps;

        if (isMoving)
        {
            if (ctx.ActiveTrip is null)
            {
                // The trip opens at the *previous* point, not this one: the leg just travelled
                // is part of the journey, and starting here would clip it off.
                ctx.ActiveTrip = new Trip
                {
                    UserId = point.UserId,
                    StartedAtUtc = previous.RecordedAtUtc,
                    StartLatitude = previous.Latitude,
                    StartLongitude = previous.Longitude,
                    PointCount = 1
                };

                previous.Trip = ctx.ActiveTrip;
                ctx.AnyTripStarted = true;
            }

            var trip = ctx.ActiveTrip;
            trip.DistanceMeters += distance;
            trip.PointCount++;
            trip.MaxSpeedMps = Math.Max(trip.MaxSpeedMps, speed);
            trip.EndLatitude = point.Latitude;
            trip.EndLongitude = point.Longitude;
            trip.LastMovingAtUtc = point.RecordedAtUtc;

            point.Trip = trip;
        }
        else if (ctx.ActiveTrip is not null)
        {
            var still = point.RecordedAtUtc - ctx.ActiveTrip.LastMovingAtUtc;

            if (still > TimeSpan.FromMinutes(_options.IdleTimeoutMinutes))
            {
                CloseTrip(ctx.ActiveTrip, TripEndReason.Idle, ctx.TripsToDiscard);
                ctx.ActiveTrip = null;
                ctx.AnyTripEnded = true;
            }
            else
            {
                // Inside the grace window this is a red light or a queue, not the end of the
                // journey, so the point still belongs to the trip.
                ctx.ActiveTrip.PointCount++;
                point.Trip = ctx.ActiveTrip;
            }
        }

        ctx.PreviousPoint = point;
    }

    /// <summary>
    /// Closes a trip at its last confirmed movement. Ending at the triggering point instead
    /// would fold however long the user sat at the destination into the travel time.
    /// </summary>
    public void CloseTrip(Trip trip, TripEndReason reason, List<Trip>? discardSink = null)
    {
        var endedAt = trip.LastMovingAtUtc == default ? trip.StartedAtUtc : trip.LastMovingAtUtc;

        trip.EndedAtUtc = endedAt;
        trip.EndReason = reason;

        var duration = endedAt - trip.StartedAtUtc;
        trip.DurationSeconds = (int)Math.Max(0, duration.TotalSeconds);
        trip.AverageSpeedMps = trip.DurationSeconds > 0
            ? trip.DistanceMeters / trip.DurationSeconds.Value
            : 0d;

        if (trip.DistanceMeters < _options.MinTripDistanceMeters)
        {
            _logger.LogDebug("Discarding trip for user {UserId}: {Distance:F1} m is below the {Min} m floor",
                trip.UserId, trip.DistanceMeters, _options.MinTripDistanceMeters);

            discardSink?.Add(trip);
        }
    }
}
