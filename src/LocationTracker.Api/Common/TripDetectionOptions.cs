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

    /// <summary>
    /// Fixes vaguer than this are stored but take no part in detection or smoothing. Wi-Fi
    /// and cell positioning routinely reports 30–100 m; beyond that a fix says little more
    /// than which neighbourhood the phone is in.
    /// </summary>
    public double MaxAccuracyMeters { get; set; } = 100d;

    /// <summary>
    /// Movement must clear the combined uncertainty of the two averaged positions being
    /// compared, times this factor. 2 keeps a phone lying still with ±40 m fixes from
    /// opening trips, while a walk is still detected within about a minute.
    /// </summary>
    public double MovementNoiseFactor { get; set; } = 2.0d;

    /// <summary>
    /// A closed trip whose smoothed route never strays further from its start than this many
    /// times its typical fix accuracy (and at least MinTripDistanceMeters) was noise, not a
    /// journey, and is discarded.
    /// </summary>
    public double TripExtentAccuracyFactor { get; set; } = 3.0d;

    /// <summary>
    /// Process noise for the Kalman smoother: how hard the device is expected to accelerate,
    /// in m/s². Lower trusts the motion model more and smooths harder. 0.5 held distance
    /// within a few percent on ±40 m test tracks, for driving and walking alike.
    /// </summary>
    public double SmoothingAccelerationMps2 { get; set; } = 0.5d;
}
