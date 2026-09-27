using LocationTracker.Api.Entities;
using Microsoft.AspNetCore.Authorization;

namespace LocationTracker.Api.Security;

public static class AuthorizationPolicies
{
    public const string AdminOnly = "AdminOnly";

    public static IServiceCollection AddApiAuthorization(this IServiceCollection services)
    {
        services.AddAuthorizationBuilder()
            .AddPolicy(AdminOnly, policy => policy
                .RequireAuthenticatedUser()
                .RequireRole(RoleNames.Admin))

            // Anything without an explicit [AllowAnonymous] requires authentication. Opting in
            // per-controller instead risks a new endpoint shipping unprotected by omission.
            .SetFallbackPolicy(new AuthorizationPolicyBuilder()
                .RequireAuthenticatedUser()
                .Build());

        return services;
    }
}
