using LocationTracker.Api.Common;
using LocationTracker.Api.Data;
using LocationTracker.Api.Dtos.Locations;
using LocationTracker.Api.Dtos.Trips;
using LocationTracker.Api.Entities;
using LocationTracker.Api.Security;
using LocationTracker.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace LocationTracker.Api.Controllers;

/// <summary>
/// Every route here is administrator-only. The role comes from the signed token, so it
/// cannot be asserted by the caller.
/// </summary>
[ApiController]
[Route("api/admin")]
[Authorize(Policy = AuthorizationPolicies.AdminOnly)]
public class AdminController : ControllerBase
{
    private readonly ILocationService _locations;
    private readonly AppDbContext _db;
    private readonly UserManager<ApplicationUser> _userManager;

    public AdminController(ILocationService locations, AppDbContext db, UserManager<ApplicationUser> userManager)
    {
        _locations = locations;
        _db = db;
        _userManager = userManager;
    }

    [HttpGet("users")]
    public async Task<ActionResult<PagedResult<AdminUserResponse>>> Users(
        [FromQuery] int? page, [FromQuery] int? pageSize, [FromQuery] string? search, CancellationToken ct)
    {
        var (p, size) = PageRequest.Normalize(page, pageSize);

        var query = _db.Users.AsNoTracking();

        if (!string.IsNullOrWhiteSpace(search))
        {
            var term = search.Trim().ToUpperInvariant();
            query = query.Where(u => u.NormalizedEmail!.Contains(term) || u.DisplayName.ToUpper().Contains(term));
        }

        var total = await query.LongCountAsync(ct);

        var users = await query
            .OrderBy(u => u.Email)
            .Skip((p - 1) * size)
            .Take(size)
            .Select(u => new AdminUserResponse(
                u.Id,
                u.Email!,
                u.DisplayName,
                u.CreatedAtUtc,
                u.LockoutEnd,
                u.AccessFailedCount,
                _db.Locations.Count(l => l.UserId == u.Id),
                _db.Trips.Count(t => t.UserId == u.Id)))
            .ToListAsync(ct);

        return Ok(new PagedResult<AdminUserResponse>
        {
            Items = users, Page = p, PageSize = size, TotalCount = total
        });
    }

    [HttpGet("users/{id:guid}/locations")]
    public async Task<ActionResult<PagedResult<LocationResponse>>> UserLocations(
        Guid id, [FromQuery] DateTime? from, [FromQuery] DateTime? to,
        [FromQuery] int? page, [FromQuery] int? pageSize, CancellationToken ct)
        => Ok(await _locations.GetHistoryAsync(id, from, to, page, pageSize, ct));

    [HttpGet("users/{id:guid}/trips")]
    public async Task<ActionResult<PagedResult<TripResponse>>> UserTrips(
        Guid id, [FromQuery] DateTime? from, [FromQuery] DateTime? to, [FromQuery] bool? activeOnly,
        [FromQuery] int? page, [FromQuery] int? pageSize, CancellationToken ct)
        => Ok(await _locations.GetTripsAsync(id, from, to, activeOnly, page, pageSize, ct));

    [HttpGet("trips/{id:long}")]
    public async Task<ActionResult<TripDetailResponse>> Trip(long id, CancellationToken ct)
    {
        // No user restriction: seeing any user's trip is the whole point of the admin role.
        var detail = await _locations.GetTripDetailAsync(id, null, ct);
        return detail is null ? NotFound(new ApiError("Trip not found.")) : Ok(detail);
    }

    /// <summary>Every user's most recent fix in one call, for a live map.</summary>
    [HttpGet("locations/latest")]
    public async Task<ActionResult<IReadOnlyList<UserLatestLocationResponse>>> LatestForAll(CancellationToken ct)
        => Ok(await _locations.GetLatestForAllUsersAsync(ct));

    /// <summary>Clears a lockout early, for when a legitimate user locks themselves out.</summary>
    [HttpPost("users/{id:guid}/unlock")]
    public async Task<IActionResult> Unlock(Guid id)
    {
        var user = await _userManager.FindByIdAsync(id.ToString());
        if (user is null) return NotFound(new ApiError("User not found."));

        await _userManager.SetLockoutEndDateAsync(user, null);
        await _userManager.ResetAccessFailedCountAsync(user);

        return NoContent();
    }
}

public record AdminUserResponse(
    Guid Id,
    string Email,
    string DisplayName,
    DateTime CreatedAtUtc,
    DateTimeOffset? LockoutEnd,
    int AccessFailedCount,
    int LocationCount,
    int TripCount);
