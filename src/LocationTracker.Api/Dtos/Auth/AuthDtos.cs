using System.ComponentModel.DataAnnotations;

namespace LocationTracker.Api.Dtos.Auth;

public record RegisterRequest
{
    [Required, EmailAddress, MaxLength(256)]
    public string Email { get; init; } = string.Empty;

    // Length is enforced here for a clean 400 with a useful message; IdentityOptions.Password
    // enforces it again at the point of creation so the rule cannot be bypassed.
    [Required, MinLength(12), MaxLength(128)]
    public string Password { get; init; } = string.Empty;

    [Required, MaxLength(128)]
    public string DisplayName { get; init; } = string.Empty;
}

public record LoginRequest
{
    [Required, EmailAddress, MaxLength(256)]
    public string Email { get; init; } = string.Empty;

    [Required, MaxLength(128)]
    public string Password { get; init; } = string.Empty;
}

public record UserProfileResponse(Guid Id, string Email, string DisplayName, IEnumerable<string> Roles, DateTime CreatedAtUtc);

public record AuthResponse(Guid Id, string Email, string DisplayName, IEnumerable<string> Roles, DateTime AccessTokenExpiresAtUtc);
