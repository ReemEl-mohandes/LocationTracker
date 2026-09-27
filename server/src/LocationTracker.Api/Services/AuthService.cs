using LocationTracker.Api.Data;
using LocationTracker.Api.Dtos.Auth;
using LocationTracker.Api.Entities;
using LocationTracker.Api.Security;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace LocationTracker.Api.Services;

public record AuthTokens(string AccessToken, string RefreshToken, string CsrfToken, DateTime AccessTokenExpiresAtUtc);

public record AuthOutcome(bool Succeeded, string? Error, ApplicationUser? User, AuthTokens? Tokens,
    IReadOnlyDictionary<string, string[]>? ValidationErrors = null);

public interface IAuthService
{
    Task<AuthOutcome> RegisterAsync(RegisterRequest request, string? ip, CancellationToken ct);
    Task<AuthOutcome> LoginAsync(LoginRequest request, string? ip, CancellationToken ct);
    Task<AuthOutcome> RefreshAsync(string? refreshToken, string? ip, CancellationToken ct);
    Task LogoutAsync(Guid userId, string? refreshToken, CancellationToken ct);
    Task<IList<string>> GetRolesAsync(ApplicationUser user);
}

public class AuthService : IAuthService
{
    /// <summary>
    /// Returned for every failed login regardless of cause. Distinguishing "no such user"
    /// from "wrong password" from "account locked" hands an attacker a free oracle for
    /// enumerating valid accounts and for confirming a lockout landed.
    /// </summary>
    private const string GenericFailure = "Invalid email or password.";

    private readonly UserManager<ApplicationUser> _userManager;
    private readonly SignInManager<ApplicationUser> _signInManager;
    private readonly IPasswordHasher<ApplicationUser> _passwordHasher;
    private readonly ITokenService _tokens;
    private readonly AppDbContext _db;
    private readonly JwtOptions _jwt;
    private readonly ILogger<AuthService> _logger;

    /// <summary>
    /// A real Identity hash of a throwaway password, computed once at startup. Verifying
    /// against it when the email is unknown burns the same PBKDF2 work a genuine check
    /// would, so response time does not reveal which addresses are registered.
    /// </summary>
    private readonly string _dummyHash;

    public AuthService(
        UserManager<ApplicationUser> userManager,
        SignInManager<ApplicationUser> signInManager,
        IPasswordHasher<ApplicationUser> passwordHasher,
        ITokenService tokens,
        AppDbContext db,
        IOptions<JwtOptions> jwt,
        ILogger<AuthService> logger)
    {
        _userManager = userManager;
        _signInManager = signInManager;
        _passwordHasher = passwordHasher;
        _tokens = tokens;
        _db = db;
        _jwt = jwt.Value;
        _logger = logger;

        _dummyHash = _passwordHasher.HashPassword(new ApplicationUser(), "not-a-real-password-placeholder");
    }

    public async Task<AuthOutcome> RegisterAsync(RegisterRequest request, string? ip, CancellationToken ct)
    {
        var email = request.Email.Trim();

        var user = new ApplicationUser
        {
            Id = Guid.NewGuid(),
            UserName = email,
            Email = email,
            DisplayName = request.DisplayName.Trim(),
            CreatedAtUtc = DateTime.UtcNow,

            // Off by default in Identity, and easy to miss. Without it AccessFailedCount
            // increments but nobody is ever actually locked out.
            LockoutEnabled = true
        };

        var result = await _userManager.CreateAsync(user, request.Password);
        if (!result.Succeeded)
        {
            var errors = result.Errors
                .GroupBy(e => e.Code)
                .ToDictionary(g => g.Key, g => g.Select(e => e.Description).ToArray());

            return new AuthOutcome(false, "Registration failed.", null, null, errors);
        }

        // The role is assigned server-side and never read from the request body. Trusting a
        // client-supplied role would let anyone register themselves as an administrator.
        await _userManager.AddToRoleAsync(user, RoleNames.User);

        _logger.LogInformation("User {UserId} registered from {Ip}", user.Id, ip);

        var tokens = await IssueTokensAsync(user, ip, ct);
        return new AuthOutcome(true, null, user, tokens);
    }

