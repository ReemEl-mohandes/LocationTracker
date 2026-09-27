using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LocationTracker.Api.Common;

namespace LocationTracker.Api.Security;

/// <summary>
/// Double-submit CSRF check. SameSite=Strict already blocks most cross-site cookie attachment,
/// but it is a browser-side policy with historical gaps and no effect on non-browser clients,
/// so state-changing requests must also prove they can *read* the CSRF cookie — something a
/// cross-origin page cannot do.
/// </summary>
public class CsrfMiddleware
{
    private static readonly string[] SafeMethods = { "GET", "HEAD", "OPTIONS", "TRACE" };

    private readonly RequestDelegate _next;
    private readonly ILogger<CsrfMiddleware> _logger;

    public CsrfMiddleware(RequestDelegate next, ILogger<CsrfMiddleware> logger)
    {
        _next = next;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        if (SafeMethods.Contains(context.Request.Method, StringComparer.OrdinalIgnoreCase))
        {
            await _next(context);
            return;
        }

        // Login and register are pre-session: there is no CSRF cookie yet, and forging them
        // gains an attacker nothing since the response sets cookies they still cannot read.
        var path = context.Request.Path.Value ?? string.Empty;
        if (path.StartsWith("/api/auth/login", StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith("/api/auth/register", StringComparison.OrdinalIgnoreCase))
        {
            await _next(context);
            return;
        }

        // Only cookie-authenticated requests are at risk. A caller presenting a bearer header
        // is not subject to automatic credential attachment.
        var hasAuthCookie = context.Request.Cookies.ContainsKey(CookieNames.AccessToken) ||
                            context.Request.Cookies.ContainsKey(CookieNames.RefreshToken);
        if (!hasAuthCookie)
        {
            await _next(context);
            return;
        }

        var cookieToken = context.Request.Cookies[CookieNames.Csrf];
        var headerToken = context.Request.Headers[CookieNames.CsrfHeader].ToString();

        if (string.IsNullOrEmpty(cookieToken) || string.IsNullOrEmpty(headerToken) ||
            !FixedTimeEquals(cookieToken, headerToken))
        {
            _logger.LogWarning("CSRF validation failed for {Method} {Path} from {Ip}",
                context.Request.Method, path, context.Connection.RemoteIpAddress);

            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            context.Response.ContentType = "application/json";
            await context.Response.WriteAsync(
                JsonSerializer.Serialize(new ApiError("CSRF token missing or invalid.")));
            return;
        }

        await _next(context);
    }

    private static bool FixedTimeEquals(string a, string b)
    {
        var left = Encoding.UTF8.GetBytes(a);
        var right = Encoding.UTF8.GetBytes(b);
        return left.Length == right.Length && CryptographicOperations.FixedTimeEquals(left, right);
    }
}
