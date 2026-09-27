using LocationTracker.Api.Common;
using LocationTracker.Api.Data;
using LocationTracker.Api.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace LocationTracker.Api.Services;

public interface ITripFinalizer
{
    /// <summary>
    /// Recomputes distance and speeds from the smoothed track of each trip, and deletes closed
    /// trips that turn out to be noise. Must run after the trips and their points are saved,
    /// inside the caller's transaction. Returns how many trips were discarded.
    /// </summary>
    Task<int> FinalizeAsync(IEnumerable<Trip> trips, CancellationToken ct);

    /// <summary>The trip's path as the smoother sees it, for drawing on a map.</summary>
    Task<IReadOnlyList<SmoothedPoint>> SmoothedPathAsync(Trip trip, CancellationToken ct);
}

/// <summary>
/// The detector decides where trips start and end, but the distance it accumulates along the
/// way sums raw fix-to-fix hops, and coarse positioning makes each hop part noise. This
/// replaces those provisional figures with ones read off a Kalman-smoothed track, which on
/// ±40 m test tracks landed within a few percent of the true distance, where raw summing
/// was off by a factor of two or more.
/// </summary>
public class TripFinalizer : ITripFinalizer
{
    private readonly AppDbContext _db;
    private readonly TripDetectionOptions _options;
    private readonly ILogger<TripFinalizer> _logger;

    public TripFinalizer(AppDbContext db, IOptions<TripDetectionOptions> options, ILogger<TripFinalizer> logger)
    {
        _db = db;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<int> FinalizeAsync(IEnumerable<Trip> trips, CancellationToken ct)
    {
        var discard = new List<Trip>();

        foreach (var trip in trips.Where(t => t.Id != 0).Distinct())
        {
            var inputs = await LoadInputsAsync(trip, ct);
            var track = TrackSmoother.Smooth(inputs, _options.SmoothingAccelerationMps2);

            trip.DistanceMeters = TrackSmoother.DistanceMeters(track);
            trip.MaxSpeedMps = track.Count == 0
                ? 0d
                : Math.Min(track.Max(p => p.SpeedMps), _options.MaxPlausibleSpeedMps);

            if (trip.EndedAtUtc is null) continue;

            trip.AverageSpeedMps = trip.DurationSeconds > 0 ? trip.DistanceMeters / trip.DurationSeconds.Value : 0d;

            if (IsNoise(trip, inputs, track, out var why))
            {
                _logger.LogDebug("Discarding trip {TripId} for user {UserId}: {Reason}", trip.Id, trip.UserId, why);
                discard.Add(trip);
            }
        }

        await _db.SaveChangesAsync(ct);

        // Detaching the points first keeps the raw history intact: only the derived rollup goes.
        foreach (var trip in discard)
        {
            await _db.Locations
                .Where(l => l.TripId == trip.Id)
                .ExecuteUpdateAsync(s => s.SetProperty(l => l.TripId, (long?)null), ct);

            await _db.Trips.Where(t => t.Id == trip.Id).ExecuteDeleteAsync(ct);
            _db.Entry(trip).State = EntityState.Detached;
        }

        return discard.Count;
    }

    public async Task<IReadOnlyList<SmoothedPoint>> SmoothedPathAsync(Trip trip, CancellationToken ct)
        => TrackSmoother.Smooth(await LoadInputsAsync(trip, ct), _options.SmoothingAccelerationMps2);

    private bool IsNoise(Trip trip, IReadOnlyList<TrackInput> inputs, IReadOnlyList<SmoothedPoint> track, out string why)
    {
        if (trip.DistanceMeters < _options.MinTripDistanceMeters)
        {
            why = $"{trip.DistanceMeters:F0} m is below the {_options.MinTripDistanceMeters} m floor";
            return true;
        }

        // Coarse fixes wandering around one spot can add up to a respectable distance while
        // never actually going anywhere. A real journey gets well clear of its own start.
        var typicalAccuracy = Median(inputs.Select(p => p.AccuracyMeters ?? 0d));
        var requiredExtent = Math.Max(_options.MinTripDistanceMeters, _options.TripExtentAccuracyFactor * typicalAccuracy);
        var extent = TrackSmoother.ExtentMeters(track);

        if (extent < requiredExtent)
        {
            why = $"never got more than {extent:F0} m from its start (needs {requiredExtent:F0} m at ±{typicalAccuracy:F0} m accuracy)";
            return true;
        }

        why = string.Empty;
        return false;
    }

    /// <summary>
    /// A closed trip's points up to its last movement, skipping fixes too vague to trust. The
    /// grace-window points after the last movement (waiting at the destination) are excluded
    /// so their wobble adds no distance.
    /// </summary>
    private async Task<IReadOnlyList<TrackInput>> LoadInputsAsync(Trip trip, CancellationToken ct)
    {
        var query = _db.Locations.AsNoTracking()
            .Where(l => l.TripId == trip.Id)
            .Where(l => l.AccuracyMeters == null || l.AccuracyMeters <= _options.MaxAccuracyMeters);

        if (trip.EndedAtUtc is { } end)
            query = query.Where(l => l.RecordedAtUtc <= end);

        return await query
            .OrderBy(l => l.RecordedAtUtc)
            .Select(l => new TrackInput(l.Latitude, l.Longitude, l.AccuracyMeters, l.RecordedAtUtc))
            .ToListAsync(ct);
    }

    private static double Median(IEnumerable<double> values)
    {
        var sorted = values.OrderBy(v => v).ToList();
        if (sorted.Count == 0) return 0d;
        var mid = sorted.Count / 2;
        return sorted.Count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2d;
    }
}
