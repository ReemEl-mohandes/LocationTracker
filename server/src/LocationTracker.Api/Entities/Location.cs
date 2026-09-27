namespace LocationTracker.Api.Entities;

public class Location
{
    public long Id { get; set; }

    public Guid UserId { get; set; }
    public ApplicationUser User { get; set; } = null!;

    /// <summary>Null while the point is stationary or otherwise unassigned to a trip.</summary>
    public long? TripId { get; set; }
    public Trip? Trip { get; set; }

    public double Latitude { get; set; }
    public double Longitude { get; set; }

    public double? AccuracyMeters { get; set; }
    public double? Speed { get; set; }
    public double? Heading { get; set; }

    /// <summary>When the device says the fix was taken.</summary>
    public DateTime RecordedAtUtc { get; set; }

    /// <summary>Server-stamped on ingest; unlike RecordedAtUtc a client cannot forge it.</summary>
    public DateTime ReceivedAtUtc { get; set; }
}
