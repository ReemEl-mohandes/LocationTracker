namespace LocationTracker.Api.Common;

public static class DateTimeExtensions
{
    /// <summary>
    /// Npgsql 6+ throws when a DateTime bound to "timestamp with time zone" has a Kind other
    /// than Utc. Model binding produces Unspecified for a bare ISO string, so every inbound
    /// timestamp is normalized through here before it reaches EF.
    /// </summary>
    public static DateTime ToUtcKind(this DateTime value) => value.Kind switch
    {
        DateTimeKind.Utc => value,
        DateTimeKind.Local => value.ToUniversalTime(),
        _ => DateTime.SpecifyKind(value, DateTimeKind.Utc)
    };

    public static DateTime? ToUtcKind(this DateTime? value) => value?.ToUtcKind();
}
