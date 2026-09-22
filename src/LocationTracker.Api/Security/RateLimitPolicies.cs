using System.Globalization;
using System.Threading.RateLimiting;
using System.Text.Json;
using LocationTracker.Api.Common;
using Microsoft.AspNetCore.RateLimiting;

namespace LocationTracker.Api.Security;

public static class RateLimitPolicies
{
    public const string Login = "login";
    public const string Register = "register";
    public const string LocationWrite = "location-write";

    public static IServiceCollection AddApiRateLimiting(this IServiceCollection services)
    {
        services.AddRateLimiter(options =>
        {
            options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

            options.OnRejected = async (context, token) =>
            {
                if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
                {
                    context.HttpContext.Response.Headers.RetryAfter =
                        ((int)retryAfter.TotalSeconds).ToString(CultureInfo.InvariantCulture);
                }

                context.HttpContext.Response.ContentType = "application/json";
                await context.HttpContext.Response.WriteAsync(
                    JsonSerializer.Serialize(new ApiError("Too many requests. Please slow down.")),
                    token);
            };

            // Credential stuffing is spread over many accounts, so per-account lockout alone
            // never sees it. A per-IP window is the layer that does.
            options.AddPolicy(Login, context => RateLimitPartition.GetSlidingWindowLimiter(
                ClientKey(context),
                _ => new SlidingWindowRateLimiterOptions
                {
                    PermitLimit = 5,
                    Window = TimeSpan.FromMinutes(1),
                    SegmentsPerWindow = 6,
                    QueueLimit = 0,
                    QueueProcessingOrder = QueueProcessingOrder.OldestFirst
                }));

            options.AddPolicy(Register, context => RateLimitPartition.GetFixedWindowLimiter(
                ClientKey(context),
                _ => new FixedWindowRateLimiterOptions
                {
                    PermitLimit = 3,
                    Window = TimeSpan.FromHours(1),
                    QueueLimit = 0
                }));

            // Partitioned by user, not IP: several users behind one NAT must not starve
            // each other's location pings. A token bucket absorbs the bursts a phone
            // produces when it reconnects.
            options.AddPolicy(LocationWrite, context => RateLimitPartition.GetTokenBucketLimiter(
                context.User.Identity?.IsAuthenticated == true
                    ? $"user:{context.User.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)?.Value}"
                    : ClientKey(context),
                _ => new TokenBucketRateLimiterOptions
                {
                    TokenLimit = 120,
                    TokensPerPeriod = 60,
                    ReplenishmentPeriod = TimeSpan.FromMinutes(1),
                    QueueLimit = 0,
                    AutoReplenishment = true
                }));

            options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(
                context => RateLimitPartition.GetFixedWindowLimiter(
                    ClientKey(context),
                    _ => new FixedWindowRateLimiterOptions
                    {
                        PermitLimit = 100,
                        Window = TimeSpan.FromMinutes(1),
                        QueueLimit = 0
                    }));
        });

        return services;
    }

    /// <summary>
    /// The partition key is the real client IP. Behind the nginx container every request
    /// originates from the proxy, so this is only correct because UseForwardedHeaders has
    /// already rewritten RemoteIpAddress — it must run before UseRateLimiter, or every
    /// caller collapses into a single bucket and the limiter protects nothing.
    /// </summary>
    private static string ClientKey(HttpContext context) =>
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
}