    public async Task<AuthOutcome> LoginAsync(LoginRequest request, string? ip, CancellationToken ct)
    {
        var user = await _userManager.FindByEmailAsync(request.Email.Trim());

        if (user is null)
        {
            // Equalize timing against the known-account path before returning.
            _passwordHasher.VerifyHashedPassword(new ApplicationUser(), _dummyHash, request.Password);
            _logger.LogWarning("Login failed (unknown account) for {Email} from {Ip}", request.Email, ip);
            return new AuthOutcome(false, GenericFailure, null, null);
        }

        // lockoutOnFailure: true is what drives the brute-force counter. Identity increments
        // AccessFailedCount, stamps LockoutEnd once MaxFailedAccessAttempts is reached, and
        // resets the counter on success. None of that needs hand-rolling.
        var signIn = await _signInManager.CheckPasswordSignInAsync(user, request.Password, lockoutOnFailure: true);

        if (signIn.IsLockedOut)
        {
            _logger.LogWarning("Login blocked (locked out until {Until}) for {UserId} from {Ip}",
                user.LockoutEnd, user.Id, ip);
            return new AuthOutcome(false, GenericFailure, null, null);
        }

        if (!signIn.Succeeded)
        {
            _logger.LogWarning("Login failed (bad password, {Count} consecutive) for {UserId} from {Ip}",
                user.AccessFailedCount, user.Id, ip);
            return new AuthOutcome(false, GenericFailure, null, null);
        }

        _logger.LogInformation("User {UserId} logged in from {Ip}", user.Id, ip);

        var tokens = await IssueTokensAsync(user, ip, ct);
        return new AuthOutcome(true, null, user, tokens);
    }

    public async Task<AuthOutcome> RefreshAsync(string? refreshToken, string? ip, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(refreshToken))
            return new AuthOutcome(false, "Missing refresh token.", null, null);

        var hash = _tokens.Hash(refreshToken);

        var stored = await _db.RefreshTokens
            .Include(r => r.User)
            .FirstOrDefaultAsync(r => r.TokenHash == hash, ct);

        if (stored is null)
            return new AuthOutcome(false, "Invalid refresh token.", null, null);

        // A token that was already rotated away is being replayed: either a stale cookie jar
        // or a stolen token. The chain cannot be told apart from a compromise, so every
        // outstanding token for the user is revoked and they must authenticate again.
        if (stored.RevokedAtUtc is not null)
        {
            _logger.LogWarning("Refresh token replay detected for {UserId} from {Ip}; revoking all tokens",
                stored.UserId, ip);
            await RevokeAllForUserAsync(stored.UserId, ct);
            return new AuthOutcome(false, "Invalid refresh token.", null, null);
        }

        if (DateTime.UtcNow >= stored.ExpiresAtUtc)
            return new AuthOutcome(false, "Refresh token expired.", null, null);

        var user = stored.User;

        // Catches a "log out everywhere" that happened after this token was issued.
        var currentStamp = await _userManager.GetSecurityStampAsync(user);
        if (!string.Equals(user.SecurityStamp, currentStamp, StringComparison.Ordinal))
            return new AuthOutcome(false, "Session is no longer valid.", null, null);

        var tokens = await IssueTokensAsync(user, ip, ct, rotating: stored);
        return new AuthOutcome(true, null, user, tokens);
    }

    public async Task LogoutAsync(Guid userId, string? refreshToken, CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(refreshToken))
        {
            var hash = _tokens.Hash(refreshToken);
            var stored = await _db.RefreshTokens
                .FirstOrDefaultAsync(r => r.TokenHash == hash && r.UserId == userId, ct);

            if (stored is { RevokedAtUtc: null })
            {
                stored.RevokedAtUtc = DateTime.UtcNow;
                await _db.SaveChangesAsync(ct);
            }
        }

        _logger.LogInformation("User {UserId} logged out", userId);
    }

    public Task<IList<string>> GetRolesAsync(ApplicationUser user) => _userManager.GetRolesAsync(user);

    private async Task<AuthTokens> IssueTokensAsync(
        ApplicationUser user, string? ip, CancellationToken ct, RefreshToken? rotating = null)
    {
        var roles = await _userManager.GetRolesAsync(user);
        var (accessToken, expiresAt) = _tokens.CreateAccessToken(user, roles);

        var refreshRaw = _tokens.CreateSecureRandomToken();
        var refreshHash = _tokens.Hash(refreshRaw);

        if (rotating is not null)
        {
            rotating.RevokedAtUtc = DateTime.UtcNow;
            rotating.ReplacedByTokenHash = refreshHash;
        }

        _db.RefreshTokens.Add(new RefreshToken
        {
            UserId = user.Id,
            TokenHash = refreshHash,
            CreatedAtUtc = DateTime.UtcNow,
            ExpiresAtUtc = DateTime.UtcNow.AddDays(_jwt.RefreshTokenDays),
            CreatedByIp = ip
        });

        await _db.SaveChangesAsync(ct);

        return new AuthTokens(accessToken, refreshRaw, _tokens.CreateSecureRandomToken(), expiresAt);
    }

    private Task RevokeAllForUserAsync(Guid userId, CancellationToken ct) =>
        _db.RefreshTokens
            .Where(r => r.UserId == userId && r.RevokedAtUtc == null)
            .ExecuteUpdateAsync(s => s.SetProperty(r => r.RevokedAtUtc, DateTime.UtcNow), ct);
}
