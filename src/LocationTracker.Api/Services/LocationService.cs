using LocationTracker.Api.Common;
using LocationTracker.Api.Data;
using LocationTracker.Api.Dtos.Locations;
using LocationTracker.Api.Dtos.Trips;
using LocationTracker.Api.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace LocationTracker.Api.Services;

public interface ILocationService
{
    Task<LocationIngestResponse> RecordAsync(Guid userId, CreateLocationRequest request, CancellationToken ct);
    Task<BatchIngestResponse> RecordBatchAsync(Guid userId, CreateLocationBatchRequest request, CancellationToken ct);
    Task<PagedResult<LocationResponse>> GetHistoryAsync(Guid userId, DateTime? from, DateTime? to, int? page, int? pageSize, CancellationToken ct);
    Task<LocationResponse?> GetLatestAsync(Guid userId, CancellationToken ct);
    Task<IReadOnlyList<UserLatestLocationResponse>> GetLatestForAllUsersAsync(CancellationToken ct);

    Task<PagedResult<TripResponse>> GetTripsAsync(Guid userId, DateTime? from, DateTime? to, bool? activeOnly, int? page, int? pageSize, CancellationToken ct);
    Task<TripResponse?> GetActiveTripAsync(Guid userId, CancellationToken ct);
    Task<TripDetailResponse?> GetTripDetailAsync(long tripId, Guid? restrictToUserId, CancellationToken ct);
}

public class LocationService : ILocationService
{
    private readonly AppDbContext _db;
    private readonly ITripDetector _detector;
    private readonly TripDetectionOptions _options;
    private readonly ILogger<LocationService> _logger;

