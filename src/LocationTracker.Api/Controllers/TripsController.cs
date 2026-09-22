using System.Security.Claims;
using LocationTracker.Api.Common;
using LocationTracker.Api.Dtos.Trips;
using LocationTracker.Api.Entities;
using LocationTracker.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LocationTracker.Api.Controllers;

[ApiController]
[Route("api/trips")]
[Authorize(Roles = RoleNames.User + "," + RoleNames.Admin)]
public class TripsController : ControllerBase
{
    private readonly ILocationService _locations;

    public TripsController(ILocationService locations) => _locations = locations;

    [HttpGet("me")]
    public async Task<ActionResult<PagedResult<TripResponse>>> MyTrips(
        [FromQuery] DateTime? from, [FromQuery] DateTime? to, [FromQuery] bool? activeOnly,
        [FromQuery] int? page, [FromQuery] int? pageSize, CancellationToken ct)
        => Ok(await _locations.GetTripsAsync(CurrentUserId, from, to, activeOnly, page, pageSize, ct));

    [HttpGet("me/active")]
    public async Task<ActionResult<TripResponse>> MyActiveTrip(CancellationToken ct)
    {
        var trip = await _locations.GetActiveTripAsync(CurrentUserId, ct);
        return trip is null ? NoContent() : Ok(trip);
    }

    [HttpGet("me/{id:long}")]
    public async Task<ActionResult<TripDetailResponse>> MyTrip(long id, CancellationToken ct)
    {
        // Scoped to the caller, so another user's trip id is indistinguishable from one that
        // does not exist.
        var detail = await _locations.GetTripDetailAsync(id, CurrentUserId, ct);
        return detail is null ? NotFound(new ApiError("Trip not found.")) : Ok(detail);
    }

    private Guid CurrentUserId => Guid.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier)!);
}
