namespace LocationTracker.Api.Entities;

public enum TripEndReason
{
    /// <summary>The user stopped moving for longer than the idle timeout.</summary>
    Idle = 0,

    /// <summary>A point arrived after a gap long enough to imply the client went dark.</summary>
    ReportingGap = 1,

    /// <summary>The background sweeper closed a trip whose client stopped reporting entirely.</summary>
    Swept = 2
}
