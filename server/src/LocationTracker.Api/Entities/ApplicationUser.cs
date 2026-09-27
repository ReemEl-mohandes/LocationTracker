using Microsoft.AspNetCore.Identity;

namespace LocationTracker.Api.Entities;

/// <summary>
/// Identity already supplies Email, NormalizedEmail, PasswordHash, SecurityStamp,
/// AccessFailedCount, LockoutEnd, LockoutEnabled and ConcurrencyStamp. Only the
/// fields Identity does not model belong here.
/// </summary>
public class ApplicationUser : IdentityUser<Guid>
{
    public string DisplayName { get; set; } = string.Empty;

    public DateTime CreatedAtUtc { get; set; }

    public ICollection<Location> Locations { get; set; } = new List<Location>();
    public ICollection<Trip> Trips { get; set; } = new List<Trip>();
    public ICollection<RefreshToken> RefreshTokens { get; set; } = new List<RefreshToken>();
}
