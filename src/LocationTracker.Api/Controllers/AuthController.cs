using System.Security.Claims;
using LocationTracker.Api.Common;
using LocationTracker.Api.Dtos.Auth;
using LocationTracker.Api.Entities;
using LocationTracker.Api.Security;
using LocationTracker.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace LocationTracker.Api.Controllers;

[ApiController]
[Route("api/auth")]
public class AuthController : ControllerBase
{
    private readonly IAuthService _auth;
    private readonly ICookieWriter _cookies;
    private readonly UserManager<ApplicationUser> _userManager;

    public AuthController(IAuthService auth, ICookieWriter cookies, UserManager<ApplicationUser> userManager)
    {
        _auth = auth;
        _cookies = cookies;
        _userManager = userManager;
    }

    [HttpPost("register")]
    [AllowAnonymous]
    [EnableRateLimiting(RateLimitPolicies.Register)]
    public async Task<IActionResult> Register(RegisterRequest request, CancellationToken ct)
    {
        var outcome = await _auth.RegisterAsync(request, ClientIp, ct);

        if (!outcome.Succeeded)
            return BadRequest(new ApiError(outcome.Error ?? "Registration failed.", outcome.ValidationErrors));

        _cookies.WriteAuthCookies(Response, outcome.Tokens!.AccessToken, outcome.Tokens.RefreshToken, outcome.Tokens.CsrfToken);

        var roles = await _auth.GetRolesAsync(outcome.User!);

        return StatusCode(StatusCodes.Status201Created,
            new AuthResponse(outcome.User!.Id, outcome.User.Email!, outcome.User.DisplayName, roles,
                outcome.Tokens.AccessTokenExpiresAtUtc));
    }

    [HttpPost("login")]
    [AllowAnonymous]
    [EnableRateLimiting(RateLimitPolicies.Login)]
    public async Task<IActionResult> Login(LoginRequest request, CancellationToken ct)
    {
        var outcome = await _auth.LoginAsync(request, ClientIp, ct);

        // Wrong password, unknown account and locked-out all land here with the same body and
        // status. Anything more specific is a user-enumeration oracle.
        if (!outcome.Succeeded)
            return Unauthorized(new ApiError(outcome.Error ?? "Invalid email or password."));

        _cookies.WriteAuthCookies(Response, outcome.Tokens!.AccessToken, outcome.Tokens.RefreshToken, outcome.Tokens.CsrfToken);

        var roles = await _auth.GetRolesAsync(outcome.User!);

        return Ok(new AuthResponse(outcome.User!.Id, outcome.User.Email!, outcome.User.DisplayName, roles,
            outcome.Tokens.AccessTokenExpiresAtUtc));
    }

    [HttpPost("refresh")]
    [AllowAnonymous]
    public async Task<IActionResult> Refresh(CancellationToken ct)
    {
        // Read from the cookie, never the body: the token must stay unreachable to script.
        var refreshToken = Request.Cookies[CookieNames.RefreshToken];

        var outcome = await _auth.RefreshAsync(refreshToken, ClientIp, ct);

        if (!outcome.Succeeded)
        {
            _cookies.ClearAuthCookies(Response);
            return Unauthorized(new ApiError(outcome.Error ?? "Invalid refresh token."));
        }

        _cookies.WriteAuthCookies(Response, outcome.Tokens!.AccessToken, outcome.Tokens.RefreshToken, outcome.Tokens.CsrfToken);

        var roles = await _auth.GetRolesAsync(outcome.User!);

        return Ok(new AuthResponse(outcome.User!.Id, outcome.User.Email!, outcome.User.DisplayName, roles,
            outcome.Tokens.AccessTokenExpiresAtUtc));
    }

    [HttpPost("logout")]
    [Authorize]
    public async Task<IActionResult> Logout(CancellationToken ct)
    {
        await _auth.LogoutAsync(CurrentUserId, Request.Cookies[CookieNames.RefreshToken], ct);
        _cookies.ClearAuthCookies(Response);
        return NoContent();
    }

    /// <summary>
    /// Rotates the Identity security stamp, which invalidates every outstanding access and
    /// refresh token for this user at once — "sign out on all my devices".
    /// </summary>
    [HttpPost("logout-all")]
    [Authorize]
    public async Task<IActionResult> LogoutEverywhere()
    {
        var user = await _userManager.FindByIdAsync(CurrentUserId.ToString());
        if (user is null) return Unauthorized();

        await _userManager.UpdateSecurityStampAsync(user);
        _cookies.ClearAuthCookies(Response);
        return NoContent();
    }

    [HttpGet("me")]
    [Authorize]
    public async Task<IActionResult> Me()
    {
        var user = await _userManager.FindByIdAsync(CurrentUserId.ToString());
        if (user is null) return Unauthorized();

        var roles = await _userManager.GetRolesAsync(user);

        return Ok(new UserProfileResponse(user.Id, user.Email!, user.DisplayName, roles, user.CreatedAtUtc));
    }

    private Guid CurrentUserId => Guid.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier)!);

    private string? ClientIp => HttpContext.Connection.RemoteIpAddress?.ToString();
}
