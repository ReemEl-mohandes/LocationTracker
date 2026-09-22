using LocationTracker.Api.Entities;
using Microsoft.AspNetCore.Identity;

namespace LocationTracker.Api.Data;

public static class IdentitySeeder
{
    /// <summary>
    /// Creates the two roles and the bootstrap administrator. Registration only ever grants
    /// the User role, so without this there would be no way to obtain an admin account.
    /// </summary>
    public static async Task SeedAsync(IServiceProvider services, IConfiguration config, ILogger logger)
    {
        var roleManager = services.GetRequiredService<RoleManager<ApplicationRole>>();
        var userManager = services.GetRequiredService<UserManager<ApplicationUser>>();

        foreach (var role in new[] { RoleNames.User, RoleNames.Admin })
        {
            if (!await roleManager.RoleExistsAsync(role))
                await roleManager.CreateAsync(new ApplicationRole(role));
        }

        var email = config["SeedAdmin:Email"];
        var password = config["SeedAdmin:Password"];

        if (string.IsNullOrWhiteSpace(email) || string.IsNullOrWhiteSpace(password))
        {
            logger.LogWarning("SeedAdmin:Email / SeedAdmin:Password not configured; no administrator was seeded.");
            return;
        }

        // Only ever creates. Resetting the password of an existing admin on every restart
        // would silently undo a deliberate password change.
        if (await userManager.FindByEmailAsync(email) is not null)
        {
            logger.LogInformation("Seed administrator {Email} already exists.", email);
            return;
        }

        var admin = new ApplicationUser
        {
            Id = Guid.NewGuid(),
            UserName = email,
            Email = email,
            DisplayName = "Administrator",
            CreatedAtUtc = DateTime.UtcNow,
            EmailConfirmed = true,
            LockoutEnabled = true
        };

        var result = await userManager.CreateAsync(admin, password);

        if (!result.Succeeded)
        {
            logger.LogError("Failed to seed administrator: {Errors}",
                string.Join("; ", result.Errors.Select(e => e.Description)));
            return;
        }

        await userManager.AddToRoleAsync(admin, RoleNames.Admin);
        logger.LogInformation("Seeded administrator {Email}", email);
    }
}
