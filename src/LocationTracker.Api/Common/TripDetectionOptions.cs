namespace LocationTracker.Api.Common;

/// <summary>
/// Bound from the "TripDetection" configuration section. These are thresholds, not constants:
/// they want tuning against real device data, so they must not be literals in the detector.
/// </summary>
public class TripDetectionOptions
{
    public const string SectionName = "TripDetection";

    /// <summary>
    /// Segments shorter than this are treated as GPS jitter and contribute no distance.
    /// A stationary phone drifts several metres between fixes; without this floor a parked
    /// device accumulates kilometres of phantom travel overnight.
    /// </summary>
    public double MinDisplacementMeters { get; set; } = 15d;

    /// <summary>At or above this speed the user counts as moving.</summary>
    public double MovingSpeedMps { get; set; } = 1.0d;

    /// <summary>Above this the fix is a GPS teleport, not travel, and the segment is discarded.</summary>
    public double MaxPlausibleSpeedMps { get; set; } = 70d;

    /// <summary>Stillness beyond this closes an open trip.</summary>
    public int IdleTimeoutMinutes { get; set; } = 5;

    /// <summary>A silence longer than this means the client went dark; close the trip.</summary>
    public int GapTimeoutMinutes { get; set; } = 15;

    /// <summary>Trips shorter than this are discarded on close. A walk to the mailbox is not a trip.</summary>
    public double MinTripDistanceMeters { get; set; } = 100d;

    /// <summary>How often the background sweeper looks for abandoned open trips.</summary>
    public int SweepIntervalSeconds { get; set; } = 60;

    /// <summary>Upper bound on points accepted in one batch upload.</summary>
    public int MaxBatchSize { get; set; } = 1000;
}
