namespace LocationTracker.Api.Security;

public class JwtOptions
{
    public const string SectionName = "Jwt";

    public string Issuer { get; set; } = "LocationTracker";
    public string Audience { get; set; } = "LocationTracker";

    /// <summary>Must be at least 32 bytes for HMAC-SHA256. Supplied via configuration, never hard-coded.</summary>
    public string SigningKey { get; set; } = string.Empty;

    public int AccessTokenMinutes { get; set; } = 15;
    public int RefreshTokenDays { get; set; } = 7;
}
