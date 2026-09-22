namespace LocationTracker.Api.Entities;

public class Trip
{
    public long Id { get; set; }

    public Guid UserId { get; set; }
    public ApplicationUser User { get; set; } = null!;

    public DateTime StartedAtUtc { get; set; }

    /// <summary>Null means the trip is still in progress.</summary>
    public DateTime? EndedAtUtc { get; set; }

    /// <summary>Accumulated incrementally as points arrive, never recomputed over the path.</summary>
    public double DistanceMeters { get; set; }

    /// <summary>Denormalized on close so trip listings never have to compute it.</summary>
    public int? DurationSeconds { get; set; }

    public double StartLatitude { get; set; }
    public double StartLongitude { get; set; }
    public double EndLatitude { get; set; }
    public double EndLongitude { get; set; }

    public int PointCount { get; set; }

    public double MaxSpeedMps { get; set; }
    public double? AverageSpeedMps { get; set; }

    public TripEndReason? EndReason { get; set; }

    /// <summary>
    /// Timestamp of the most recent point that counted as movement. A trip closes at this
    /// instant rather than at the point that triggered the close, so time spent idling at
    /// the destination is not counted as travel time.
    /// </summary>
    public DateTime LastMovingAtUtc { get; set; }

    public ICollection<Location> Locations { get; set; } = new List<Location>();

    public bool IsActive => EndedAtUtc is null;
}
