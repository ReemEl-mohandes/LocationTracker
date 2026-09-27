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
    /// <summary>The most recent fix accurate enough to take part in detection.</summary>
    public Location? PreviousPoint { get; set; }

    /// <summary>
    /// Usable fixes from the last minute or so, oldest first, ending with PreviousPoint.
    /// Movement is judged by comparing averages over this window rather than two single
    /// fixes, which is what keeps coarse (±40 m) positioning from reading as travel.
    /// </summary>
    public List<Location> RecentPoints { get; } = new();

    /// <summary>Newest timestamp stored for the user, usable or not; batches must not predate it.</summary>
    public DateTime? LatestRecordedAtUtc { get; set; }

    public Trip? ActiveTrip { get; set; }

    /// <summary>
    /// Implausible segments do not advance PreviousPoint, so the detector stays anchored to
    /// the last trusted fix. This counts how long that has been going on — see the resync
    /// note in the detector.
    /// </summary>
    public int ConsecutiveRejectedSegments { get; set; }

    /// <summary>
    /// Trips closed while processing. Their final distance and speed, and whether they are
    /// kept at all, are settled by TripFinalizer once their points are persisted.
    /// </summary>
    public List<Trip> ClosedTrips { get; } = new();

    public bool AnyTripStarted { get; set; }
    public bool AnyTripEnded { get; set; }
}

public interface ITripDetector
{
    void ProcessPoint(DetectionContext context, Location point);
    void CloseTrip(Trip trip, TripEndReason reason);
}

/// <summary>
/// Decides when trips start and end. Distance and speed recorded here are provisional:
/// TripFinalizer replaces them with values read off a smoothed track.
/// </summary>
public class TripDetector : ITripDetector
{
    /// <summary>
    /// After this many consecutive implausible segments the detector accepts the newest point
    /// as its anchor without crediting distance. Without the escape hatch a single bad fix
    /// that happens to sit near the device could wedge detection permanently.
    /// </summary>
    private const int ResyncAfterRejectedSegments = 3;

    /// <summary>Fixes averaged as "where the device is now".</summary>
    public static readonly TimeSpan RecentWindow = TimeSpan.FromSeconds(10);

    /// <summary>
    /// Fixes this far back (between the two bounds) are averaged as "where it was". The gap
    /// between the windows is long enough for real movement to clear the noise, short enough
    /// that a trip starts within a minute of setting off.
    /// </summary>
    public static readonly TimeSpan BaselineFrom = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan BaselineTo = TimeSpan.FromSeconds(20);

    /// <summary>How much history the context needs to hold.</summary>
    public static TimeSpan HistoryWindow => BaselineFrom + RecentWindow;

    /// <summary>GPS-grade fixes whose reported (Doppler) speed is trusted as-is.</summary>
    private const double TrustedSpeedAccuracyMeters = 20d;

    private readonly TripDetectionOptions _options;
    private readonly ILogger<TripDetector> _logger;

    public TripDetector(IOptions<TripDetectionOptions> options, ILogger<TripDetector> logger)
    {
        _options = options.Value;
        _logger = logger;
    }

    public void ProcessPoint(DetectionContext ctx, Location point)
    {
        // Too vague to say whether the device moved. Stored as history, never measured.
        if (point.AccuracyMeters > _options.MaxAccuracyMeters)
            return;

        var previous = ctx.PreviousPoint;

        // Nothing to measure against yet.
        if (previous is null)
        {
            Reanchor(ctx, point);
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
                CloseAndRecord(ctx, TripEndReason.ReportingGap);
            }

            Reanchor(ctx, point);
            return;
        }

        var segment = GeoMath.HaversineMeters(
            previous.Latitude, previous.Longitude, point.Latitude, point.Longitude);

        // A fix that implies impossible speed is an artefact, not travel. Crediting it would
        // add kilometres in a single segment.
        if (segment / elapsed.TotalSeconds > _options.MaxPlausibleSpeedMps)
        {
            ctx.ConsecutiveRejectedSegments++;

            if (ctx.ConsecutiveRejectedSegments >= ResyncAfterRejectedSegments)
            {
                _logger.LogWarning(
                    "Re-anchoring after {Count} implausible segments for user {UserId}",
                    ctx.ConsecutiveRejectedSegments, point.UserId);

                Reanchor(ctx, point);
            }

            return;
        }

        ctx.ConsecutiveRejectedSegments = 0;
        Remember(ctx, point);

        var (isMoving, startPoint, speed) = MeasureMovement(ctx, point, previous);