    public LocationService(
        AppDbContext db,
        ITripDetector detector,
        IOptions<TripDetectionOptions> options,
        ILogger<LocationService> logger)
    {
        _db = db;
        _detector = detector;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<LocationIngestResponse> RecordAsync(Guid userId, CreateLocationRequest request, CancellationToken ct)
    {
        var point = ToEntity(userId, request);

        var ctx = await LoadContextAsync(userId, ct);

        _db.Locations.Add(point);
        _detector.ProcessPoint(ctx, point);

        await PersistAsync(ctx, ct);

        return new LocationIngestResponse(
            ToDto(point),
            ctx.ActiveTrip?.Id,
            ctx.AnyTripStarted,
            ctx.AnyTripEnded);
    }

    public async Task<BatchIngestResponse> RecordBatchAsync(Guid userId, CreateLocationBatchRequest request, CancellationToken ct)
    {
        var warnings = new List<string>();

        if (request.Points.Count > _options.MaxBatchSize)
            throw new ArgumentException($"Batch exceeds the maximum of {_options.MaxBatchSize} points.");

        var ctx = await LoadContextAsync(userId, ct);

        // Replaying in recorded order is what makes an offline backlog produce the same trips
        // it would have produced live — the detector is entirely order-dependent.
        var ordered = request.Points
            .Select(p => ToEntity(userId, p))
            .OrderBy(p => p.RecordedAtUtc)
            .ToList();

        var accepted = 0;
        var rejected = 0;

        foreach (var point in ordered)
        {
            // Points predating what is already stored would rewrite history the detector has
            // already acted on, so they are refused rather than silently reordering trips.
            if (ctx.PreviousPoint is not null && point.RecordedAtUtc < ctx.PreviousPoint.RecordedAtUtc)
            {
                rejected++;
                continue;
            }

            _db.Locations.Add(point);
            _detector.ProcessPoint(ctx, point);
            accepted++;
        }

        if (rejected > 0)
            warnings.Add($"{rejected} point(s) were older than the latest stored fix and were ignored.");

        await PersistAsync(ctx, ct);

        return new BatchIngestResponse(accepted, rejected, ctx.ActiveTrip?.Id, warnings);
    }

    /// <summary>
    /// One query for the last stored fix and one for the open trip. Both are index-backed,
    /// and loading them once is what lets a 1000-point batch cost the same two reads.
    /// </summary>
    private async Task<DetectionContext> LoadContextAsync(Guid userId, CancellationToken ct)
    {
        var previous = await _db.Locations
            .Where(l => l.UserId == userId)
            .OrderByDescending(l => l.RecordedAtUtc)
            .FirstOrDefaultAsync(ct);

        var activeTrip = await _db.Trips
            .Where(t => t.UserId == userId && t.EndedAtUtc == null)
            .FirstOrDefaultAsync(ct);

        return new DetectionContext { PreviousPoint = previous, ActiveTrip = activeTrip };
    }

    private async Task PersistAsync(DetectionContext ctx, CancellationToken ct)
    {
        try
        {
            await SaveAndDiscardAsync(ctx, ct);
        }
        catch (DbUpdateException ex) when (IsActiveTripConflict(ex))
        {
            // The partial unique index refused a second open trip for this user: a concurrent
            // request opened one first. The database, not application code, is what guarantees
            // this — and losing the race costs only the trip attribution, never the point.
            _logger.LogWarning(
                "Concurrent trip creation rejected by UX_Trips_UserId_Active; retrying without trip attribution");

            foreach (var entry in _db.ChangeTracker.Entries<Trip>().Where(e => e.State == EntityState.Added).ToList())
                entry.State = EntityState.Detached;

            // Both halves matter: clearing only the FK leaves the navigation set, and EF would
            // re-populate TripId from it on the way back into SaveChanges.
            foreach (var entry in _db.ChangeTracker.Entries<Location>())
            {
                entry.Entity.Trip = null;
                entry.Entity.TripId = null;
            }

            ctx.ActiveTrip = null;
            ctx.AnyTripStarted = false;

            await _db.SaveChangesAsync(ct);
        }
    }

    private async Task SaveAndDiscardAsync(DetectionContext ctx, CancellationToken ct)
    {
        // Scoped so the transaction is disposed before any retry runs. Saving again while a
        // rolled-back transaction is still the context's current one throws.
        await using var transaction = await _db.Database.BeginTransactionAsync(ct);

        await _db.SaveChangesAsync(ct);

        // Deferred until now because a discarded trip may own points persisted by earlier
        // requests. Detaching them first keeps the raw history intact — only the derived
        // rollup goes away.
        foreach (var trip in ctx.TripsToDiscard.Where(t => t.Id != 0))
        {
            await _db.Locations
                .Where(l => l.TripId == trip.Id)
                .ExecuteUpdateAsync(s => s.SetProperty(l => l.TripId, (long?)null), ct);

            await _db.Trips.Where(t => t.Id == trip.Id).ExecuteDeleteAsync(ct);
        }

        await transaction.CommitAsync(ct);
    }

    private static bool IsActiveTripConflict(DbUpdateException ex) =>
        ex.InnerException is Npgsql.PostgresException { SqlState: "23505" } pg &&
        pg.ConstraintName == "UX_Trips_UserId_Active";

    private static Location ToEntity(Guid userId, CreateLocationRequest request) => new()
    {
        UserId = userId,
        Latitude = request.Latitude,
        Longitude = request.Longitude,
        AccuracyMeters = request.AccuracyMeters,
        Speed = request.Speed,
        Heading = request.Heading,
        RecordedAtUtc = (request.RecordedAtUtc ?? DateTime.UtcNow).ToUtcKind(),
        ReceivedAtUtc = DateTime.UtcNow
    };

    public async Task<PagedResult<LocationResponse>> GetHistoryAsync(
        Guid userId, DateTime? from, DateTime? to, int? page, int? pageSize, CancellationToken ct)
    {
        var (p, size) = PageRequest.Normalize(page, pageSize);

        var query = _db.Locations.AsNoTracking().Where(l => l.UserId == userId);

        if (from is not null) query = query.Where(l => l.RecordedAtUtc >= from.Value.ToUtcKind());
        if (to is not null) query = query.Where(l => l.RecordedAtUtc <= to.Value.ToUtcKind());

        var total = await query.LongCountAsync(ct);

        var items = await query
            .OrderByDescending(l => l.RecordedAtUtc)
            .Skip((p - 1) * size)
            .Take(size)
            .Select(l => ToDto(l))
            .ToListAsync(ct);

        return new PagedResult<LocationResponse> { Items = items, Page = p, PageSize = size, TotalCount = total };
    }

    public async Task<LocationResponse?> GetLatestAsync(Guid userId, CancellationToken ct)
    {
        var latest = await _db.Locations.AsNoTracking()
            .Where(l => l.UserId == userId)
            .OrderByDescending(l => l.RecordedAtUtc)
            .FirstOrDefaultAsync(ct);

        return latest is null ? null : ToDto(latest);
    }

    public async Task<IReadOnlyList<UserLatestLocationResponse>> GetLatestForAllUsersAsync(CancellationToken ct)
    {
        // A correlated "latest per user" rather than loading every point and grouping in
        // memory; the (UserId, RecordedAtUtc DESC) index turns each lookup into a single seek.
        var rows = await _db.Users.AsNoTracking()
            .Select(u => new
            {
                u.Id,
                u.Email,
                u.DisplayName,
                Latest = _db.Locations
                    .Where(l => l.UserId == u.Id)
                    .OrderByDescending(l => l.RecordedAtUtc)
                    .FirstOrDefault(),
                ActiveTripId = _db.Trips
                    .Where(t => t.UserId == u.Id && t.EndedAtUtc == null)
                    .Select(t => (long?)t.Id)
                    .FirstOrDefault()
            })
            .ToListAsync(ct);

        return rows
            .Select(r => new UserLatestLocationResponse(
                r.Id,
                r.Email ?? string.Empty,
                r.DisplayName,
                r.Latest is null ? null : ToDto(r.Latest),
                r.ActiveTripId))
            .ToList();
    }

    public async Task<PagedResult<TripResponse>> GetTripsAsync(
        Guid userId, DateTime? from, DateTime? to, bool? activeOnly, int? page, int? pageSize, CancellationToken ct)
    {
        var (p, size) = PageRequest.Normalize(page, pageSize);

        var query = _db.Trips.AsNoTracking().Where(t => t.UserId == userId);

        if (from is not null) query = query.Where(t => t.StartedAtUtc >= from.Value.ToUtcKind());
        if (to is not null) query = query.Where(t => t.StartedAtUtc <= to.Value.ToUtcKind());
        if (activeOnly == true) query = query.Where(t => t.EndedAtUtc == null);

        var total = await query.LongCountAsync(ct);

        var trips = await query
            .OrderByDescending(t => t.StartedAtUtc)
            .Skip((p - 1) * size)
            .Take(size)
            .ToListAsync(ct);

        return new PagedResult<TripResponse>
        {
            Items = trips.Select(ToDto).ToList(),
            Page = p,
            PageSize = size,
            TotalCount = total
        };
    }

    public async Task<TripResponse?> GetActiveTripAsync(Guid userId, CancellationToken ct)
    {
        var trip = await _db.Trips.AsNoTracking()
            .FirstOrDefaultAsync(t => t.UserId == userId && t.EndedAtUtc == null, ct);

        return trip is null ? null : ToDto(trip);
    }

    /// <summary>
    /// When restrictToUserId is supplied the trip must belong to that user. A caller asking
    /// for someone else's trip gets the same null an unknown id produces, so trip ids cannot
    /// be probed to learn who exists.
    /// </summary>
    public async Task<TripDetailResponse?> GetTripDetailAsync(long tripId, Guid? restrictToUserId, CancellationToken ct)
    {
        var query = _db.Trips.AsNoTracking().Where(t => t.Id == tripId);

        if (restrictToUserId is not null)
            query = query.Where(t => t.UserId == restrictToUserId.Value);

        var trip = await query.FirstOrDefaultAsync(ct);
        if (trip is null) return null;

        var path = await _db.Locations.AsNoTracking()
            .Where(l => l.TripId == tripId)
            .OrderBy(l => l.RecordedAtUtc)
            .Select(l => new TrackPointResponse(l.Latitude, l.Longitude, l.RecordedAtUtc))
            .ToListAsync(ct);

        return new TripDetailResponse(ToDto(trip), path);
    }

    private static LocationResponse ToDto(Location l) => new(
        l.Id, l.Latitude, l.Longitude, l.AccuracyMeters, l.Speed, l.Heading,
        l.RecordedAtUtc, l.ReceivedAtUtc, l.TripId);

    public static TripResponse ToDto(Trip t) => new(
        t.Id,
        t.UserId,
        t.StartedAtUtc,
        t.EndedAtUtc,
        Math.Round(t.DistanceMeters, 2),
        Math.Round(t.DistanceMeters / 1000d, 3),
        t.DurationSeconds,
        t.DurationSeconds is null ? null : TimeSpan.FromSeconds(t.DurationSeconds.Value).ToString(@"hh\:mm\:ss"),
        t.StartLatitude,
        t.StartLongitude,
        t.EndLatitude,
        t.EndLongitude,
        t.PointCount,
        Math.Round(t.MaxSpeedMps, 3),
        t.AverageSpeedMps is null ? null : Math.Round(t.AverageSpeedMps.Value, 3),
        t.EndReason,
        t.EndedAtUtc is null);
}
