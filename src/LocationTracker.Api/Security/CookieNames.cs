namespace LocationTracker.Api.Security;

public static class CookieNames
{
    public const string AccessToken = "access_token";
    public const string RefreshToken = "refresh_token";

    /// <summary>Deliberately readable by script — the client must echo it in a header.</summary>
    public const string Csrf = "csrf_token";

    public const string CsrfHeader = "X-CSRF-Token";

    /// <summary>The refresh cookie is scoped so it is not attached to ordinary API calls.</summary>
    public const string RefreshPath = "/api/auth";
}