        if (isMoving)
        {
            if (ctx.ActiveTrip is null)
            {
                // The trip opens where the baseline began, not at this point: the stretch just
                // travelled is part of the journey, and starting here would clip it off.
                ctx.ActiveTrip = new Trip
                {
                    UserId = point.UserId,
                    StartedAtUtc = startPoint.RecordedAtUtc,
                    StartLatitude = startPoint.Latitude,
                    StartLongitude = startPoint.Longitude,
                };

                // With sparse reporting the start point may already have aged out of the
                // window, so it is attached explicitly.
                var earlier = ctx.RecentPoints
                    .Where(p => p.RecordedAtUtc >= startPoint.RecordedAtUtc && p != point)
                    .Append(startPoint)
                    .Distinct();

                foreach (var p in earlier)
                {
                    p.Trip = ctx.ActiveTrip;
                    ctx.ActiveTrip.PointCount++;
                }

                ctx.AnyTripStarted = true;
            }

            var trip = ctx.ActiveTrip;
            trip.DistanceMeters += segment;
            trip.PointCount++;
            trip.MaxSpeedMps = Math.Max(trip.MaxSpeedMps, Math.Min(speed, _options.MaxPlausibleSpeedMps));
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
                CloseAndRecord(ctx, TripEndReason.Idle);
            }
            else
            {
                // Inside the grace window this is a red light or a queue, not the end of the
                // journey, so the point still belongs to the trip.
                ctx.ActiveTrip.PointCount++;
                point.Trip = ctx.ActiveTrip;
            }
        }
    }

    /// <summary>
    /// Compares the average position over the last few seconds with the average from 20–60
    /// seconds earlier. Averaging n fixes shrinks their noise by √n, so a phone lying still
    /// with ±40 m positioning stays put while genuine travel stands out. With sparse
    /// reporting (a fix every 30 s or more) each window holds a single fix, and this reduces
    /// to comparing the point with its predecessor.
    /// </summary>
    private (bool IsMoving, Location StartPoint, double SpeedMps) MeasureMovement(
        DetectionContext ctx, Location point, Location previous)
    {
        var now = point.RecordedAtUtc;
        var recent = ctx.RecentPoints.Where(p => p.RecordedAtUtc >= now - RecentWindow).ToList();
        var baseline = ctx.RecentPoints
            .Where(p => p.RecordedAtUtc >= now - BaselineFrom && p.RecordedAtUtc <= now - BaselineTo)
            .ToList();

        if (baseline.Count == 0)
        {
            var older = ctx.RecentPoints.LastOrDefault(p => p.RecordedAtUtc < now - RecentWindow) ?? previous;
            baseline.Add(older);
        }

        var from = Centroid(baseline);
        var to = Centroid(recent);

        var distance = GeoMath.HaversineMeters(from.Latitude, from.Longitude, to.Latitude, to.Longitude);
        var seconds = Math.Max((to.Time - from.Time).TotalSeconds, 1e-6);
        var speed = distance / seconds;

        var threshold = Math.Max(
            _options.MinDisplacementMeters,
            _options.MovementNoiseFactor * Math.Sqrt((from.Uncertainty * from.Uncertainty) + (to.Uncertainty * to.Uncertainty)));

        // A GPS fix's own speed comes from Doppler shift, not position differences, and is
        // accurate even at walking pace; trust it when the fix itself is good.
        var reportedMoving = point.Speed >= _options.MovingSpeedMps
                             && point.AccuracyMeters <= TrustedSpeedAccuracyMeters;

        var isMoving = reportedMoving || (distance >= threshold && speed >= _options.MovingSpeedMps);
        var bestSpeed = reportedMoving ? Math.Max(speed, point.Speed!.Value) : speed;

        return (isMoving, baseline[0], bestSpeed);
    }

    private static (double Latitude, double Longitude, DateTime Time, double Uncertainty) Centroid(List<Location> points)
    {
        var n = points.Count;
        var lat = points.Average(p => p.Latitude);
        var lon = points.Average(p => p.Longitude);
        var ticks = (long)points.Average(p => (double)p.RecordedAtUtc.Ticks);
        var meanSquareAccuracy = points.Average(p => (p.AccuracyMeters ?? 0d) * (p.AccuracyMeters ?? 0d));

        return (lat, lon, new DateTime(ticks, DateTimeKind.Utc), Math.Sqrt(meanSquareAccuracy / n));
    }

    private static void Remember(DetectionContext ctx, Location point)
    {
        ctx.PreviousPoint = point;
        ctx.RecentPoints.Add(point);

        var cutoff = point.RecordedAtUtc - HistoryWindow;
        ctx.RecentPoints.RemoveAll(p => p.RecordedAtUtc < cutoff);
    }

    private static void Reanchor(DetectionContext ctx, Location point)
    {
        ctx.RecentPoints.Clear();
        ctx.ConsecutiveRejectedSegments = 0;
        Remember(ctx, point);
    }

    private void CloseAndRecord(DetectionContext ctx, TripEndReason reason)
    {
        CloseTrip(ctx.ActiveTrip!, reason);
        ctx.ClosedTrips.Add(ctx.ActiveTrip!);
        ctx.ActiveTrip = null;
        ctx.AnyTripEnded = true;
    }

    /// <summary>
    /// Closes a trip at its last confirmed movement. Ending at the triggering point instead
    /// would fold however long the user sat at the destination into the travel time.
    /// </summary>
    public void CloseTrip(Trip trip, TripEndReason reason)
    {
        var endedAt = trip.LastMovingAtUtc == default ? trip.StartedAtUtc : trip.LastMovingAtUtc;

        trip.EndedAtUtc = endedAt;
        trip.EndReason = reason;

        var duration = endedAt - trip.StartedAtUtc;
        trip.DurationSeconds = (int)Math.Max(0, duration.TotalSeconds);
        trip.AverageSpeedMps = trip.DurationSeconds > 0
            ? trip.DistanceMeters / trip.DurationSeconds.Value
            : 0d;
    }
}
