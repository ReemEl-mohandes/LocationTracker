using System.Security.Claims;
using LocationTracker.Api.Common;
using LocationTracker.Api.Dtos.Locations;
using LocationTracker.Api.Entities;
using LocationTracker.Api.Security;
using LocationTracker.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;

namespace LocationTracker.Api.Controllers;

[ApiController]
[Route("api/locations")]
[Authorize(Roles = RoleNames.User + "," + RoleNames.Admin)]
public class LocationsController : ControllerBase
{
    private readonly ILocationService _locations;

    public LocationsController(ILocationService locations) => _locations = locations;

    [HttpPost]
    [EnableRateLimiting(RateLimitPolicies.LocationWrite)]
    public async Task<ActionResult<LocationIngestResponse>> Record(CreateLocationRequest request, CancellationToken ct)
    {
        var result = await _locations.RecordAsync(CurrentUserId, request, ct);
        return Ok(result);
    }

    /// <summary>Upload a backlog accumulated while the device was offline.</summary>
    [HttpPost("batch")]
    [EnableRateLimiting(RateLimitPolicies.LocationWrite)]
    public async Task<ActionResult<BatchIngestResponse>> RecordBatch(CreateLocationBatchRequest request, CancellationToken ct)
    {
        try
        {
            return Ok(await _locations.RecordBatchAsync(CurrentUserId, request, ct));
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new ApiError(ex.Message));
        }
    }

    [HttpGet("me")]
    public async Task<ActionResult<PagedResult<LocationResponse>>> MyHistory(
        [FromQuery] DateTime? from, [FromQuery] DateTime? to,
        [FromQuery] int? page, [FromQuery] int? pageSize, CancellationToken ct)
        => Ok(await _locations.GetHistoryAsync(CurrentUserId, from, to, page, pageSize, ct));

    [HttpGet("me/latest")]
    public async Task<ActionResult<LocationResponse>> MyLatest(CancellationToken ct)
    {
        var latest = await _locations.GetLatestAsync(CurrentUserId, ct);
        return latest is null ? NoContent() : Ok(latest);
    }

    private Guid CurrentUserId => Guid.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier)!);
}
